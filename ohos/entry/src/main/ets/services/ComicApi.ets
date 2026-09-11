import { TalebookCoreService } from './TalebookCoreService';

/**
 * 漫画在线阅读端点封装（talebook 专有）。
 * 参考源码：`docs/talebook/webserver/handlers/comic.py`（逐项核对上游，勿凭印象改动）；
 * 页面字典由 `docs/talebook/webserver/services/comic_archive.py::ComicPage.to_public_dict` 生成。
 *
 * 端点：
 * - `GET  /api/book/{id}/comic/pages`（ComicManifestHandler.get，@js @auth）
 *   返回 `{err, contract_version, book_id, title, format, revision, pages_count, pages[]}`；
 *   `pages[]` 每项 `{id, index, url, width, height, mime_type}`，`url` 已带 `revision` 与单页
 *   `token`（`/api/book/{id}/comic/pages/{index}?revision=..&token=..`）。
 * - `GET  /api/book/{id}/comic/pages/{index}?revision=&token=`（ComicPageHandler）
 *   返回**图片二进制**（非 JSON，Content-Type 为页面的 mime_type），因此必须走图片通道
 *   （`AuthImage`），不能走 JSON 文本通道；登录态有效时也可由 Cookie 鉴权，`token` 用作
 *   无 Cookie 时的兜底（有效期 `COMIC_PAGE_TOKEN_MAX_AGE_DAYS = 1` 天）。
 * - `GET  /api/book/{id}/comic/progress`（ComicProgressHandler.get，@js @auth）
 *   返回 `{err, progress, update_time}`；无进度时 `progress` 为 `{}`。
 * - `POST /api/book/{id}/comic/progress`（ComicProgressHandler.post，@js @auth）
 *   请求体 `{"progress": {kind:"comic", version:1, pageId, pageIndex, percent, completed}}`；
 *   超过 `MAX_COMIC_PROGRESS_BYTES` 返回 `comic.progress_invalid`，
 *   `pageId`/`percent`/`completed` 与清单归一化结果不一致返回 `comic.progress_stale`。
 *
 * 说明：上游页面路由 `/read-comic/{id}`（ComicReaderHandler）是网页版阅读入口，渲染
 * `book/comic-reader.html`，客户端不实现，此处仅作记录。
 */

/** 进度契约版本（上游 `COMIC_PROGRESS_VERSION`）。 */
export const COMIC_PROGRESS_VERSION: number = 1;
/** 进度请求体上限，字节（上游 `MAX_COMIC_PROGRESS_BYTES`）。 */
export const COMIC_PROGRESS_MAX_BYTES: number = 2048;
/** 进度类型标识（上游 `normalized_progress` 校验的 `kind`）。 */
export const COMIC_PROGRESS_KIND: string = 'comic';

/** 单页元数据（`pages[]` 元素，对应 `ComicPage.to_public_dict`）。 */
export interface ComicPageInfo {
  /** 不透明页 id（`page_id`），进度上报时用于校验清单是否已更新。 */
  id: string;
  /** 连续页码下标，从 0 开始（`index`）。 */
  index: number;
  /** 已带 `revision` 与单页 `token` 的图片地址（相对路径）。 */
  url: string;
  /** 图片原始宽度（像素），用于按真实宽高比排版。 */
  width: number;
  /** 图片原始高度（像素）。 */
  height: number;
  /** 图片 MIME 类型（`mime_type`，如 image/jpeg）。 */
  mime_type: string;
}

/** `{err, msg}` 响应公共字段。 */
export interface ComicApiResult {
  err?: string;
  msg?: string;
}

/** `GET /api/book/{id}/comic/pages` 响应。 */
export interface ComicManifestResponse extends ComicApiResult {
  contract_version?: number;
  book_id?: number;
  title?: string;
  format?: string;
  revision?: string;
  pages_count?: number;
  /** 原始 `pages` 数组，用 `ComicApi.parsePages` 转换。 */
  pages?: Object;
}

/** 归一化后的漫画阅读进度（上游 `normalized_progress` 的返回结构）。 */
export interface ComicProgress {
  kind: string;
  version: number;
  pageId: string;
  pageIndex: number;
  percent: number;
  completed: boolean;
}

/** `GET`/`POST /api/book/{id}/comic/progress` 响应。 */
export interface ComicProgressResponse extends ComicApiResult {
  /** 原始 progress 对象（无进度时为 `{}`），用 `ComicApi.parseProgress` 转换。 */
  progress?: Object;
  /** 进度更新时间（ISO8601），无记录时为 null。 */
  update_time?: string;
}

/** `POST /api/book/{id}/comic/progress` 请求体。 */
interface ComicProgressBody {
  progress: ComicProgress;
}

/** 读字符串字段（缺失/空返回指定的回退值）。 */
function comicString(raw: Record<string, Object>, key: string, fallback: string = ''): string {
  const value = raw[key];
  if (value === undefined || value === null) {
    return fallback;
  }
  const text = `${value}`;
  return text === 'undefined' || text === 'null' ? fallback : text;
}

/** 读数字字段（缺失/非数字返回指定的回退值）。 */
function comicNumber(raw: Record<string, Object>, key: string, fallback: number = 0): number {
  const value = raw[key];
  if (value === undefined || value === null) {
    return fallback;
  }
  const parsed = Number(`${value}`);
  return Number.isNaN(parsed) ? fallback : parsed;
}

/** 读布尔字段（仅 `true` 为真，缺失/其他值返回 false）。 */
function comicBool(raw: Record<string, Object>, key: string): boolean {
  return raw[key] === true;
}

/** 把对象数组字段归一化为 `Array<Record<string, Object>>`（缺失/null/非数组返回空数组）。 */
function comicRows(value: Object | undefined): Array<Record<string, Object>> {
  if (value === undefined || value === null || !Array.isArray(value)) {
    return [];
  }
  return value as Array<Record<string, Object>>;
}

export class ComicApi {
  /** 漫画页面清单：`GET /api/book/{bookId}/comic/pages`（`url` 已含 revision 与单页 token）。 */
  static async getManifest(bookId: number): Promise<ComicManifestResponse> {
    const raw = await TalebookCoreService.talebookGet(`/api/book/${bookId}/comic/pages`);
    return JSON.parse(raw) as ComicManifestResponse;
  }

  /**
   * 单页图片端点路径：`GET /api/book/{bookId}/comic/pages/{pageIndex}?revision=`。
   * 该端点返回图片二进制，只用于说明；实际取图请直接使用清单里的 `pages[].url`
   * （已带 token）并交给 `AuthImage` 渲染。
   */
  static pageImagePath(bookId: number, pageIndex: number, revision: string): string {
    return `/api/book/${bookId}/comic/pages/${pageIndex}?revision=${encodeURIComponent(revision)}`;
  }

  /** 读取阅读进度：`GET /api/book/{bookId}/comic/progress`。 */
  static async getProgress(bookId: number): Promise<ComicProgressResponse> {
    const raw = await TalebookCoreService.talebookGet(`/api/book/${bookId}/comic/progress`);
    return JSON.parse(raw) as ComicProgressResponse;
  }

  /**
   * 上报阅读进度：`POST /api/book/{bookId}/comic/progress`。
   * 请求体字段严格按上游归一化结果生成（pageId 取清单里的页 id，
   * percent 取 `(pageIndex + 1) * 100 / totalPages`，completed 为是否末页）。
   */
  static async saveProgress(bookId: number, page: ComicPageInfo, pageIndex: number,
    totalPages: number): Promise<ComicProgressResponse> {
    const progress: ComicProgress = {
      kind: COMIC_PROGRESS_KIND,
      version: COMIC_PROGRESS_VERSION,
      pageId: page.id,
      pageIndex: pageIndex,
      percent: ComicApi.percentFor(pageIndex, totalPages),
      completed: totalPages > 0 && pageIndex === totalPages - 1,
    };
    const body: ComicProgressBody = { progress: progress };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/comic/progress`,
      JSON.stringify(body));
    return JSON.parse(raw) as ComicProgressResponse;
  }

  /** 上报百分比：与上游 `round((page_index + 1) * 100 / len(pages), 2)` 对齐（保留两位小数）。 */
  static percentFor(pageIndex: number, totalPages: number): number {
    if (totalPages <= 0) {
      return 0;
    }
    return Math.round(((pageIndex + 1) * 100 / totalPages) * 100) / 100;
  }

  /** `pages[]` → 强类型数组（逐项取字段，缺失用回退值）。 */
  static parsePages(raw: Object | undefined): ComicPageInfo[] {
    const rows = comicRows(raw);
    const pages: ComicPageInfo[] = [];
    for (let i = 0; i < rows.length; i++) {
      const row = rows[i];
      const page: ComicPageInfo = {
        id: comicString(row, 'id'),
        index: comicNumber(row, 'index', i),
        url: comicString(row, 'url'),
        width: comicNumber(row, 'width', 0),
        height: comicNumber(row, 'height', 0),
        mime_type: comicString(row, 'mime_type'),
      };
      pages.push(page);
    }
    return pages;
  }

  /** progress → 强类型；缺失、非 comic 进度或页码非法时返回 null。 */
  static parseProgress(raw: Object | undefined): ComicProgress | null {
    if (raw === undefined || raw === null) {
      return null;
    }
    const row = raw as Record<string, Object>;
    if (comicString(row, 'kind') !== COMIC_PROGRESS_KIND) {
      return null;
    }
    const pageIndex = comicNumber(row, 'pageIndex', -1);
    if (pageIndex < 0) {
      return null;
    }
    const progress: ComicProgress = {
      kind: COMIC_PROGRESS_KIND,
      version: comicNumber(row, 'version', COMIC_PROGRESS_VERSION),
      pageId: comicString(row, 'pageId'),
      pageIndex: pageIndex,
      percent: comicNumber(row, 'percent', 0),
      completed: comicBool(row, 'completed'),
    };
    return progress;
  }

  /** 响应是否成功（`err` 缺省或 `'ok'`）。 */
  static isOk(rsp: ComicApiResult): boolean {
    const err = rsp.err;
    return err === undefined || err === 'ok';
  }

  /** 取服务端错误提示（优先 msg，回退 err；返回空串表示成功）。 */
  static errorMessage(rsp: ComicApiResult): string {
    if (ComicApi.isOk(rsp)) {
      return '';
    }
    const msg = rsp.msg;
    if (msg !== undefined && msg.length > 0) {
      return msg;
    }
    return rsp.err ?? '';
  }
}
