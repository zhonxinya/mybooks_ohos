import { asset } from '@kit.AssetStoreKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'SecureStore';

/**
 * 安全存储（**鸿蒙实现**）。
 *
 * 用 `Asset Store Kit`（关键资产存储服务）保存密码类敏感数据：
 * 关键资产由系统加密后写入受信存储，避免密码明文落盘。
 * 来源: https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-asset
 *
 * Android 端的等价实现见 `SecureStoreAndroid`（AES-GCM + Keystore），
 * 两者方法签名一致，`PasswordStore` 因此不需要感知平台。
 */
export class SecureStore {
  /** 写入；别名已存在则覆盖。 */
  static put(_context: common.UIAbilityContext, key: Uint8Array, value: Uint8Array): void {
    const attr: asset.AssetMap = new Map();
    attr.set(asset.Tag.SECRET, value);
    attr.set(asset.Tag.ALIAS, key);
    attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attr.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    try {
      asset.addSync(attr);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0000, TAG, 'put failed, code: %{public}d, message: %{public}s', err.code, err.message);
      throw err as Error;
    }
  }

  /** 别名不存在时返回 null。 */
  static get(_context: common.UIAbilityContext, key: Uint8Array): Uint8Array | null {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, key);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const result: Array<asset.AssetMap> = asset.querySync(query);
      if (result.length === 0) {
        return null;
      }
      return result[0].get(asset.Tag.SECRET) as Uint8Array;
    } catch (error) {
      const err = error as BusinessError;
      // NOT_FOUND 是稳定结论（等价于「不存在」）；其他错误上抛，由调用方决定是否重试
      if (err.code === asset.ErrorCode.NOT_FOUND) {
        return null;
      }
      hilog.error(0x0000, TAG, 'get failed, code: %{public}d, message: %{public}s', err.code, err.message);
      throw err as Error;
    }
  }

  /** 删除；别名不存在时静默成功。 */
  static delete(_context: common.UIAbilityContext, key: Uint8Array): void {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, key);
    try {
      asset.removeSync(query);
    } catch (error) {
      const err = error as BusinessError;
      if (err.code !== asset.ErrorCode.NOT_FOUND) {
        hilog.error(0x0000, TAG, 'delete failed, code: %{public}d, message: %{public}s', err.code, err.message);
        throw err as Error;
      }
    }
  }
}
