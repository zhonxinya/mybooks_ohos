import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import entry from 'libentry.so';
import { PlatformTarget } from '../common/PlatformTarget';
import { ErrorFormat } from '../utils/ErrorFormat';

/** 安装包下载进度；total 为 0 表示服务端未提供 Content-Length（无法给出百分比）。 */
export interface ApkDownloadProgress {
  received: number;
  total: number;
}

/** 落盘目录名：Android 壳工程的 ApkFileProvider 按同一约定读取（<filesDir>/updates）。 */
const UPDATES_DIR: string = 'updates';
/**
 * provider 的 authority：与 scripts/android-shell-overlay.sh 注入清单的字面量一致。
 * 这里不按 bundleManager 推导——安卓 applicationId（…mybooks.android）与 ArkUI-X 的
 * bundleName（…mybooks.harmonyos）已经不同，推导出来的是后者，与清单对不上。
 */
const AUTHORITY: string = 'com.zhonxinya.mybooks.android.apkprovider';
const CONNECT_TIMEOUT_MS: number = 20000;
/** 读超时按“单次读”计时；安装包较大，放宽到 10 分钟。 */
const READ_TIMEOUT_MS: number = 600000;
const USER_AGENT: string = 'mybooks_ohos-android';

/**
 * Android 应用内升级：把 release 附件里的 APK 下载到应用私有目录，再交由系统安装器安装。
 *
 * 链路上两个平台约束（详见 docs/ArkUI-X-Android迁移指南.md 的「应用内升级（Android）」一节）：
 * - Android 7 起禁止把 file:// URI 交给别的应用，而 ArkUI-X 的 Want→Intent 映射只会 setData、
 *   不会附加 FLAG_GRANT_READ_URI_PERMISSION，所以必须经壳工程里声明的 ApkFileProvider 提供
 *   content:// URI（见 android-overlay/ 与 scripts/android-shell-overlay.sh）；
 * - 安装界面由系统在“安装未知应用”授权之后弹出，客户端只负责把安装包交出去。
 */
export class ApkUpdater {
  /** 应用内安装仅 Android 支持；HarmonyOS 的 HAP 需自行签名后安装，仍走外链下载。 */
  static supported(): boolean {
    return PlatformTarget.isAndroid();
  }

  /** 安装包目录：<filesDir>/updates。 */
  static updatesDir(context: common.UIAbilityContext): string {
    return `${context.filesDir}/${UPDATES_DIR}`;
  }

  /** 把远端文件名收敛成安全文件名；不以 .apk 结尾时退回 fallback。 */
  static safeFileName(name: string, fallback: string): string {
    const cleaned: string = name.replace(/[^A-Za-z0-9._-]/g, '');
    return cleaned.toLowerCase().endsWith('.apk') ? cleaned : fallback;
  }

  /**
   * 流式下载 APK 到应用私有目录。
   * @param expectedSize release 里登记的附件字节数；>0 时会校验落盘大小，防止把半截包交给安装器。
   * @returns 落地文件的绝对路径（安装时再按文件名拼 content:// URI）。
   * @throws 网络或写盘失败时抛出 Error，由调用方提示。
   */
  static async download(
    context: common.UIAbilityContext,
    url: string,
    fileName: string,
    expectedSize: number,
    onProgress: (progress: ApkDownloadProgress) => void,
  ): Promise<string> {
    const dir: string = ApkUpdater.updatesDir(context);
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (_error) {
      fs.mkdirSync(dir, true);
    }
    const destPath: string = `${dir}/${fileName}`;
    const request = http.createHttp();
    let file: fs.File | null = null;
    try {
      file = fs.openSync(destPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const fd: number = file.fd;
      await new Promise<void>((resolve, reject) => {
        let settled: boolean = false;
        let received: number = 0;
        let total: number = 0;
        const finish = (error?: Error): void => {
          if (settled) {
            return;
          }
          settled = true;
          // 实测：数据其实已收全时，requestInStream 的回调仍可能带一个无信息的 err，
          // 故以字节数为准——收全即成功，没收全才报错。
          if (total > 0 && received >= total) {
            resolve();
            return;
          }
          if (error !== undefined) {
            reject(error);
            return;
          }
          if (received <= 0) {
            reject(new Error('安装包下载为空'));
            return;
          }
          reject(new Error(`安装包下载不完整（已收 ${received} / ${total} 字节）`));
        };
        request.on('headersReceive', (header: Object) => {
          const record: Record<string, Object> = header as Record<string, Object>;
          const length: number = Number(record['content-length'] ?? 0);
          if (Number.isFinite(length) && length > 0) {
            total = length;
          }
        });
        request.on('dataReceive', (chunk: ArrayBuffer) => {
          if (settled) {
            return;
          }
          // writeSync 可能只写入一部分，必须按返回值续写；否则字节数记满了、文件却是半截的
          let offset: number = 0;
          while (offset < chunk.byteLength) {
            const view: ArrayBuffer = offset === 0 ? chunk : chunk.slice(offset);
            let written: number = 0;
            try {
              written = fs.writeSync(fd, view);
            } catch (error) {
              finish(new Error(ErrorFormat.message(error as Object)));
              return;
            }
            if (written <= 0) {
              finish(new Error('写入安装包失败'));
              return;
            }
            offset += written;
          }
          received += chunk.byteLength;
          onProgress({ received: received, total: total });
        });
        request.on('dataEnd', () => {
          finish();
        });
        request.requestInStream(url, {
          method: http.RequestMethod.GET,
          header: { 'User-Agent': USER_AGENT },
          connectTimeout: CONNECT_TIMEOUT_MS,
          readTimeout: READ_TIMEOUT_MS,
        }, (err: BusinessError | null, code: number) => {
          if (err !== null) {
            finish(new Error(ErrorFormat.message(err as Object)));
            return;
          }
          if (code < 200 || code >= 300) {
            finish(new Error(`下载安装包失败（HTTP ${code}）`));
          }
        });
      });
    } catch (error) {
      ApkUpdater.removeFile(destPath);
      throw error as Error;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file.fd);
        } catch (_error) {
        }
      }
      request.destroy();
    }
    ApkUpdater.pruneOthers(dir, fileName);
    const size: number = fs.statSync(destPath).size;
    if (expectedSize > 0 && size !== expectedSize) {
      ApkUpdater.removeFile(destPath);
      throw new Error(`安装包不完整：已下载 ${size} 字节，应为 ${expectedSize} 字节`);
    }
    return destPath;
  }

  /**
   * 唤起系统安装器（仅 Android）。
   *
   * 不走 ArkTS 的 startAbility：ArkUI-X 的隐式 Want 在引擎内先做自身 bundle 解析，解析不到
   * 直接抛 Internal error，压根到不了平台侧（实测连用 viewData 打开 https 链接也失败）。
   * 改走 libentry 的原生桥，由 Android 侧的 ApkInstaller 构造 Intent 并授予一次性读权限。
   */
  static async install(fileName: string): Promise<void> {
    const uri: string = `content://${AUTHORITY}/${UPDATES_DIR}/${fileName}`;
    const error: string = entry.apiInstallApk(uri) as string;
    if (error.length > 0) {
      throw new Error(error);
    }
  }

  /** 只保留当前这次下载的文件，避免历史安装包堆积占用空间。 */
  private static pruneOthers(dir: string, keepName: string): void {
    try {
      const names: string[] = fs.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        const name: string = names[i];
        if (name !== keepName && name.toLowerCase().endsWith('.apk')) {
          ApkUpdater.removeFile(`${dir}/${name}`);
        }
      }
    } catch (_error) {
      // 清理失败不影响安装
    }
  }

  private static removeFile(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (_error) {
      // 尽力而为
    }
  }
}
