import { TalebookCoreService } from './TalebookCoreService';

/**
 * 网络书库（书源搜索 / 发现 / 详情 / 目录 / 正文 / 保存）API —— talebook 上游专有。
 *
 * 端点核对依据：`docs/talebook/webserver/handlers/network_library.py::routes()`。
 * 上游同时注册了标准入口 `/api/book-sources*` 与一版过渡别名 `/api/network/*`，
 * 本封装统一使用**标准入口**（上游注释标注 `/api/network/*` 为兼容别名）：
 *
 *   GET  /api/book-sources                    → NetworkSources.get
 *        `{err, items[], availability{state, enabled_plugins, configured_sources}}`
 *        `items[]` = `SourceBinding.to_public_dict()`：`{id, source_key, name, group,
 *        plugin_key, capabilities[], download_mode}`；`id` 在非 Legado 绑定上是
 *        `source_key` 字符串，故统一以 `source_key` 作为后续请求的 `source_id`。
 *   GET  /api/book-sources/search?key=&page=&sources=&group=&mode=
 *        → NetworkSearch.get，创建后台搜索任务（线程池并发各源），立即返回
 *        `{err, task_id, total, mode}`；`sources` 为逗号分隔的 source_key，
 *        `mode=top|all`（仅在未指定 sources/group 时生效）。
 *   GET  /api/book-sources/search/status?task_id=
 *        → NetworkSearchStatus.get，`{err, task_id, total, done, finished,
 *        results[{source_id, source_name, books[]}], partial[{source_id, source_name, error}],
 *        pending[{source_id, source_name}]}`（`books[]` 为 `SourceBook.to_dict()`，见 legado.py::_summary）。
 *   GET  /api/book-sources/browse?source_id=&url=&page=
 *        → NetworkExplore.get，`url` 即分类 id（`Category.id`），返回 `{err, books[]}`。
 *   GET  /api/book-sources/categories?source_id=
 *        → NetworkCategories.get，`{err, items[{id, name, url}]}`（`url` 与 `id` 同值）。
 *   GET  /api/book-sources/book?source_id=&book_url=
 *        → NetworkBook.get，`{err, book, toc_url, download_mode}`；
 *        `book` = `SourceBookDetail.to_dict()`（含 `serialize_status`、`toc_url`、`book_url`）。
 *   GET  /api/book-sources/toc?source_id=&book_url=  （或 `&toc_url=`）
 *        → NetworkToc.get，`{err, chapters[], serialize_status}`；
 *        `chapters[]` = `SourceChapter.to_dict()`（`external_id`/`url`、`title`/`name`、`is_vip`）。
 *   GET  /api/book-sources/content?source_id=&chapter_url=&title=&clean=
 *        → NetworkContent.get，`{err, title, content}`（`clean=1|true` 走正文净化）。
 *   GET  /api/book-sources/save/status?source_id=&book_url=
 *        → NetworkSaveStatus.get，按 `SaveOnlineBookService.make_tag(source_id, book_url)`
 *        定位任务：`{err, found, status, progress, done, total, book_id, error}`；
 *        `status` 取值见 BackgroundTask：`running|completed|failed|cancelled`。
 *   POST /api/book-sources/save
 *        → NetworkSave.post，body `{source_id, book_url, fmt: "txt"|"epub", clean: bool}`
 *        返回 `{err, tag, msg}`（同书已在保存中会返回 err=ok + msg="该书籍正在保存中"）。
 *
 * 另（本文件不覆盖，见说明）：`/api/library/online`（本地已保存网络书列表）由
 * `services/ShelfApi.ets` 封装；`/api/network/status`（本地网络书连载状态读写，仅
 * 保留在过渡命名空间下）当前无客户端调用方，暂不封装。
 */

/** 搜索模式：仅取「近期可用」的前 K 个书源（上游 `BOOKSOURCE_SEARCH_TOP_K`）。 */
export const NETWORK_SEARCH_MODE_TOP: string = 'top';
/** 搜索模式：全部可用书源。 */
export const NETWORK_SEARCH_MODE_ALL: string = 'all';

/** 保存格式：TXT（服务端拼装后导入本地书库）。 */
export const NETWORK_SAVE_FMT_TXT: string = 'txt';
/** 保存格式：EPUB（先导 TXT，再后台转换）。 */
export const NETWORK_SAVE_FMT_EPUB: string = 'epub';

/** 可用性状态：有启用插件且有可用书源。 */
export const NETWORK_AVAILABILITY_READY: string = 'ready';
/** 可用性状态：没有启用的书源插件。 */
export const NETWORK_AVAILABILITY_NO_PLUGINS: string = 'no_enabled_plugins';
/** 可用性状态：插件已启用但没有配置任何书源。 */
export const NETWORK_AVAILABILITY_NO_SOURCES: string = 'no_configured_sources';

/** 保存任务状态：运行中。 */
export const NETWORK_SAVE_RUNNING: string = 'running';
/** 保存任务状态：已完成。 */
export const NETWORK_SAVE_COMPLETED: string = 'completed';
/** 保存任务状态：失败。 */
export const NETWORK_SAVE_FAILED: string = 'failed';
/** 保存任务状态：已取消。 */
export const NETWORK_SAVE_CANCELLED: string = 'cancelled';

/** 搜索能力标识（仅带该能力的书源可参与搜索）。 */
export const NETWORK_CAPABILITY_SEARCH: string = 'sources.search';
/** 发现能力标识（仅带该能力的书源可浏览分类）。 */
export const NETWORK_CAPABILITY_BROWSE: string = 'sources.browse';

/** `{err, msg}` 响应公共字段（`err === undefined || err === 'ok'` 为成功）。 */
export interface NetworkApiResult {
  err?: string;
  msg?: string;
}

/** 归一化后的书源条目（`SourceBinding.to_public_dict()`）。 */
export interface NetworkSourceItem {
  /** Legado 书源的数字 id；非 Legado 绑定无 legacy id 时为 0。 */
  id: number;
  /** 绑定键（`legado:12` / `plugin:3`），作为所有端点的 `source_id`。 */
  sourceKey: string;
  name: string;
  group: string;
  pluginKey: string;
  capabilities: string[];
  downloadMode: string;
}

/** 空状态提示用的可用性摘要（上游 `SourceCatalogService.availability`）。 */
export interface NetworkAvailability {
  state: string;
  enabledPlugins: number;
  configuredSources: number;
}

/** `GET /api/book-sources` 响应。 */
export interface NetworkSourcesResponse extends NetworkApiResult {
  /** 原始 `items` 数组，用 `parseNetworkSources` 转换。 */
  items?: Object;
  /** 原始 `availability` 对象，用 `parseNetworkAvailability` 转换。 */
  availability?: Object;
}

/** `GET /api/book-sources/search` 响应（任务创建结果）。 */
export interface NetworkSearchResponse extends NetworkApiResult {
  task_id?: string;
  /** 参与搜索的源数量。 */
  total?: number;
  mode?: string;
}

/** `GET /api/book-sources/search/status` 响应。 */
export interface NetworkSearchStatusResponse extends NetworkApiResult {
  task_id?: string;
  total?: number;
  done?: number;
  finished?: boolean;
  /** `[{source_id, source_name, books[]}]`，用 `parseNetworkSearchProgress` 转换。 */
  results?: Object;
  /** `[{source_id, source_name, error}]`。 */
  partial?: Object;
  /** `[{source_id, source_name}]`（仍在搜索的源）。 */
  pending?: Object;
}

/** 归一化后的搜索结果（同一任务内为累计快照）。 */
export interface NetworkSearchProgress {
  taskId: string;
  /** 参与搜索的源数量。 */
  total: number;
  /** 已结束（成功或失败）的源数量。 */
  done: number;
  /** 搜索与审计都已收口（前端判定「可停止轮询」的唯一依据）。 */
  finished: boolean;
  /** 有结果的源（每组含该源返回的书籍）。 */
  groups: NetworkSearchGroup[];
  /** 失败源。 */
  failures: NetworkSearchFailure[];
  /** 仍在搜索的源。 */
  pending: NetworkSearchFailure[];
}

/** 单个书源的搜索结果。 */
export interface NetworkSearchGroup {
  sourceId: string;
  sourceName: string;
  books: NetworkBookItem[];
}

/** 单个书源的失败 / 进行中信息。 */
export interface NetworkSearchFailure {
  sourceId: string;
  sourceName: string;
  /** 上游结构化错误码（如 `js_unsupported`、`fetch_failed`）；进行中为空串。 */
  error: string;
}

/** 归一化后的书源书籍条目（`SourceBook.to_dict()` / `BookSummary.to_dict()`）。 */
export interface NetworkBookItem {
  /** 书籍在书源内的不透明 id（即 `book_url`）。 */
  bookUrl: string;
  title: string;
  author: string;
  coverUrl: string;
  description: string;
  /** 分类文本（上游 `kind`）。 */
  kind: string;
  wordCount: string;
  lastChapter: string;
  /** 来源书源绑定键（`source_id`）。 */
  sourceId: string;
  /** 来源书源名（搜索/发现结果用于展示分组）。 */
  sourceName: string;
}

/** `GET /api/book-sources/browse` 响应。 */
export interface NetworkExploreResponse extends NetworkApiResult {
  /** 原始 `books` 数组，用 `parseNetworkBooks` 转换。 */
  books?: Object;
}

/** 归一化后的发现页分类（`Category.to_dict()` + handler 追加的 `url`）。 */
export interface NetworkCategoryItem {
  id: string;
  name: string;
  url: string;
}

/** `GET /api/book-sources/categories` 响应。 */
export interface NetworkCategoriesResponse extends NetworkApiResult {
  /** 原始 `items` 数组，用 `parseNetworkCategories` 转换。 */
  items?: Object;
}

/** 归一化后的书籍详情（`SourceBookDetail.to_dict()`）。 */
export interface NetworkBookDetail {
  bookUrl: string;
  tocUrl: string;
  title: string;
  author: string;
  coverUrl: string;
  description: string;
  kind: string;
  wordCount: string;
  lastChapter: string;
  /** 上游按章节名推测的连载状态：`serial|finished|unknown`。 */
  serializeStatus: string;
  sourceName: string;
}

/** `GET /api/book-sources/book` 响应。 */
export interface NetworkBookResponse extends NetworkApiResult {
  /** 原始 `book` 对象，用 `parseNetworkBookDetail` 转换。 */
  book?: Object;
  toc_url?: string;
  /** 下载模式：`chapters`（逐章拼装）/ `single_book` / `none`（不支持保存）。 */
  download_mode?: string;
}

/** 归一化后的章节（`SourceChapter.to_dict()`）。 */
export interface NetworkChapterItem {
  externalId: string;
  url: string;
  title: string;
  isVip: boolean;
  updatedAt: string;
}

/** `GET /api/book-sources/toc` 响应。 */
export interface NetworkTocResponse extends NetworkApiResult {
  /** 原始 `chapters` 数组，用 `parseNetworkChapters` 转换。 */
  chapters?: Object;
  serialize_status?: string;
}

/** `GET /api/book-sources/content` 响应。 */
export interface NetworkContentResponse extends NetworkApiResult {
  title?: string;
  content?: string;
}

/** `POST /api/book-sources/save` 响应。 */
export interface NetworkSaveResponse extends NetworkApiResult {
  /** 任务定位键（`online_save:{source_id}:{book_url}`）。 */
  tag?: string;
}

/** `GET /api/book-sources/save/status` 响应。 */
export interface NetworkSaveStatusResponse extends NetworkApiResult {
  found?: boolean;
  status?: string;
  /** 0~100。 */
  progress?: number;
  done?: number;
  total?: number;
  book_id?: number;
  error?: string;
}

/** 归一化后的保存进度。 */
export interface NetworkSaveProgress {
  /** 是否找到任务记录（任务结束很久后可能被清理，此时只能提示用户去通知/书库确认）。 */
  found: boolean;
  status: string;
  progress: number;
  done: number;
  total: number;
  bookId: number;
  error: string;
  /** 任务已收口（completed / failed / cancelled）。 */
  finished: boolean;
  /** 任务成功完成。 */
  succeeded: boolean;
}

/** `POST /api/book-sources/save` 请求体（字段名严格对齐上游 `NetworkSave.post`）。 */
interface NetworkSaveBody {
  source_id: string;
  book_url: string;
  fmt: string;
  clean: boolean;
}

/** 读字符串字段（缺失/null 返回回退值）。 */
function netText(raw: Record<string, Object>, key: string, fallback: string = ''): string {
  const value = raw[key];
  if (value === undefined || value === null) {
    return fallback;
  }
  const text = `${value}`;
  return text === 'undefined' || text === 'null' ? fallback : text;
}

/** 读数字字段（缺失/非数字返回回退值）。 */
function netCount(raw: Record<string, Object>, key: string, fallback: number = 0): number {
  const value = raw[key];
  if (value === undefined || value === null) {
    return fallback;
  }
  const parsed = Number(`${value}`);
  return Number.isNaN(parsed) ? fallback : parsed;
}

/** 读布尔字段（仅 `true` 为真）。 */
function netFlag(raw: Record<string, Object>, key: string): boolean {
  return raw[key] === true;
}

/** 对象字段 → `Record`；缺失/null/数组/非对象返回 null。 */
function netMap(value: Object | undefined): Record<string, Object> | null {
  if (value === undefined || value === null || Array.isArray(value)) {
    return null;
  }
  if (typeof value !== 'object') {
    return null;
  }
  return value as Record<string, Object>;
}

/** 对象数组字段 → `Record[]`；缺失/null/非数组返回空数组。 */
function netRows(value: Object | undefined): Array<Record<string, Object>> {
  if (value === undefined || value === null || !Array.isArray(value)) {
    return [];
  }
  const rows: Array<Record<string, Object>> = [];
  for (const item of value as Array<Object>) {
    const row = netMap(item);
    if (row !== null) {
      rows.push(row);
    }
  }
  return rows;
}

/** 字符串数组字段（如 `capabilities`、`authors`、`categories`）。 */
function netTexts(value: Object | undefined): string[] {
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

/** 追加查询参数（空值跳过，值统一 URL 编码 —— book_url / chapter_url 本身是 URL）。 */
function withQuery(path: string, key: string, value: string): string {
  if (value.length === 0) {
    return path;
  }
  const separator = path.indexOf('?') >= 0 ? '&' : '?';
  return `${path}${separator}${key}=${encodeURIComponent(value)}`;
}

export class NetworkLibraryApi {
  /** 响应是否成功（上游约定 `err === undefined || err === 'ok'`）。 */
  static isOk(rsp: NetworkApiResult): boolean {
    return rsp.err === undefined || rsp.err === 'ok';
  }

  /** 取服务端错误提示（优先 msg，回退 err；成功时返回空串）。 */
  static errorMessage(rsp: NetworkApiResult): string {
    if (NetworkLibraryApi.isOk(rsp)) {
      return '';
    }
    const msg = rsp.msg;
    if (msg !== undefined && msg.length > 0) {
      return msg;
    }
    return rsp.err ?? '';
  }

  /** 书源列表与可用性：`GET /api/book-sources`。 */
  static async getSources(): Promise<NetworkSourcesResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/book-sources');
    return JSON.parse(raw) as NetworkSourcesResponse;
  }

  /**
   * 创建搜索任务：`GET /api/book-sources/search`。
   * 未指定 `sourceKeys` 与 `group` 时按 `mode` 选源（`top` 取上游前 K 个）。
   */
  static async search(key: string, page: number, sourceKeys: string[], group: string,
    mode: string): Promise<NetworkSearchResponse> {
    let path = '/api/book-sources/search';
    path = withQuery(path, 'key', key.trim());
    path = withQuery(path, 'page', `${page > 0 ? page : 1}`);
    path = withQuery(path, 'sources', sourceKeys.join(','));
    path = withQuery(path, 'group', group.trim());
    path = withQuery(path, 'mode', mode);
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as NetworkSearchResponse;
  }

  /** 查询搜索任务进度：`GET /api/book-sources/search/status`。 */
  static async getSearchStatus(taskId: string): Promise<NetworkSearchStatusResponse> {
    const path = withQuery('/api/book-sources/search/status', 'task_id', taskId);
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as NetworkSearchStatusResponse;
  }

  /** 发现页浏览：`GET /api/book-sources/browse`（`categoryId` 即分类的 `id`/`url`）。 */
  static async explore(sourceId: string, categoryId: string, page: number): Promise<NetworkExploreResponse> {
    let path = '/api/book-sources/browse';
    path = withQuery(path, 'source_id', sourceId);
    path = withQuery(path, 'url', categoryId);
    path = withQuery(path, 'page', `${page > 0 ? page : 1}`);
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as NetworkExploreResponse;
  }

  /** 书源发现页分类：`GET /api/book-sources/categories`。 */
  static async getCategories(sourceId: string): Promise<NetworkCategoriesResponse> {
    const path = withQuery('/api/book-sources/categories', 'source_id', sourceId);
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as NetworkCategoriesResponse;
  }

  /** 书籍详情：`GET /api/book-sources/book`。 */
  static async getBook(sourceId: string, bookUrl: string): Promise<NetworkBookResponse> {
    let path = '/api/book-sources/book';
    path = withQuery(path, 'source_id', sourceId);
    path = withQuery(path, 'book_url', bookUrl);
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as NetworkBookResponse;
  }

  /** 目录（按书籍 URL，服务端会先抓详情再取目录）：`GET /api/book-sources/toc`。 */
  static async getToc(sourceId: string, bookUrl: string): Promise<NetworkTocResponse> {
    let path = '/api/book-sources/toc';
    path = withQuery(path, 'source_id', sourceId);
    path = withQuery(path, 'book_url', bookUrl);
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as NetworkTocResponse;
  }

  /** 目录（已有 `toc_url` 时跳过详情抓取）：`GET /api/book-sources/toc`。 */
  static async getTocByUrl(sourceId: string, tocUrl: string): Promise<NetworkTocResponse> {
    let path = '/api/book-sources/toc';
    path = withQuery(path, 'source_id', sourceId);
    path = withQuery(path, 'toc_url', tocUrl);
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as NetworkTocResponse;
  }

  /** 章节正文：`GET /api/book-sources/content`（`clean` 为真时走上游正文净化）。 */
  static async getContent(sourceId: string, chapterUrl: string, title: string,
    clean: boolean): Promise<NetworkContentResponse> {
    let path = '/api/book-sources/content';
    path = withQuery(path, 'source_id', sourceId);
    path = withQuery(path, 'chapter_url', chapterUrl);
    path = withQuery(path, 'title', title);
    path = withQuery(path, 'clean', clean ? '1' : '0');
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as NetworkContentResponse;
  }

  /** 保存到本地书库（异步任务）：`POST /api/book-sources/save`。 */
  static async save(sourceId: string, bookUrl: string, fmt: string,
    clean: boolean): Promise<NetworkSaveResponse> {
    const body: NetworkSaveBody = {
      source_id: sourceId,
      book_url: bookUrl,
      fmt: fmt,
      clean: clean,
    };
    const raw = await TalebookCoreService.talebookPost('/api/book-sources/save', JSON.stringify(body));
    return JSON.parse(raw) as NetworkSaveResponse;
  }

  /** 查询保存进度：`GET /api/book-sources/save/status`。 */
  static async getSaveStatus(sourceId: string, bookUrl: string): Promise<NetworkSaveStatusResponse> {
    let path = '/api/book-sources/save/status';
    path = withQuery(path, 'source_id', sourceId);
    path = withQuery(path, 'book_url', bookUrl);
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as NetworkSaveStatusResponse;
  }

  /** 解析 `GET /api/book-sources` 的 `items`。 */
  static parseSources(value: Object | undefined): NetworkSourceItem[] {
    const items: NetworkSourceItem[] = [];
    for (const row of netRows(value)) {
      const sourceKey = netText(row, 'source_key');
      items.push({
        id: netCount(row, 'id'),
        sourceKey: sourceKey,
        name: netText(row, 'name', sourceKey),
        group: netText(row, 'group'),
        pluginKey: netText(row, 'plugin_key'),
        capabilities: netTexts(row['capabilities']),
        downloadMode: netText(row, 'download_mode'),
      });
    }
    return items;
  }

  /** 解析 `GET /api/book-sources` 的 `availability`。 */
  static parseAvailability(value: Object | undefined): NetworkAvailability {
    const row = netMap(value);
    if (row === null) {
      return {
        state: NETWORK_AVAILABILITY_NO_PLUGINS,
        enabledPlugins: 0,
        configuredSources: 0,
      };
    }
    return {
      state: netText(row, 'state'),
      enabledPlugins: netCount(row, 'enabled_plugins'),
      configuredSources: netCount(row, 'configured_sources'),
    };
  }

  /** 解析搜索任务状态快照（`results` 为累计值，可直接整表替换当前任务的展示结果）。 */
  static parseSearchProgress(rsp: NetworkSearchStatusResponse): NetworkSearchProgress {
    const groups: NetworkSearchGroup[] = [];
    for (const row of netRows(rsp.results)) {
      const sourceId = netText(row, 'source_id');
      groups.push({
        sourceId: sourceId,
        sourceName: netText(row, 'source_name', sourceId),
        books: NetworkLibraryApi.parseNetworkBooks(row['books'], sourceId,
          netText(row, 'source_name', sourceId)),
      });
    }
    const failures: NetworkSearchFailure[] = [];
    for (const row of netRows(rsp.partial)) {
      failures.push({
        sourceId: netText(row, 'source_id'),
        sourceName: netText(row, 'source_name'),
        error: netText(row, 'error'),
      });
    }
    const pending: NetworkSearchFailure[] = [];
    for (const row of netRows(rsp.pending)) {
      pending.push({
        sourceId: netText(row, 'source_id'),
        sourceName: netText(row, 'source_name'),
        error: '',
      });
    }
    return {
      taskId: rsp.task_id ?? '',
      total: rsp.total !== undefined ? rsp.total : 0,
      done: rsp.done !== undefined ? rsp.done : 0,
      finished: rsp.finished === true,
      groups: groups,
      failures: failures,
      pending: pending,
    };
  }

  /** 解析书籍条目数组（搜索 / 发现 / 书源测试的结果结构一致）。 */
  static parseNetworkBooks(value: Object | undefined, sourceId: string,
    sourceName: string): NetworkBookItem[] {
    const books: NetworkBookItem[] = [];
    for (const row of netRows(value)) {
      const bookUrl = netText(row, 'book_url', netText(row, 'external_id'));
      const authors = netTexts(row['authors']);
      const author = netText(row, 'author', authors.length > 0 ? authors[0] : '');
      books.push({
        bookUrl: bookUrl,
        title: netText(row, 'title', netText(row, 'name')),
        author: author,
        coverUrl: netText(row, 'cover_url'),
        description: netText(row, 'description', netText(row, 'intro')),
        kind: netText(row, 'kind'),
        wordCount: netText(row, 'word_count'),
        lastChapter: netText(row, 'last_chapter'),
        sourceId: sourceId,
        sourceName: sourceName,
      });
    }
    return books;
  }

  /** 解析发现页分类数组。 */
  static parseNetworkCategories(value: Object | undefined): NetworkCategoryItem[] {
    const items: NetworkCategoryItem[] = [];
    for (const row of netRows(value)) {
      const id = netText(row, 'id', netText(row, 'url'));
      items.push({
        id: id,
        name: netText(row, 'name', id),
        url: netText(row, 'url', id),
      });
    }
    return items;
  }

  /** 解析书籍详情（`book` 字段）；非对象返回 null。 */
  static parseNetworkBookDetail(value: Object | undefined, fallbackBookUrl: string,
    fallbackSourceName: string): NetworkBookDetail | null {
    const row = netMap(value);
    if (row === null) {
      return null;
    }
    const authors = netTexts(row['authors']);
    return {
      bookUrl: netText(row, 'book_url', netText(row, 'external_id', fallbackBookUrl)),
      tocUrl: netText(row, 'toc_url', netText(row, 'toc_ref')),
      title: netText(row, 'title', netText(row, 'name')),
      author: netText(row, 'author', authors.length > 0 ? authors[0] : ''),
      coverUrl: netText(row, 'cover_url'),
      description: netText(row, 'description', netText(row, 'intro')),
      kind: netText(row, 'kind'),
      wordCount: netText(row, 'word_count'),
      lastChapter: netText(row, 'last_chapter'),
      serializeStatus: netText(row, 'serialize_status', 'unknown'),
      sourceName: netText(row, 'source', fallbackSourceName),
    };
  }

  /** 解析章节数组（同时兼容 `SourceChapter.to_dict()` 与 `Chapter.to_dict()`）。 */
  static parseNetworkChapters(value: Object | undefined): NetworkChapterItem[] {
    const chapters: NetworkChapterItem[] = [];
    for (const row of netRows(value)) {
      const url = netText(row, 'url', netText(row, 'external_id'));
      chapters.push({
        externalId: netText(row, 'external_id', url),
        url: url,
        title: netText(row, 'title', netText(row, 'name')),
        isVip: netFlag(row, 'is_vip'),
        updatedAt: netText(row, 'updated_at', netText(row, 'update_time')),
      });
    }
    return chapters;
  }

  /** 解析保存进度（`found=false` 表示任务记录不存在或已被清理）。 */
  static parseSaveProgress(rsp: NetworkSaveStatusResponse): NetworkSaveProgress {
    const status = rsp.status !== undefined ? rsp.status : '';
    const finished = status === NETWORK_SAVE_COMPLETED || status === NETWORK_SAVE_FAILED ||
      status === NETWORK_SAVE_CANCELLED;
    return {
      found: rsp.found === true,
      status: status,
      progress: rsp.progress !== undefined ? rsp.progress : 0,
      done: rsp.done !== undefined ? rsp.done : 0,
      total: rsp.total !== undefined ? rsp.total : 0,
      bookId: rsp.book_id !== undefined ? rsp.book_id : 0,
      error: rsp.error !== undefined ? rsp.error : '',
      finished: finished,
      succeeded: status === NETWORK_SAVE_COMPLETED,
    };
  }
}
