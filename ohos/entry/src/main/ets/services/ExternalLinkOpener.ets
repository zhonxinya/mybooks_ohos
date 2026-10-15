import { common, Want } from '@kit.AbilityKit';
import entry from 'libentry.so';
import { PlatformTarget } from '../common/PlatformTarget';

/**
 * 打开外部链接（http/https），按运行平台分派。
 *
 * ArkUI-X 的 Android 端**无法用隐式 Want 打开外部应用**：`startAbility({action: viewData, uri})`
 * 会在引擎内先做自身 bundle 解析，解析不到就直接抛 Internal error，根本到不了平台侧
 * （实测，与 `ApkUpdater` 装包遇到的是同一个限制）。故 Android 经 libentry 原生桥
 * （`ExternalLinkOpener.java` 构造 `Intent.ACTION_VIEW`）打开，鸿蒙端仍走隐式 Want。
 *
 * 协议白名单在本类统一把关（并在 Java 侧再校验一次）：链接可能来自服务端下发的数据，
 * 放开任意协议等于允许用 `file://` / `intent://` 之类的 URI 触发其它应用的行为。
 */
export class ExternalLinkOpener {
  /** 仅放行 http/https。 */
  static isHttpUrl(url: string): boolean {
    return url.startsWith('http://') || url.startsWith('https://');
  }

  /**
   * 打开链接。
   *
   * @param context 鸿蒙分支需要；Android 分支不使用（上下文来自壳工程 provider，见 android-overlay）
   * @returns 空串表示已发起；否则为可直接展示的错误描述
   */
  static async open(context: common.UIAbilityContext, url: string): Promise<string> {
    if (url.length === 0) {
      return '链接不可用';
    }
    if (!ExternalLinkOpener.isHttpUrl(url)) {
      return '链接协议不受支持';
    }
    if (PlatformTarget.isAndroid()) {
      return entry.apiOpenExternalUrl(url) as string;
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: url,
    };
    try {
      await context.startAbility(want);
      return '';
    } catch (_error) {
      return '无法打开链接';
    }
  }
}
