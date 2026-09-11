import { TalebookCoreService } from './TalebookCoreService';
import { NetworkBookDetail, NetworkBookItem, NetworkLibraryApi } from './NetworkLibraryApi';

/**
 * 书源管理 API（管理员，talebook 上游专有，Legado 风格书源）。
 *
 * 端点核对依据：`docs/talebook/webserver/handlers/booksource_admin.py::routes()`。
 *
 *   GET    /api/admin/booksource/list?enabled=&group=&q=&page=&size=
 *          → BookSourceList.get（`enabled` 取 `1|true|0|false`；`size` 默认 50、上限 200）
 *          返回 `{err, items[], count, page, size, groups[], check_task{}}`；
 *          `items[]` = `BookSourceModel.to_summary_dict()`。
 *   GET    /api/admin/booksource/export
 *          → BookSourceExport.get，返回 `{err, sources[]}`（可直接再次导入的 Legado 原始对象）。
 *   POST   /api/admin/booksource        → BookSourceCRUD.post，body `{raw}`（对象或 JSON 字符串）
 *          返回 `{err, id}`；同 URL 已存在时返回 `err=params.exist`。
 *   PUT    /api/admin/booksource        → BookSourceCRUD.put，body `{id, group, weight, raw, enabled}`
 *   DELETE /api/admin/booksource?ids=1&ids=2
 *          → BookSourceCRUD.delete，返回 `{err, deleted}`（上游优先从查询参数取 ids）。
 *   POST   /api/admin/booksource/import → BookSourceImport.post，body `{json}` 或 `{url}`
 *   POST   /api/admin/booksource/seed   → BookSourceSeed.post（导入仓库内置种子书源）
 *   POST   /api/admin/booksource/toggle → BookSourceToggle.post，body `{ids[], enabled}`
 *          返回 `{err, updated, enabled}`
 *   POST   /api/admin/booksource/check  → BookSourceCheckAll.post（触发全量检测，异步）
 *          返回 `{err, checked, checking, started, ...status}`
 *   GET    /api/admin/booksource/check/status → BookSourceCheckStatus.get（轮询体检进度）
 *   POST   /api/admin/booksource/clean-invalid → BookSourceCleanInvalid.post
 *          （= BookSourceCheckAll，上游已不删除书源，仅触发检测）
 *   POST   /api/admin/booksource/test   → BookSourceTest.post，body `{id, key}`（key 默认「剑来」）
 *          返回 `{err, js_skipped, search[], info{}, toc_count, sample_content, elapsed_ms}`
 *
 * 导入 / 种子 / 检测的统计字段对齐上游 `import_sources()`：`{added, updated, skipped,
 * disabled, failed[], checking, check_task}`（`overwrite` 恒为 False，同 URL 一律跳过）。
 * 检测任务状态对齐 `BookSourceCheckService.status()`：`{running, total, done, pending,
 * last_start, last_end, last_error}`；检测完成的源会被上游自动置为 `enabled = ok`。
 */

/** 书源筛选：全部。 */
export const BOOK_SOURCE_ENABLED_ALL: string = '';
/** 书源筛选：仅启用。 */
export const BOOK_SOURCE_ENABLED_ONLY: string = '1';
/** 书源筛选：仅停用。 */
export const BOOK_SOURCE_ENABLED_DISABLED: string = '0';

/** 检测状态：等待后台检测（刚导入时上游写入的占位状态）。 */
export const BOOK_SOURCE_CHECK_PENDING: string = 'pending';
/** 检测状态：检测通过。 */
export const BOOK_SOURCE_CHECK_OK: string = 'ok';

/** `{err, msg}` 响应公共字段。 */
export interface BookSourceApiResult {
  err?: string;
  msg?: string;
}

/** 归一化后的书源条目（`BookSourceModel.to_summary_dict()`）。 */
export interface BookSourceItem {
  id: number;
  name: string;
  url: string;
  group: string;
  sourceType: number;
  enabled: boolean;
  weight: number;
  comment: string;
  lastCheckOk: boolean;
  /** `ok` / `failed` / `pending` / `js_unsupported` / `incomplete` / `dns_failed` … */
  checkStatus: string;
  checkMessage: string;
  checkTags: string[];
  createTime: string;
  updateTime: string;
}

/** 归一化后的检测任务快照（`BookSourceCheckService.status()`）。 */
export interface BookSourceCheckTask {
  running: boolean;
  total: number;
  done: number;
  pending: number;
  lastStart: string;
  lastEnd: string;
  lastError: string;
}

/** `GET /api/admin/booksource/list` 响应。 */
export interface BookSourceListResponse extends BookSourceApiResult {
  /** 原始 `items` 数组，用 `parseBookSources` 转换。 */
  items?: Object;
  count?: number;
  page?: number;
  size?: number;
  /** 已出现的分组名（字符串数组）。 */
  groups?: Object;
  /** 原始 `check_task` 对象，用 `parseCheckTask` 转换。 */
  check_task?: Object;
}

/** `GET /api/admin/booksource/export` 响应。 */
export interface BookSourceExportResponse extends BookSourceApiResult {
  /** 可再次导入的 Legado 原始对象数组。 */
  sources?: Object;
}

/** 归一化后的导入统计（上游 `import_sources()`）。 */
export interface BookSourceImportStats {
  added: number;
  updated: number;
  skipped: number;
  disabled: number;
  failed: BookSourceImportFailure[];
  /** 本次进入后台检测的书源数量。 */
  checking: number;
  /** 检测任务标记（`queued` 表示已排队，空串表示无）。 */
  checkTask: string;
}

/** 导入失败条目。 */
export interface BookSourceImportFailure {
  name: string;
  /** `invalid` / `missing_fields` … */
  reason: string;
}

/** 导入 / 种子响应（含统计字段）。 */
export interface BookSourceImportResponse extends BookSourceApiResult {
  added?: number;
  updated?: number;
  skipped?: number;
  disabled?: number;
  /** 原始 `failed` 数组，用 `parseImportStats` 转换。 */
  failed?: Object;
  checking?: number;
  check_task?: string;
}

/** `POST /api/admin/booksource` 响应。 */
export interface BookSourceCreateResponse extends BookSourceApiResult {
  id?: number;
}

/** `POST /api/admin/booksource/toggle` 响应。 */
export interface BookSourceToggleResponse extends BookSourceApiResult {
  updated?: number;
  enabled?: boolean;
}

/** `DELETE /api/admin/booksource` 响应。 */
export interface BookSourceDeleteResponse extends BookSourceApiResult {
  deleted?: number;
}

/** 触发检测（check / clean-invalid）响应：在任务状态上追加本次触发信息。 */
export interface BookSourceCheckResponse extends BookSourceApiResult {
  checked?: number;
  checking?: number;
  started?: boolean;
  running?: boolean;
  total?: number;
  done?: number;
  pending?: number;
  last_start?: string;
  last_end?: string;
  last_error?: string;
}

/** 检测状态查询响应。 */
export interface BookSourceCheckStatusResponse extends BookSourceApiResult {
  running?: boolean;
  total?: number;
  done?: number;
  pending?: number;
  last_start?: string;
  last_end?: string;
  last_error?: string;
}

/** `POST /api/admin/booksource/test` 响应。 */
export interface BookSourceTestResponse extends BookSourceApiResult {
  js_skipped?: boolean;
  /** 搜索结果（`BookSummary.to_dict()` 数组）。 */
  search?: Object;
  /** 首本书的详情（`BookDetail.to_dict()`）。 */
  info?: Object;
  toc_count?: number;
  sample_content?: string;
  elapsed_ms?: number;
}

/** 归一化后的书源连通性测试结果。 */
export interface BookSourceTestSummary {
  /** 上游判定关键规则依赖 JS 时置位（此时不会返回结果）。 */
  jsSkipped: boolean;
  books: NetworkBookItem[];
  info: NetworkBookDetail | null;
  tocCount: number;
  sampleContent: string;
  elapsedMs: number;
  /** 是否测试成功（上游 `ok = err === 'ok' && 有搜索结果`）。 */
  ok: boolean;
}

/** `POST /api/admin/booksource` / `PUT` 使用的路径。 */
const BOOK_SOURCE_ITEM_PATH: string = '/api/admin/booksource';

/** 追加查询参数（空值跳过）。 */
function bsQuery(path: string, key: string, value: string): string {
  if (value.length === 0) {
    return path;
  }
  const separator = path.indexOf('?') >= 0 ? '&' : '?';
  return `${path}${separator}${key}=${encodeURIComponent(value)}`;
}

/** 读字符串字段（缺失/null 返回回退值）。 */
function bsText(raw: Record<string, Object>, key: string, fallback: string = ''): string {
  const value = raw[key];
  if (value === undefined || value === null) {
    return fallback;
  }
  const text = `${value}`;
  return text === 'undefined' || text === 'null' ? fallback : text;
}

/** 读数字字段（缺失/非数字返回回退值）。 */
function bsCount(raw: Record<string, Object>, key: string, fallback: number = 0): number {
  const value = raw[key];
  if (value === undefined || value === null) {
    return fallback;
  }
  const parsed = Number(`${value}`);
  return Number.isNaN(parsed) ? fallback : parsed;
}

/** 读布尔字段（仅 `true` 为真）。 */
function bsFlag(raw: Record<string, Object>, key: string): boolean {
  return raw[key] === true;
}

/** 对象字段 → `Record`；缺失/null/数组/非对象返回 null。 */
function bsMap(value: Object | undefined): Record<string, Object> | null {
  if (value === undefined || value === null || Array.isArray(value)) {
    return null;
  }
  if (typeof value !== 'object') {
    return null;
  }
  return value as Record<string, Object>;
}

/** 对象数组字段 → `Record[]`。 */
function bsRows(value: Object | undefined): Array<Record<string, Object>> {
  if (value === undefined || value === null || !Array.isArray(value)) {
    return [];
  }
  const rows: Array<Record<string, Object>> = [];
  for (const item of value as Array<Object>) {
    if (item !== undefined && item !== null && !Array.isArray(item) && typeof item === 'object') {
      rows.push(item as Record<string, Object>);
    }
  }
  return rows;
}

/** 字符串数组字段。 */
function bsTexts(value: Object | undefined): string[] {
  if (value === undefined || value === null || !Array.isArray(value)) {
    return [];
  }
  const texts: string[] = [];
  for (const item of value as Array<Object>) {
    if (item !== undefined && item !== null) {
      texts.push(`${item}`);
    }
  }
  return texts;
}

/** `POST /api/admin/booksource` 请求体（上游允许 raw 为 JSON 字符串）。 */
interface BookSourceRawBody {
  raw: string;
}

/** `PUT /api/admin/booksource` 请求体。 */
interface BookSourceUpdateBody {
  id: number;
  group: string;
  weight: number;
  enabled: boolean;
}

/** `POST /api/admin/booksource/import` 请求体。 */
interface BookSourceImportBody {
  json?: string;
  url?: string;
}

/** `POST /api/admin/booksource/toggle` 请求体。 */
interface BookSourceToggleBody {
  ids: number[];
  enabled: boolean;
}

/** `POST /api/admin/booksource/test` 请求体。 */
interface BookSourceTestBody {
  id: number;
  key: string;
}

export class BookSourceApi {
  /** 响应是否成功。 */
  static isOk(rsp: BookSourceApiResult): boolean {
    return rsp.err === undefined || rsp.err === 'ok';
  }

  /** 取服务端错误提示（优先 msg，回退 err；成功时返回空串）。 */
  static errorMessage(rsp: BookSourceApiResult): string {
    if (BookSourceApi.isOk(rsp)) {
      return '';
    }
    const msg = rsp.msg;
    if (msg !== undefined && msg.length > 0) {
      return msg;
    }
    return rsp.err ?? '';
  }

  /** 书源列表：`GET /api/admin/booksource/list`（分页为 `page`/`size`）。 */
  static async listSources(enabled: string, group: string, q: string, page: number,
    size: number): Promise<BookSourceListResponse> {
    let path = '/api/admin/booksource/list';
    path = bsQuery(path, 'enabled', enabled);
    path = bsQuery(path, 'group', group);
    path = bsQuery(path, 'q', q.trim());
    path = bsQuery(path, 'page', `${page > 0 ? page : 1}`);
    path = bsQuery(path, 'size', `${size > 0 ? size : 50}`);
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as BookSourceListResponse;
  }

  /** 导出全部书源（Legado 原始对象数组）：`GET /api/admin/booksource/export`。 */
  static async exportSources(): Promise<BookSourceExportResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/booksource/export');
    return JSON.parse(raw) as BookSourceExportResponse;
  }

  /** 新增书源（同 URL 已存在时上游返回 `params.exist`）：`POST /api/admin/booksource`。 */
  static async createSource(rawJson: string): Promise<BookSourceCreateResponse> {
    const body: BookSourceRawBody = { raw: rawJson };
    const raw = await TalebookCoreService.talebookPost(BOOK_SOURCE_ITEM_PATH, JSON.stringify(body));
    return JSON.parse(raw) as BookSourceCreateResponse;
  }

  /**
   * 编辑书源（分组 / 权重 / 启停）：`PUT /api/admin/booksource`（BookSourceCRUD.put），
   * body `{id, group, weight, enabled}`。
   */
  static async updateSource(id: number, group: string, weight: number,
    enabled: boolean): Promise<BookSourceApiResult> {
    const body: BookSourceUpdateBody = {
      id: id,
      group: group.trim(),
      weight: weight,
      enabled: enabled,
    };
    const raw = await TalebookCoreService.talebookPut(BOOK_SOURCE_ITEM_PATH, JSON.stringify(body));
    return JSON.parse(raw) as BookSourceApiResult;
  }

  /** 删除书源（上游优先从查询参数取 id）：`DELETE /api/admin/booksource?ids=`。 */
  static async deleteSources(ids: number[]): Promise<BookSourceDeleteResponse> {
    let path: string = BOOK_SOURCE_ITEM_PATH;
    for (const id of ids) {
      path = bsQuery(path, 'ids', `${id}`);
    }
    const raw = await TalebookCoreService.talebookDelete(path);
    return JSON.parse(raw) as BookSourceDeleteResponse;
  }

  /**
   * 批量启用 / 停用：`POST /api/admin/booksource/toggle`。
   * 指定 `enabled` 时上游走批量 update，返回 `{updated, enabled}`。
   */
  static async toggleSources(ids: number[], enabled: boolean): Promise<BookSourceToggleResponse> {
    const body: BookSourceToggleBody = { ids: ids, enabled: enabled };
    const raw = await TalebookCoreService.talebookPost('/api/admin/booksource/toggle',
      JSON.stringify(body));
    return JSON.parse(raw) as BookSourceToggleResponse;
  }

  /** 从粘贴的 JSON 批量导入：`POST /api/admin/booksource/import`（body `{json}`）。 */
  static async importSources(jsonText: string): Promise<BookSourceImportResponse> {
    const body: BookSourceImportBody = { json: jsonText };
    const raw = await TalebookCoreService.talebookPost('/api/admin/booksource/import',
      JSON.stringify(body));
    return JSON.parse(raw) as BookSourceImportResponse;
  }

  /** 从远端 URL 拉取并导入：`POST /api/admin/booksource/import`（body `{url}`）。 */
  static async importFromUrl(url: string): Promise<BookSourceImportResponse> {
    const body: BookSourceImportBody = { url: url.trim() };
    const raw = await TalebookCoreService.talebookPost('/api/admin/booksource/import',
      JSON.stringify(body));
    return JSON.parse(raw) as BookSourceImportResponse;
  }

  /** 导入仓库内置种子书源：`POST /api/admin/booksource/seed`。 */
  static async fillSeeds(): Promise<BookSourceImportResponse> {
    const raw = await TalebookCoreService.talebookPost('/api/admin/booksource/seed', '{}');
    return JSON.parse(raw) as BookSourceImportResponse;
  }

  /** 触发全量有效性检测（异步）：`POST /api/admin/booksource/check`。 */
  static async checkAll(): Promise<BookSourceCheckResponse> {
    const raw = await TalebookCoreService.talebookPost('/api/admin/booksource/check', '{}');
    return JSON.parse(raw) as BookSourceCheckResponse;
  }

  /** 查询检测任务进度：`GET /api/admin/booksource/check/status`。 */
  static async getCheckStatus(): Promise<BookSourceCheckStatusResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/booksource/check/status');
    return JSON.parse(raw) as BookSourceCheckStatusResponse;
  }

  /**
   * 清理无效书源：`POST /api/admin/booksource/clean-invalid`。
   * 上游该类直接继承 BookSourceCheckAll，**只触发检测、不再删除书源**（检测结束后
   * 未通过的书源会被置为停用）。
   */
  static async cleanInvalid(): Promise<BookSourceCheckResponse> {
    const raw = await TalebookCoreService.talebookPost('/api/admin/booksource/clean-invalid', '{}');
    return JSON.parse(raw) as BookSourceCheckResponse;
  }

  /** 关键词测试书源：`POST /api/admin/booksource/test`（`key` 留空时上游用「剑来」）。 */
  static async testSource(id: number, key: string): Promise<BookSourceTestResponse> {
    const body: BookSourceTestBody = { id: id, key: key.trim() };
    const raw = await TalebookCoreService.talebookPost('/api/admin/booksource/test',
      JSON.stringify(body));
    return JSON.parse(raw) as BookSourceTestResponse;
  }

  /** 解析 `GET /api/admin/booksource/list` 的 `items`。 */
  static parseBookSources(value: Object | undefined): BookSourceItem[] {
    const items: BookSourceItem[] = [];
    for (const row of bsRows(value)) {
      items.push({
        id: bsCount(row, 'id'),
        name: bsText(row, 'name'),
        url: bsText(row, 'url'),
        group: bsText(row, 'group'),
        sourceType: bsCount(row, 'source_type'),
        enabled: bsFlag(row, 'enabled'),
        weight: bsCount(row, 'weight'),
        comment: bsText(row, 'comment'),
        lastCheckOk: bsFlag(row, 'last_check_ok'),
        checkStatus: bsText(row, 'check_status', 'failed'),
        checkMessage: bsText(row, 'check_message'),
        checkTags: bsTexts(row['check_tags']),
        createTime: bsText(row, 'create_time'),
        updateTime: bsText(row, 'update_time'),
      });
    }
    return items;
  }

  /** 解析检测任务快照（`list` 响应的 `check_task` 对象）。 */
  static parseCheckTask(value: Object | undefined): BookSourceCheckTask {
    const row = bsMap(value);
    if (row === null) {
      return {
        running: false,
        total: 0,
        done: 0,
        pending: 0,
        lastStart: '',
        lastEnd: '',
        lastError: '',
      };
    }
    return {
      running: bsFlag(row, 'running'),
      total: bsCount(row, 'total'),
      done: bsCount(row, 'done'),
      pending: bsCount(row, 'pending'),
      lastStart: bsText(row, 'last_start'),
      lastEnd: bsText(row, 'last_end'),
      lastError: bsText(row, 'last_error'),
    };
  }

  /** 解析 check/status 响应体（字段直接位于响应对象上，非嵌套）。 */
  static parseCheckStatus(rsp: BookSourceCheckStatusResponse): BookSourceCheckTask {
    return {
      running: rsp.running === true,
      total: rsp.total !== undefined ? rsp.total : 0,
      done: rsp.done !== undefined ? rsp.done : 0,
      pending: rsp.pending !== undefined ? rsp.pending : 0,
      lastStart: rsp.last_start !== undefined ? rsp.last_start : '',
      lastEnd: rsp.last_end !== undefined ? rsp.last_end : '',
      lastError: rsp.last_error !== undefined ? rsp.last_error : '',
    };
  }

  /** 解析导入 / 种子统计。 */
  static parseImportStats(rsp: BookSourceImportResponse): BookSourceImportStats {
    const failed: BookSourceImportFailure[] = [];
    for (const row of bsRows(rsp.failed)) {
      failed.push({
        name: bsText(row, 'name', 'unknown'),
        reason: bsText(row, 'reason'),
      });
    }
    return {
      added: rsp.added !== undefined ? rsp.added : 0,
      updated: rsp.updated !== undefined ? rsp.updated : 0,
      skipped: rsp.skipped !== undefined ? rsp.skipped : 0,
      disabled: rsp.disabled !== undefined ? rsp.disabled : 0,
      failed: failed,
      checking: rsp.checking !== undefined ? rsp.checking : 0,
      checkTask: rsp.check_task !== undefined ? rsp.check_task : '',
    };
  }

  /** 解析测试结果（`search` 复用书源搜索的书籍解析器）。 */
  static parseTestSummary(rsp: BookSourceTestResponse): BookSourceTestSummary {
    const books = NetworkLibraryApi.parseNetworkBooks(rsp.search, '', '');
    return {
      jsSkipped: rsp.js_skipped === true,
      books: books,
      info: NetworkLibraryApi.parseNetworkBookDetail(rsp.info, '', ''),
      tocCount: rsp.toc_count !== undefined ? rsp.toc_count : 0,
      sampleContent: rsp.sample_content !== undefined ? rsp.sample_content : '',
      elapsedMs: rsp.elapsed_ms !== undefined ? rsp.elapsed_ms : 0,
      ok: BookSourceApi.isOk(rsp) && books.length > 0,
    };
  }
}
