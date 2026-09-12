import { ServerKind } from './ServerProfile';
import { TalebookCoreService } from './TalebookCoreService';

/** 探测结果可用时，通知 UI 的 AppStorage 键（值为识别出的服务端展示名）。 */
export const SERVER_KIND_NOTICE_KEY: string = 'serverKindNotice';

/**
 * 服务端类型探测：按服务器**实际响应**识别 talebook / mybooks。
 *
 * 为什么需要：账号里的 `serverKind` 来自用户在「账号与服务器」下拉里的选择。
 * 一旦选错，整类功能都会错：把 talebook 当成 MyBooks 时会去请求 mybooks 专有的
 * `/api/library/stats`（talebook 上返回 404），「管理概览」因此显示且必然加载失败；
 * 同时 talebook 专有的书架/标注/主题/网络书库等入口全部被隐藏。
 *
 * 探针选择依据（实测 192.168.31.160:58080 talebook）：
 * - talebook 独有 `GET /api/welcome` → 200 `{"err":"free","msg":"无需访问码"}`；
 *   同一路径在 mybooks 上 404
 * - mybooks 独有 `GET /api/access` → 200；同一路径在 talebook 上 404
 * 两者都是**公开**路由（访问码要在登录前使用），不受登录态影响。
 */
export class ServerProbe {
  /**
   * 探测当前 base URL 指向的书库服务端类型。
   * 返回 ServerKind 的值；无法判定（网络不可达、非书库服务端等）时返回空串，调用方不应改变既有配置。
   *
   * 顺序说明：先探 mybooks 的 `/api/access`，再探 talebook 的 `/api/welcome`。
   * talebook 已实测对未知 `/api/*` 返回 404（无 JSON 兜底），因此先判 mybooks 更安全：
   * 万一某个 mybooks 部署对 `/api/welcome` 有响应，也不会把 mybooks 误判成 talebook。
   */
  static async detect(): Promise<string> {
    if (await ServerProbe.reachable('/api/access')) {
      return ServerKind.MYBOOKS;
    }
    if (await ServerProbe.reachable('/api/welcome')) {
      return ServerKind.TALEBOOK;
    }
    return '';
  }

  /**
   * 该路径是否返回了可识别的书库接口响应。
   *
   * 必须校验响应形态：部分服务端对未知路径会返回 200 的 HTML 兜底页，
   * 仅凭状态码会把它们误判成命中。
   */
  private static async reachable(path: string): Promise<boolean> {
    try {
      const raw: string = await TalebookCoreService.talebookGet(path);
      // native 通道在 HTTP >= 400 时抛异常，能走到这里说明状态码是 2xx
      return raw.length > 0 && raw.charAt(0) === '{' && raw.indexOf('"err"') >= 0;
    } catch (_error) {
      return false;
    }
  }
}
