import { router, UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_TAG: string = 'AppRouter';

/**
 * 跨端路由助手。
 *
 * **为什么需要它**：Android（ArkUI-X）上 `UIContext.getRouter()` 返回 `undefined`，
 * 直接调用会抛 `TypeError: Cannot read property pushUrl of undefined`——表现为
 * 「点击无反应」（实测：设置页跳转账号与服务器页）。而全局 `router`（`@kit.ArkUI`）
 * 在鸿蒙与 Android 两端都可用。
 *
 * 因此全工程的路由调用统一走本类：优先使用 `UIContext` 版（鸿蒙推荐写法），
 * 取不到（取方法即抛 TypeError）时回退全局 `router`。返回值与 `router` 一致
 * （`Promise<void>`），调用方仍可链式 `.then()/.catch()`。
 */
export class AppRouter {
  /** 打开新页面。 */
  static pushUrl(ui: UIContext, options: router.RouterOptions): Promise<void> {
    try {
      return ui.getRouter().pushUrl(options);
    } catch (error) {
      hilog.debug(0x0000, LOG_TAG, 'pushUrl via UIContext unavailable, fallback: %{public}s', `${error}`);
      router.pushUrl(options);
      return Promise.resolve();
    }
  }

  /** 用新页面替换当前页面。 */
  static replaceUrl(ui: UIContext, options: router.RouterOptions): Promise<void> {
    try {
      return ui.getRouter().replaceUrl(options);
    } catch (error) {
      hilog.debug(0x0000, LOG_TAG, 'replaceUrl via UIContext unavailable, fallback: %{public}s', `${error}`);
      router.replaceUrl(options);
      return Promise.resolve();
    }
  }

  /** 返回上一页。 */
  static back(ui: UIContext): Promise<void> {
    try {
      ui.getRouter().back();
      return Promise.resolve();
    } catch (error) {
      hilog.debug(0x0000, LOG_TAG, 'back via UIContext unavailable, fallback: %{public}s', `${error}`);
      router.back();
      return Promise.resolve();
    }
  }

  /** 清空页面栈。 */
  static clear(ui: UIContext): Promise<void> {
    try {
      ui.getRouter().clear();
      return Promise.resolve();
    } catch (error) {
      hilog.debug(0x0000, LOG_TAG, 'clear via UIContext unavailable, fallback: %{public}s', `${error}`);
      router.clear();
      return Promise.resolve();
    }
  }

  /** 读取当前页面的路由参数（Android 下经全局 router 读取）。 */
  static getParams(ui: UIContext): Object {
    try {
      return ui.getRouter().getParams();
    } catch (error) {
      hilog.debug(0x0000, LOG_TAG, 'getParams via UIContext unavailable, fallback: %{public}s', `${error}`);
      return router.getParams();
    }
  }

  /** 读取当前页面栈状态。 */
  static getState(ui: UIContext): router.RouterState {
    try {
      return ui.getRouter().getState();
    } catch (error) {
      hilog.debug(0x0000, LOG_TAG, 'getState via UIContext unavailable, fallback: %{public}s', `${error}`);
      return router.getState();
    }
  }
}
