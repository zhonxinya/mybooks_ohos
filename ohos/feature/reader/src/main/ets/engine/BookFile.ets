import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TextCodec } from './TextCodec';

const TAG: string = 'BookFile';

/** 书籍文件的同步读写工具（EPUB 解压后的目录结构也用它访问）。 */
export class BookFile {
  /**
   * 路径是否存在。
   * 用 `statSync` 而非 `accessSync`：实测（模拟器 6.1.0.115）对**不存在**的路径
   * `accessSync` 不抛错，会让调用方误判为「已存在」。
   */
  static exists(path: string): boolean {
    try {
      fs.statSync(path);
      return true;
    } catch (_error) {
      return false;
    }
  }

  /** 建目录（含中间层级）；已存在时直接返回。 */
  static ensureDir(path: string): void {
    if (BookFile.exists(path)) {
      return;
    }
    try {
      fs.mkdirSync(path, true);
    } catch (error) {
      throw new Error(`无法创建缓存目录：${(error as Error).message}`);
    }
  }

  /**
   * 递归删除目录（用于清理上次中断的 EPUB 解压残留）。
   * `fs.rmdirSync` 只能删空目录（非空会报 13900032），故需自行递归。
   */
  static removeDir(path: string): void {
    if (!BookFile.exists(path)) {
      return;
    }
    try {
      const entries = fs.listFileSync(path);
      for (let i = 0; i < entries.length; i++) {
        const child = BookFile.join(path, entries[i]);
        if (fs.statSync(child).isDirectory()) {
          BookFile.removeDir(child);
        } else {
          fs.unlinkSync(child);
        }
      }
      fs.rmdirSync(path);
    } catch (error) {
      throw new Error(`无法清理缓存目录：${(error as Error).message}`);
    }
  }

  /** 读取整个文件并按 `TextCodec` 的编码探测解码。 */
  static readText(path: string): string {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const size = fs.statSync(path).size;
      if (size <= 0) {
        return '';
      }
      const buffer = new ArrayBuffer(size);
      const readLength = fs.readSync(file.fd, buffer);
      return TextCodec.decode(readLength === size ? buffer : buffer.slice(0, readLength));
    } catch (error) {
      hilog.error(0x0000, TAG, 'readText failed: %{public}s (%{public}s)', path, (error as Error).message);
      throw new Error(`读取文件失败：${(error as Error).message}`);
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (_error) {
          // 关闭失败不影响已读到的内容
        }
      }
    }
  }

  /** 拼接路径，避免调用方各自处理分隔符。 */
  static join(base: string, relative: string): string {
    if (relative.length === 0) {
      return base;
    }
    const left = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    const right = relative.startsWith('/') ? relative.substring(1) : relative;
    return `${left}/${right}`;
  }

  /** 取目录部分（无分隔符时返回空串）。 */
  static dirName(path: string): string {
    const index = path.lastIndexOf('/');
    return index < 0 ? '' : path.substring(0, index);
  }

  /** 去掉 URL 片段与查询串，并做一次 decodeURIComponent（EPUB 内的 href 常见 %20）。 */
  static normalizeHref(href: string): string {
    let value = href;
    const hashIndex = value.indexOf('#');
    if (hashIndex >= 0) {
      value = value.substring(0, hashIndex);
    }
    const queryIndex = value.indexOf('?');
    if (queryIndex >= 0) {
      value = value.substring(0, queryIndex);
    }
    try {
      return decodeURIComponent(value);
    } catch (_error) {
      return value;
    }
  }
}
