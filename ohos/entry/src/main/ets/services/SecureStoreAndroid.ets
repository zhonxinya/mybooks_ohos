import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { NativeCore } from 'mybooks_core';

const TAG: string = 'SecureStoreAndroid';
/** preferences 文件名：与应用其它偏好隔离，避免误读 */
const STORE_NAME: string = 'mybooks_secure_store';

/**
 * 安全存储（**Android 实现**）。
 *
 * ArkUI-X 的 Android 端没有 `@kit.AssetStoreKit`（关键资产存储服务），
 * 因此用等价方案：**AES-256-GCM 加密后落盘到 preferences**。
 *
 * 加解密复用 `mybooks_core` 原生模块（`NativeCore.secureSeal` / `secureOpen`，
 * 内部用 mbedTLS 的 AES-GCM，密钥文件位于身份根目录、权限 0600）。
 *
 * ## 为什么走 NAPI 而不是 ArkUI-X 的 Android 加密插件
 *
 * ArkUI-X 的 Android 能力需在 ArkTS 侧 `import '@arkui-x.android'`，
 * 而该模块的类型声明**只在 ArkUI-X SDK 存在时才有**；本工程的鸿蒙构建链
 * （hvigor + 官方 ArkTS SDK）没有该 SDK，会因「找不到模块」直接编译失败。
 * `//#if ANDROID` 条件编译在 hvigor 下不被识别，无法用来跳过 import。
 *
 * 复用已有的 NAPI 通道后，两条构建链共用同一份 ArkTS 代码，
 * 且加密实现天然跨端（同一套 mbedTLS 在鸿蒙端也在跑）。
 *
 * 安全性：GCM 的 authTag 校验失败时 `secureOpen` 返回空串，**不返回部分明文**；
 * 取不到密钥时同样失败，**绝不降级为明文存储**。
 *
 * 方法签名与鸿蒙版 `SecureStore` 一致，故 `PasswordStore` 无需感知平台。
 */
export class SecureStoreAndroid {
  /** 进程内缓存的 preferences 句柄（getPreferencesSync 不宜每次调用） */
  private static cachedStore: preferences.Preferences | null = null;

  static put(context: common.UIAbilityContext, key: Uint8Array, value: Uint8Array): void {
    try {
      const plain: string = SecureStoreAndroid.toUtf8(value);
      const sealed: string = NativeCore.secureSeal(SecureStoreAndroid.keyDir(context), plain);
      if (sealed.length === 0) {
        throw new Error('secure store: seal failed');
      }
      const store: preferences.Preferences = SecureStoreAndroid.openStore(context);
      store.putSync(SecureStoreAndroid.encodeKey(key), sealed);
      store.flush();
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0000, TAG, 'put failed, code: %{public}d, message: %{public}s', err.code, err.message);
      throw err as Error;
    }
  }

  static get(context: common.UIAbilityContext, key: Uint8Array): Uint8Array | null {
    try {
      const store: preferences.Preferences = SecureStoreAndroid.openStore(context);
      const mapKey: string = SecureStoreAndroid.encodeKey(key);
      const sealed: preferences.ValueType = store.getSync(mapKey, mapKey);
      if (typeof sealed !== 'string' || sealed.length === 0) {
        return null;
      }
      const plain: string = NativeCore.secureOpen(SecureStoreAndroid.keyDir(context), sealed);
      // 密文被篡改 / 密钥不匹配时原生层返回空串，此时按「不存在」处理
      if (plain.length === 0) {
        return null;
      }
      return SecureStoreAndroid.fromUtf8(plain);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0000, TAG, 'get failed, code: %{public}d, message: %{public}s', err.code, err.message);
      throw err as Error;
    }
  }

  static delete(context: common.UIAbilityContext, key: Uint8Array): void {
    try {
      const store: preferences.Preferences = SecureStoreAndroid.openStore(context);
      store.deleteSync(SecureStoreAndroid.encodeKey(key));
      store.flush();
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0000, TAG, 'delete failed, code: %{public}d, message: %{public}s', err.code, err.message);
      throw err as Error;
    }
  }

  /**
   * 密钥目录：**应用级固定目录，不随账号身份根变化**。
   *
   * 这里刻意不用 `NativeCore.identityDir()`：密文存放在**全局**的
   * `mybooks_secure_store`（preferences 按应用一份，见 `openStore`），密钥若随身份根
   * 变化就会与密文的作用域错配——`AccountManager.add()` 是在 `activate()` **之前**
   * 写密码的，那时身份根还是上一个（首装时即应用根），于是密码用旧密钥封装，
   * 切根后永远解不开。实测（2026-10-15 设备端）：`talebook_url`/`talebook_username`
   * 正常而 `talebook_password` 恒为空 → `hasAuthCredentials()` 恒 false →
   * 安卓端「个人中心／退出登录」入口整个消失。
   *
   * 账号隔离本来就靠**别名**（`account_<id>_password`），与鸿蒙端 Asset Store 的做法一致：
   * 那种实现里也没有「按身份根换密钥」这回事。
   */
  private static keyDir(context: common.UIAbilityContext): string {
    return context.filesDir;
  }

  /** 打开（或复用）安全存储的 preferences。 */
  private static openStore(context: common.UIAbilityContext): preferences.Preferences {
    if (SecureStoreAndroid.cachedStore !== null) {
      return SecureStoreAndroid.cachedStore;
    }
    const options: preferences.Options = { name: STORE_NAME } as preferences.Options;
    SecureStoreAndroid.cachedStore = preferences.getPreferencesSync(context, options);
    return SecureStoreAndroid.cachedStore;
  }

  /** 用 base64 编码键字节，保证任意字节序列都能作为合法 preferences 键。 */
  private static encodeKey(key: Uint8Array): string {
    const helper: util.Base64Helper = new util.Base64Helper();
    return helper.encodeToStringSync(key);
  }

  private static toUtf8(data: Uint8Array): string {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(data, { stream: false });
  }

  private static fromUtf8(text: string): Uint8Array {
    const encoder: util.TextEncoder = new util.TextEncoder();
    return encoder.encodeInto(text);
  }
}
