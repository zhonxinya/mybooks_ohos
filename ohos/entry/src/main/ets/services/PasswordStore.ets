import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'PasswordStore';

/**
 * 基于 Asset Store Kit（关键资产存储服务）保存密码类敏感数据。
 * 关键资产由系统加密后写入受信存储，避免密码明文落盘。
 * 来源: https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-asset
 */
export class PasswordStore {
  /**
   * 进程内一级缓存：`asset.querySync` 是一次同步 IPC，读关键资产在 UI 线程上是毫秒级开销。
   * 封面地址解析 / 凭据判断等路径会高频读取（每次解析封面都会读一次 talebook_url），
   * 命中缓存后完全不再进系统服务。
   *
   * 失效策略：所有写入都经本类，`set`/`remove` 同步更新缓存；键在 Asset Store 中的值
   * 不会被其他进程改写（同一应用的账号切换也走这里），因此缓存不会变脏。
   */
  private static cache: Map<string, string> = new Map<string, string>();

  private static stringToArray(str: string): Uint8Array {
    const textEncoder: util.TextEncoder = new util.TextEncoder();
    return textEncoder.encodeInto(str);
  }

  private static arrayToString(arr: Uint8Array): string {
    const textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return textDecoder.decodeToString(arr, { stream: false });
  }

  /** 写入密码，别名已存在时覆盖；密码为空则删除该关键资产。 */
  static set(alias: string, secret: string): void {
    if (secret.length === 0) {
      PasswordStore.remove(alias);
      return;
    }
    const attr: asset.AssetMap = new Map();
    attr.set(asset.Tag.SECRET, PasswordStore.stringToArray(secret));
    attr.set(asset.Tag.ALIAS, PasswordStore.stringToArray(alias));
    attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attr.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    try {
      asset.addSync(attr);
      PasswordStore.cache.set(alias, secret);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0000, TAG, 'set failed, code: %{public}d, message: %{public}s', err.code, err.message);
    }
  }

  /** 读取密码，关键资产不存在时返回空字符串。 */
  static get(alias: string): string {
    const cached: string | undefined = PasswordStore.cache.get(alias);
    if (cached !== undefined) {
      return cached;
    }
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, PasswordStore.stringToArray(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const result: Array<asset.AssetMap> = asset.querySync(query);
      if (result.length === 0) {
        PasswordStore.cache.set(alias, '');
        return '';
      }
      const secret: Uint8Array = result[0].get(asset.Tag.SECRET) as Uint8Array;
      const value: string = PasswordStore.arrayToString(secret);
      PasswordStore.cache.set(alias, value);
      return value;
    } catch (error) {
      const err = error as BusinessError;
      if (err.code !== asset.ErrorCode.NOT_FOUND) {
        hilog.error(0x0000, TAG, 'get failed, code: %{public}d, message: %{public}s', err.code, err.message);
        return '';
      }
      // NOT_FOUND 是稳定结论，可安全缓存；其他错误（如设备未解锁）不缓存，下次重试
      PasswordStore.cache.set(alias, '');
      return '';
    }
  }

  /** 删除关键资产（账号被删除时需同步清理其密码）。 */
  static remove(alias: string): void {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, PasswordStore.stringToArray(alias));
    try {
      asset.removeSync(query);
      PasswordStore.cache.set(alias, '');
    } catch (error) {
      const err = error as BusinessError;
      if (err.code !== asset.ErrorCode.NOT_FOUND) {
        hilog.error(0x0000, TAG, 'remove failed, code: %{public}d, message: %{public}s', err.code, err.message);
      }
    }
  }

  /**
   * 确保别名在 Asset Store 中存在（用于把历史上明文保存的凭据迁移过来）。
   * 已存在时不覆盖：Asset Store 中的值更可信，避免明文旧值倒灌。
   * 返回是否已就绪（含此前已存在的情况）。
   */
  static ensure(alias: string, secret: string): boolean {
    if (secret.length === 0 || PasswordStore.get(alias).length > 0) {
      return true;
    }
    PasswordStore.set(alias, secret);
    return PasswordStore.get(alias).length > 0;
  }
}
