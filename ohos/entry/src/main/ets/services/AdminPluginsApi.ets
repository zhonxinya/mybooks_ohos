/**
 * talebook 插件中心 REST 封装（强类型）。
 *
 * 端点来源（逐条核对上游 handler，勿凭印象改动）：
 * - docs/talebook/webserver/handlers/plugins.py::routes()
 * - docs/talebook/webserver/handlers/plugin_booktools.py::routes()
 *
 * 上游语义备忘：
 * - `GET /api/admin/plugins` 返回 definitions / installations / builtin_state；
 *   definition 由 `models.py::PluginDefinition.to_public_dict` 序列化，**不含** `extra_features`。
 *   需要枚举某个插件的 features 时改走 `GET /api/plugins/{plugin_key}`
 *   （`plugins.py::_public_manifest` 会带上 `extra_features` 与 `ui`）。
 * - 连接动作统一走 `POST /api/admin/plugins/connections/{id}/{test|preview|run|retry|rollback}`，
 *   请求体支持 `input_data` / `trigger` / `parent_run_id`。test|preview 是只读，run|retry|rollback 会写库。
 * - `POST /api/admin/plugins/opds-service` 只切换 `settings.OPDS_ENABLED` 开关，与 OPDS 源导入（AdminOpdsApi）无关。
 * - features 逃生舱 `POST /api/plugins/{plugin_key}/features/{action}` 属于用户态接口（@auth），
 *   上游没有对应的 /api/admin 版本。
 * - 分页：本组接口无分页参数，`/api/admin/plugins/runs` 固定 `limit(100)`。
 * - 插件工具：text-replace 与 txt-fixer 有 preview（@auth）/ run（@is_admin）；
 *   zh-converter 上游**只有 run**（provider 层有 preview 实现但未注册 HTTP 路由），故作降级：
 *   仅提供 `zhConverterRun`，不臆造 preview 端点。
 */
import { TalebookCoreService } from './TalebookCoreService';
import { ApiMessageResult } from './TalebookApi';

/** 插件动作（上游路由捕获组 `(test|preview|run|retry|rollback)`）。 */
export const PLUGIN_ACTION_TEST: string = 'test';
export const PLUGIN_ACTION_PREVIEW: string = 'preview';
export const PLUGIN_ACTION_RUN: string = 'run';
export const PLUGIN_ACTION_RETRY: string = 'retry';
export const PLUGIN_ACTION_ROLLBACK: string = 'rollback';

/** 文本工具输出模式。 */
export const TOOL_OUTPUT_MODE_NEW: string = 'new';
export const TOOL_OUTPUT_MODE_OVERWRITE: string = 'overwrite';

// ---------------------------------------------------------------------------
// 模型（字段取自上游 to_public_dict / _public_manifest / _*_summary）
// ---------------------------------------------------------------------------

export interface AdminPluginDefinition {
  id?: number;
  plugin_key?: string;
  version?: string;
  protocol_version?: string;
  name?: string;
  runtime_kind?: string;
  categories?: string[];
  capabilities?: string[];
  actions?: string[];
  auth_schema?: Record<string, Object>;
  config_schema?: Record<string, Object>;
  permissions?: string[];
  data_policy?: Record<string, Object>;
  compatibility?: Record<string, Object>;
  homepage?: string;
  license?: string;
  description?: string;
  ui?: Record<string, Object>;
  connection_owners?: string[];
  /** 仅 `/api/plugins/{plugin_key}` 返回（_public_manifest）。 */
  extra_features?: Record<string, Object>;
}

export interface AdminPluginSecret {
  configured?: boolean;
  kind?: string;
  mask?: string;
  version?: number;
  last_rotated_at?: string;
}

export interface AdminPluginInstallation {
  id?: number;
  plugin_key?: string;
  version?: string;
  enabled?: boolean;
  scope?: string;
  config?: Record<string, Object>;
  installed_from?: string;
  checksum?: string;
  status?: string;
  /** 仅 `/api/admin/plugins` 列表内联返回。 */
  definition?: AdminPluginDefinition;
}

export interface AdminPluginConnection {
  id?: number;
  installation_id?: number;
  owner_type?: string;
  owner_id?: number;
  role?: string;
  name?: string;
  config?: Record<string, Object>;
  scopes?: string[];
  schedule?: string;
  cursor?: Record<string, Object>;
  health?: string;
  health_message?: string;
  enabled?: boolean;
  secret?: AdminPluginSecret;
}

export interface AdminPluginRun {
  id?: number;
  connection_id?: number;
  parent_run_id?: number;
  action?: string;
  trigger?: string;
  status?: string;
  requested_by?: number;
  counts?: Record<string, Object>;
  cursor_before?: Record<string, Object>;
  cursor_after?: Record<string, Object>;
  error_code?: string;
  error_message?: string;
  attempt?: number;
  duration_ms?: number;
  created_at?: string;
  started_at?: string;
  finished_at?: string;
}

export interface AdminPluginRunItem {
  id?: number;
  run_id?: number;
  external_id?: string;
  entity_type?: string;
  status?: string;
  operation?: string;
  error_code?: string;
  error_message?: string;
  payload_hash?: string;
  data?: Record<string, Object>;
}

export interface AdminMetadataSummary {
  title?: string;
  authors?: string[];
  publisher?: string;
  isbn?: string;
  comments?: string;
  rating?: Object;
  series?: string;
  language?: string;
  cover_url?: string;
  website?: string;
  provider_value?: string;
}

export interface AdminSourceSummary {
  external_id?: Object;
  title?: Object;
  authors?: Object;
  isbn?: Object;
  format?: Object;
  source?: Object;
  source_url?: Object;
  access?: Object;
  license?: Object;
  description?: Object;
  cover_url?: Object;
}

export interface AdminReviewSummary {
  source?: Object;
  review_kind?: Object;
  external_id?: Object;
  rating?: Object;
  source_time?: Object;
  source_url?: Object;
  summary?: Object;
}

export interface AdminCapabilityFailure {
  external_id?: string;
  error_code?: string;
  error_message?: string;
}

export interface AdminUserConnectionHealth {
  installation_id?: number;
  health?: string;
  count?: number;
}

/**
 * builtin_state 条目：各内置插件 `status()` 的自报状态（字段因插件而异）。
 * 当前已知来源：`webserver/plugins/source/opds.py::_status`（configured/enabled/service_enabled）、
 * `webserver/plugins/tool/base.py::status`。
 */
export interface AdminPluginServiceState {
  configured?: number;
  enabled?: number;
  service_enabled?: boolean;
}

export interface AdminPluginMetadataPrefs {
  auto_fill_meta?: boolean;
  auto_fill_keep_cover?: boolean;
}

export interface AdminBookToolAction {
  plugin_key?: string;
  name?: string;
  icon?: string;
  route?: string;
}

export interface AdminToolBookOption {
  id?: number;
  title?: string;
  authors?: string[];
  formats?: string[];
  timestamp?: string;
}

export interface AdminTextReplaceSample {
  index?: number;
  pre?: string;
  match?: string;
  post?: string;
}

// ---------------------------------------------------------------------------
// 请求载荷
// ---------------------------------------------------------------------------

export interface AdminPluginInstallPayload {
  plugin_key: string;
  config?: Record<string, Object>;
  permissions?: string[];
}

export interface AdminPluginConnectionPayload {
  installation_id: number;
  name?: string;
  role?: string;
  credentials?: Record<string, Object>;
  config?: Record<string, Object>;
  scopes?: string[];
  schedule?: string;
}

export interface AdminPluginActionPayload {
  input_data?: Record<string, Object>;
  trigger?: string;
  parent_run_id?: number;
}

export interface AdminPluginPreferencesPayload {
  metadata?: AdminPluginMetadataPrefs;
  devices?: Array<Record<string, Object>>;
}

export interface AdminMetadataQuery {
  title?: string;
  isbn?: string;
  publisher?: string;
  authors?: string[];
}

export interface AdminMetadataSearchPayload {
  query: AdminMetadataQuery;
}

export interface AdminSourceSearchPayload {
  query: string;
}

export interface AdminTextReplacePayload {
  book_id: number;
  pattern: string;
  replacement: string;
  use_regex: boolean;
}

export interface AdminTextReplaceRunPayload {
  book_id: number;
  pattern: string;
  replacement: string;
  use_regex: boolean;
  output_mode: string;
  suffix?: string;
}

export interface AdminTxtFixerRunPayload {
  book_id: number;
  output_mode: string;
}

export interface AdminZhConverterRunPayload {
  book_id: number;
  direction: string;
  use_a5: boolean;
  convert_title: boolean;
  backup: boolean;
  output_mode: string;
}

// ---------------------------------------------------------------------------
// 响应
// ---------------------------------------------------------------------------

export interface AdminPluginsResponse extends ApiMessageResult {
  definitions?: AdminPluginDefinition[];
  installations?: AdminPluginInstallation[];
  builtin_state?: Record<string, AdminPluginServiceState>;
}

export interface AdminPluginInstallResponse extends ApiMessageResult {
  installation?: AdminPluginInstallation;
}

export interface AdminPluginOpdsServiceResponse extends ApiMessageResult {
  enabled?: boolean;
}

export interface AdminPluginConnectionsResponse extends ApiMessageResult {
  connections?: AdminPluginConnection[];
  user_connection_health?: AdminUserConnectionHealth[];
}

export interface AdminPluginConnectionResponse extends ApiMessageResult {
  connection?: AdminPluginConnection;
}

export interface AdminPluginRunResponse extends ApiMessageResult {
  run?: AdminPluginRun;
}

export interface AdminPluginRunsResponse extends ApiMessageResult {
  runs?: AdminPluginRun[];
}

export interface AdminPluginRunDetailResponse extends ApiMessageResult {
  run?: AdminPluginRun;
  items?: AdminPluginRunItem[];
}

export interface AdminPluginStateResponse extends ApiMessageResult {
  plugin?: AdminPluginDefinition;
  installation?: AdminPluginInstallation;
  connections?: AdminPluginConnection[];
  runs?: AdminPluginRun[];
}

export interface AdminPluginPreferencesResponse extends ApiMessageResult {
  metadata?: AdminPluginMetadataPrefs;
  devices?: Array<Record<string, Object>>;
}

export interface AdminPluginFeatureResponse extends ApiMessageResult {
  connection?: AdminPluginConnection;
  data?: Object;
}

export interface AdminPluginMetadataSearchResponse extends ApiMessageResult {
  capability?: string;
  items?: AdminMetadataSummary[];
}

export interface AdminPluginSourceSearchResponse extends ApiMessageResult {
  capability?: string;
  items?: AdminSourceSummary[];
  failures?: AdminCapabilityFailure[];
  has_more?: boolean;
  health_message?: string;
}

export interface AdminPluginReviewLookupResponse extends ApiMessageResult {
  capability?: string;
  items?: AdminReviewSummary[];
  failures?: AdminCapabilityFailure[];
  has_more?: boolean;
  health_message?: string;
}

export interface AdminBookToolActionsResponse extends ApiMessageResult {
  actions?: AdminBookToolAction[];
}

export interface AdminToolBooksResponse extends ApiMessageResult {
  books?: AdminToolBookOption[];
  total?: number;
}

export interface AdminTextReplacePreviewResponse extends ApiMessageResult {
  format?: string;
  matches?: number;
  samples?: AdminTextReplaceSample[];
  regex_error?: string;
  truncated?: boolean;
  book_id?: number;
}

/** text-replace / txt-fixer / zh-converter 的 run 输出（字段并集，按插件出现）。 */
export interface AdminToolRunResponse extends ApiMessageResult {
  path?: string;
  format?: string;
  matches?: number;
  book_id?: number;
  output_mode?: string;
  backup_path?: string;
  encoding?: string;
  mojibake?: boolean;
  report?: Record<string, Object>;
  direction?: string;
  direction_label?: string;
  language?: string;
  source_encoding?: string;
  converted_title?: string;
  converted_authors?: string[];
}

export interface AdminTxtFixerAnalyzeResponse extends ApiMessageResult {
  encoding?: string;
  confidence?: Object;
  mojibake?: boolean;
  garbage?: boolean;
  unrecoverable?: boolean;
  sample?: string;
  preview?: string;
  reasons?: string[];
  book_id?: number;
}

export class AdminPluginsApi {
  /** 插件目录与安装状态（GET /api/admin/plugins）。 */
  static async listPlugins(): Promise<AdminPluginsResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/plugins');
    return JSON.parse(raw) as AdminPluginsResponse;
  }

  /**
   * 单个插件的清单、安装态、连接与最近运行（GET /api/plugins/{plugin_key}）。
   * 该接口的 `plugin` 含 `extra_features` / `ui`，用于枚举插件 features。
   */
  static async getPluginState(pluginKey: string): Promise<AdminPluginStateResponse> {
    const raw = await TalebookCoreService.talebookGet(`/api/plugins/${encodeURIComponent(pluginKey)}`);
    return JSON.parse(raw) as AdminPluginStateResponse;
  }

  /** 安装/更新内置插件（POST /api/admin/plugins/install）。 */
  static async installPlugin(pluginKey: string, permissions: string[],
    config: Record<string, Object>): Promise<AdminPluginInstallResponse> {
    const payload: AdminPluginInstallPayload = {
      plugin_key: pluginKey,
      config: config,
      permissions: permissions,
    };
    const raw = await TalebookCoreService.talebookPost('/api/admin/plugins/install',
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminPluginInstallResponse;
  }

  /** 启停插件安装（POST /api/admin/plugins/installations/{id}/state）。 */
  static async setInstallationEnabled(installationId: number, enabled: boolean):
    Promise<AdminPluginInstallResponse> {
    const payload: Record<string, Object> = { 'enabled': enabled };
    const raw = await TalebookCoreService.talebookPost(
      `/api/admin/plugins/installations/${installationId}/state`, JSON.stringify(payload));
    return JSON.parse(raw) as AdminPluginInstallResponse;
  }

  /** 切换服务端 OPDS 总开关（POST /api/admin/plugins/opds-service）。 */
  static async setOpdsServiceEnabled(enabled: boolean): Promise<AdminPluginOpdsServiceResponse> {
    const payload: Record<string, Object> = { 'enabled': enabled };
    const raw = await TalebookCoreService.talebookPost('/api/admin/plugins/opds-service',
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminPluginOpdsServiceResponse;
  }

  /** 实例级连接列表（GET /api/admin/plugins/connections）。 */
  static async listConnections(): Promise<AdminPluginConnectionsResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/plugins/connections');
    return JSON.parse(raw) as AdminPluginConnectionsResponse;
  }

  /**
   * 新增/更新实例级连接（POST /api/admin/plugins/connections）。
   * 上游固定 `owner_type=instance`；`role` 是查询键（不传会按名字回退定位）。
   */
  static async saveConnection(payload: AdminPluginConnectionPayload):
    Promise<AdminPluginConnectionResponse> {
    const raw = await TalebookCoreService.talebookPost('/api/admin/plugins/connections',
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminPluginConnectionResponse;
  }

  /** 启停连接（POST /api/admin/plugins/connections/{id}/state）。 */
  static async setConnectionEnabled(connectionId: number, enabled: boolean):
    Promise<AdminPluginConnectionResponse> {
    const payload: Record<string, Object> = { 'enabled': enabled };
    const raw = await TalebookCoreService.talebookPost(
      `/api/admin/plugins/connections/${connectionId}/state`, JSON.stringify(payload));
    return JSON.parse(raw) as AdminPluginConnectionResponse;
  }

  /**
   * 连接动作（POST /api/admin/plugins/connections/{id}/{action}）。
   * action 取 PLUGIN_ACTION_* 常量；run|retry|rollback 会写库，UI 侧需二次确认。
   */
  static async runConnectionAction(connectionId: number, action: string,
    payload: AdminPluginActionPayload): Promise<AdminPluginRunResponse> {
    const path = `/api/admin/plugins/connections/${connectionId}/${encodeURIComponent(action)}`;
    const raw = await TalebookCoreService.talebookPost(path, JSON.stringify(payload));
    return JSON.parse(raw) as AdminPluginRunResponse;
  }

  /** 运行记录（GET /api/admin/plugins/runs?connection_id=&include_items=）。 */
  static async listRuns(connectionId: number = 0, includeItems: boolean = false):
    Promise<AdminPluginRunsResponse> {
    let query = `?include_items=${includeItems ? 'true' : 'false'}`;
    if (connectionId > 0) {
      query += `&connection_id=${connectionId}`;
    }
    const raw = await TalebookCoreService.talebookGet(`/api/admin/plugins/runs${query}`);
    return JSON.parse(raw) as AdminPluginRunsResponse;
  }

  /** 运行详情（GET /api/admin/plugins/runs/{id}，items 带 data）。 */
  static async getRunDetail(runId: number): Promise<AdminPluginRunDetailResponse> {
    const raw = await TalebookCoreService.talebookGet(`/api/admin/plugins/runs/${runId}`);
    return JSON.parse(raw) as AdminPluginRunDetailResponse;
  }

  /** 插件自有功能逃生舱（POST /api/plugins/{plugin_key}/features/{action}）。 */
  static async invokeFeature(pluginKey: string, action: string, params: Record<string, Object>,
    credentials: Record<string, Object> | undefined = undefined):
    Promise<AdminPluginFeatureResponse> {
    const payload: Record<string, Object> = { 'params': params };
    if (credentials !== undefined) {
      payload['credentials'] = credentials;
    }
    const path = `/api/plugins/${encodeURIComponent(pluginKey)}/features/${encodeURIComponent(action)}`;
    const raw = await TalebookCoreService.talebookPost(path, JSON.stringify(payload));
    return JSON.parse(raw) as AdminPluginFeatureResponse;
  }

  /** 元数据能力联调（POST /api/admin/plugins/{plugin_key}/metadata/search）。 */
  static async searchMetadata(pluginKey: string, query: AdminMetadataQuery):
    Promise<AdminPluginMetadataSearchResponse> {
    const payload: AdminMetadataSearchPayload = { query: query };
    const raw = await TalebookCoreService.talebookPost(
      `/api/admin/plugins/${encodeURIComponent(pluginKey)}/metadata/search`,
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminPluginMetadataSearchResponse;
  }

  /** 书源能力联调（POST /api/admin/plugins/{plugin_key}/source/search）。 */
  static async searchSources(pluginKey: string, query: string):
    Promise<AdminPluginSourceSearchResponse> {
    const payload: AdminSourceSearchPayload = { query: query };
    const raw = await TalebookCoreService.talebookPost(
      `/api/admin/plugins/${encodeURIComponent(pluginKey)}/source/search`,
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminPluginSourceSearchResponse;
  }

  /** 书评能力联调（POST /api/admin/plugins/{plugin_key}/reviews/lookup）。 */
  static async lookupReviews(pluginKey: string, query: AdminMetadataQuery):
    Promise<AdminPluginReviewLookupResponse> {
    const payload: AdminMetadataSearchPayload = { query: query };
    const raw = await TalebookCoreService.talebookPost(
      `/api/admin/plugins/${encodeURIComponent(pluginKey)}/reviews/lookup`,
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminPluginReviewLookupResponse;
  }

  /** 插件偏好（GET /api/admin/plugins/preferences）。 */
  static async getPreferences(): Promise<AdminPluginPreferencesResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/plugins/preferences');
    return JSON.parse(raw) as AdminPluginPreferencesResponse;
  }

  /** 保存插件偏好（POST /api/admin/plugins/preferences）。 */
  static async savePreferences(payload: AdminPluginPreferencesPayload):
    Promise<AdminPluginPreferencesResponse> {
    const raw = await TalebookCoreService.talebookPost('/api/admin/plugins/preferences',
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminPluginPreferencesResponse;
  }

  // -------------------------------------------------------------------------
  // 插件提供的正文工具
  // -------------------------------------------------------------------------

  /** 当前书籍可用的实例级工具动作（GET /api/plugins/tools/book-actions?book_id=）。 */
  static async getBookToolActions(bookId: number): Promise<AdminBookToolActionsResponse> {
    const raw = await TalebookCoreService.talebookGet(
      `/api/plugins/tools/book-actions?book_id=${bookId}`);
    return JSON.parse(raw) as AdminBookToolActionsResponse;
  }

  /** 可作为工具输入的书籍（GET /api/plugins/tools/books?query=，最多 100 本）。 */
  static async listToolBooks(keyword: string): Promise<AdminToolBooksResponse> {
    const raw = await TalebookCoreService.talebookGet(
      `/api/plugins/tools/books?query=${encodeURIComponent(keyword)}`);
    return JSON.parse(raw) as AdminToolBooksResponse;
  }

  /** 单本书籍校验（GET /api/plugins/tools/books?book_id=）。 */
  static async getToolBook(bookId: number): Promise<AdminToolBooksResponse> {
    const raw = await TalebookCoreService.talebookGet(
      `/api/plugins/tools/books?book_id=${bookId}`);
    return JSON.parse(raw) as AdminToolBooksResponse;
  }

  /** 正文替换预览（POST /api/plugins/tools/text-replace/preview，只读）。 */
  static async textReplacePreview(payload: AdminTextReplacePayload):
    Promise<AdminTextReplacePreviewResponse> {
    const raw = await TalebookCoreService.talebookPost(
      '/api/plugins/tools/text-replace/preview', JSON.stringify(payload));
    return JSON.parse(raw) as AdminTextReplacePreviewResponse;
  }

  /** 正文替换执行（POST /api/plugins/tools/text-replace/run，写库，需二次确认）。 */
  static async textReplaceRun(payload: AdminTextReplaceRunPayload): Promise<AdminToolRunResponse> {
    const raw = await TalebookCoreService.talebookPost(
      '/api/plugins/tools/text-replace/run', JSON.stringify(payload));
    return JSON.parse(raw) as AdminToolRunResponse;
  }

  /** TXT 编码检测（POST /api/plugins/tools/txt-fixer/analyze，只读）。 */
  static async txtFixerAnalyze(bookId: number): Promise<AdminTxtFixerAnalyzeResponse> {
    const payload: Record<string, Object> = { 'book_id': bookId };
    const raw = await TalebookCoreService.talebookPost(
      '/api/plugins/tools/txt-fixer/analyze', JSON.stringify(payload));
    return JSON.parse(raw) as AdminTxtFixerAnalyzeResponse;
  }

  /** TXT 编码修复执行（POST /api/plugins/tools/txt-fixer/run，写库，需二次确认）。 */
  static async txtFixerRun(payload: AdminTxtFixerRunPayload): Promise<AdminToolRunResponse> {
    const raw = await TalebookCoreService.talebookPost(
      '/api/plugins/tools/txt-fixer/run', JSON.stringify(payload));
    return JSON.parse(raw) as AdminToolRunResponse;
  }

  /**
   * 繁简转换执行（POST /api/plugins/tools/zh-converter/run，写库，需二次确认）。
   * 上游无 HTTP preview 路由，预览请用方向与词表说明代替。
   */
  static async zhConverterRun(payload: AdminZhConverterRunPayload): Promise<AdminToolRunResponse> {
    const raw = await TalebookCoreService.talebookPost(
      '/api/plugins/tools/zh-converter/run', JSON.stringify(payload));
    return JSON.parse(raw) as AdminToolRunResponse;
  }
}
