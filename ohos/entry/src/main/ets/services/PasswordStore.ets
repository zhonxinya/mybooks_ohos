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
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0000, TAG, 'set failed, code: %{public}d, message: %{public}s', err.code, err.message);
    }
  }

  /** 读取密码，关键资产不存在时返回空字符串。 */
  static get(alias: string): string {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, PasswordStore.stringToArray(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const result: Array<asset.AssetMap> = asset.querySync(query);
      if (result.length === 0) {
        return '';
      }
      const secret: Uint8Array = result[0].get(asset.Tag.SECRET) as Uint8Array;
      return PasswordStore.arrayToString(secret);
    } catch (error) {
      const err = error as BusinessError;
      if (err.code !== asset.ErrorCode.NOT_FOUND) {
        hilog.error(0x0000, TAG, 'get failed, code: %{public}d, message: %{public}s', err.code, err.message);
      }
      return '';
    }
  }

  private static remove(alias: string): void {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, PasswordStore.stringToArray(alias));
    try {
      asset.removeSync(query);
    } catch (error) {
      const err = error as BusinessError;
      if (err.code !== asset.ErrorCode.NOT_FOUND) {
        hilog.error(0x0000, TAG, 'remove failed, code: %{public}d, message: %{public}s', err.code, err.message);
      }
    }
  }
}
