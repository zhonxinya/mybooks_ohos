import { TalebookCoreService } from './TalebookCoreService';

/**
 * 主题管理（themes）API —— talebook 上游专有，mybooks 无对应端点。
 *
 * 端点核对依据：docs/talebook/webserver/handlers/theme.py::routes()
 *   GET  /api/themes          → ThemeListHandler.get（列出内置主题，每项含 `active`，无需登录）
 *   POST /api/themes/activate → ThemeActivateHandler.post（@is_admin；JSON body `{name}`；
 *                               `name` 为空串时恢复默认主题，成功返回 `{err, msg}`（清空）或 `{err, msg, theme}`）
 *   GET  /api/themes/active   → ThemeActiveHandler.get（当前激活主题，无激活主题时 `theme: null`，无需登录）
 *
 * 字段核对依据：theme.py::get_builtin_theme
 *   `name` / `display_name` / `version` / `author` / `description` / `installed_at` / `builtin` /
 *   `components` / `active`。
 *   ⚠️ 上游未提供任何缩略图/预览图字段（Web 端 app/pages/admin/themes.vue 同样只用图标 + 文案渲染），
 *   因此这里不构造图片 URL，列表页也不使用 AuthImage。
 */

/** 主题实体（theme.py::get_builtin_theme 返回项中客户端会用到的字段）。 */
export interface ThemeItem {
  /** 主题标识（激活时提交的 `name`，如 `brass`）。 */
  name: string;
  /** 展示名（上游 `display_name`，已本地化）。 */
  displayName: string;
  version: string;
  author: string;
  description: string;
  /** 是否为当前激活主题（列表接口直接给出；无激活主题时全部为 false）。 */
  active: boolean;
}

/** 激活结果（`name` 为空串恢复默认主题时上游不返回 `theme`）。 */
export interface ThemeActivateResult {
  /** 激活后的主题信息；恢复默认主题时为 null。 */
  theme: ThemeItem | null;
  /** 服务端提示（上游 msg，如「已激活主题：brass」「已恢复默认主题」）。 */
  message: string;
}

function asString(value: Object | undefined | null, fallback: string = ''): string {
  if (value === undefined || value === null) {
    return fallback;
  }
  const text = String(value);
  return text === 'undefined' || text === 'null' ? fallback : text;
}

/** 上游布尔字段（JSON true/false）→ boolean；缺失时取 fallback。 */
function asBoolean(value: Object | undefined | null, fallback: boolean): boolean {
  if (value === undefined || value === null) {
    return fallback;
  }
  return String(value).toLowerCase() === 'true';
}

function isMissing(value: Object | undefined | null): boolean {
  return value === undefined || value === null;
}

/** `{err, msg}` 约定：err 为空或 `ok` 视为成功。 */
function isOk(err: string): boolean {
  return err.length === 0 || err === 'ok';
}

function envelopeOf(raw: string): Record<string, Object> {
  try {
    return JSON.parse(raw) as Record<string, Object>;
  } catch (_error) {
    throw new Error('主题接口返回的响应无法解析');
  }
}

/** 解析响应并校验 `{err, msg}`；失败时抛出带服务端提示的错误（如 `permission.not_admin`）。 */
function ensureOk(raw: string): Record<string, Object> {
  const parsed = envelopeOf(raw);
  const err = asString(parsed['err']);
  if (!isOk(err)) {
    throw new Error(asString(parsed['msg'], err));
  }
  return parsed;
}

function parseTheme(raw: Record<string, Object>): ThemeItem {
  return {
    name: asString(raw['name']),
    displayName: asString(raw['display_name']),
    version: asString(raw['version']),
    author: asString(raw['author']),
    description: asString(raw['description']),
    active: asBoolean(raw['active'], false),
  };
}

function parseThemes(raw: Object | undefined): ThemeItem[] {
  const list = (raw as Array<Record<string, Object>> | undefined) ?? [];
  const result: ThemeItem[] = [];
  for (let index = 0; index < list.length; index++) {
    result.push(parseTheme(list[index]));
  }
  return result;
}

export class ThemeApi {
  /** GET /api/themes —— 列出服务端全部可用主题（内置主题，含 `active` 标记）。 */
  static async listThemes(): Promise<ThemeItem[]> {
    const parsed = ensureOk(await TalebookCoreService.talebookGet('/api/themes'));
    return parseThemes(parsed['themes']);
  }

  /**
   * GET /api/themes/active —— 当前激活主题。
   *
   * 上游未激活任何主题（`ACTIVE_THEME` 为空或不在内置列表中）时返回 `theme: null`，这里映射为 null。
   */
  static async getActiveTheme(): Promise<ThemeItem | null> {
    const parsed = ensureOk(await TalebookCoreService.talebookGet('/api/themes/active'));
    const node = parsed['theme'];
    if (isMissing(node)) {
      return null;
    }
    return parseTheme(node as Record<string, Object>);
  }

  /**
   * POST /api/themes/activate —— 激活主题（上游要求管理员权限）。
   *
   * @param name 主题标识；传空串即恢复默认主题（上游 `{name: ''}` 分支）。
   *
   * ⚠️ 上游该操作会写入服务端配置文件，部署在监听配置变化的容器/进程上时可能触发服务重启，
   * 因此调用方不应在成功后立刻强依赖下一次请求。
   */
  static async activateTheme(name: string): Promise<ThemeActivateResult> {
    const body: Record<string, Object> = { 'name': name };
    const parsed = ensureOk(await TalebookCoreService.talebookPost('/api/themes/activate', JSON.stringify(body)));
    const node = parsed['theme'];
    const theme: ThemeItem | null = isMissing(node) ? null : parseTheme(node as Record<string, Object>);
    return {
      theme: theme,
      message: asString(parsed['msg']),
    };
  }
}
