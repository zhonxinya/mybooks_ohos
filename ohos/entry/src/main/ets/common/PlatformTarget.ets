import { deviceInfo } from '@kit.BasicServicesKit';

/**
 * 目标平台判定（**运行时**，非条件编译）。
 *
 * ## 为什么用运行时判断而不是 `//#if` 条件编译
 *
 * ArkUI-X 用 `//#if ANDROID` / `//#if OHOS` 做**构建期**裁剪，能把不适用于当前平台的
 * 代码整段剔除产物。但这套预处理由 **ACE Tools / ArkUI-X SDK 的构建链**驱动：
 *
 * - 用 ArkUI-X 的 `ace build apk` 构建 Android 时，`//#if` 生效，Android 分支被保留；
 * - 用 **DevEco Studio / 官方 hvigor 构建鸿蒙 HAP 时，`//#if` 不被识别**，
 *   它只是普通注释，于是 `//#if ANDROID` 与 `//#if OHOS` 两个分支的代码会**同时编译**，
 *   造成「Duplicate identifier」这类编译错误。
 *
 * 本工程两种构建都要能跑通（鸿蒙 HAP 走 hvigor，Android APK 走 ACE Tools），
 * 因此**平台分支一律用运行时判断**：依据系统信息识别平台，调用对应实现。
 * 代价是两端产物里都含有另一个分支的代码，但平台层方法体都很小，
 * 且 Android 专有代码依赖 `@arkui-x.android`，在鸿蒙端不会被执行到。
 *
 * 判定依据：`osFullName` 含 'Android' 即为 Android；OpenHarmony/HarmonyOS 走 else 分支。
 */
export class PlatformTarget {
  /**
   * 当前是否运行在 Android 上。
   *
   * 判定依据为 `deviceInfo.osFullName`（如 `Android 14` / `OpenHarmony 5.0`），
   * ArkUI-X 在两端都实现了 `ohos.deviceInfo`，因此该判断跨端可用。
   * 取不到值（空串）时按鸿蒙处理 —— 鸿蒙是本工程的主目标，保守回退到它更安全。
   */
  static isAndroid(): boolean {
    const osName: string = deviceInfo.osFullName ?? '';
    return osName.toLowerCase().indexOf('android') >= 0;
  }

  /** 展示用平台名。 */
  static label(): string {
    return PlatformTarget.isAndroid() ? 'Android' : 'HarmonyOS';
  }
}
