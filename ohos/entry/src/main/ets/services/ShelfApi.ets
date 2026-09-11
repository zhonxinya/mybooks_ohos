/**
 * 书架 / 阅读进度 / 书籍可见范围与媒体类型 / 在线书库 REST API。
 *
 * 端点逐条核对自上游源码（勿凭印象改动）：
 * - `GET  /api/shelf`                → webserver/handlers/book.py::BookShelf.get
 *   ⚠️ 一次性返回全部在架书籍，**不接受 `start`/`size`**（无 get_argument_start）
 * - `POST /api/book/{id}/shelf`      → webserver/handlers/book.py::BookShelf.post，body `{"shelf": bool}`
 * - `GET  /api/book/{id}/progress`   → webserver/handlers/book.py::BookReadingProgress.get
 * - `POST /api/book/{id}/progress`   → webserver/handlers/book.py::BookReadingProgress.post
 *   body `{"progress": {...}}`，服务端限制 8KiB；**无删除端点**（清空只能以空对象覆盖）
 * - `GET  /api/book/{id}`            → webserver/handlers/book.py::BookDetail.get（含 `scope` / `media_type`）
 * - `POST /api/book/{id}/setscope`   → webserver/handlers/book.py::BookSetScope.post
 *   ⚠️ 不读请求体，服务端在 `public`/`private` 之间**翻转**
 * - `POST /api/book/{id}/media_type` → webserver/handlers/book.py::BookSetMediaType.post
 *   body `{"media_type": "ebook"|"comic"}`（取值见 webserver/constants.py）
 * - `GET  /api/library/online`       → webserver/handlers/network_library.py::NetworkLibraryOnline.get
 *   `status` 可选 `serial`/`finished`/`unknown`；经 `render_book_list` 支持 `start`（偏移）+ `size`（每页）
 *
 * 响应约定：`{err, msg}`；`err === undefined || err === 'ok'` 视为成功（见 `isShelfApiOk`）。
 */
import { TalebookCoreService } from './TalebookCoreService';
import { ApiMessageResult } from './TalebookApi';

/** 默认每页条数（服务端 `render_book_list` 的 max_size 下限为 60，客户端取 20 保持与其它列表一致）。 */
const DEFAULT_PAGE_SIZE: number = 20;

/** 服务端书籍列表响应（书架与在线书库共用同一结构）。 */
export interface BookListResponse extends ApiMessageResult {
  title?: string;
  total?: number;
  books?: Array<Record<string, Object>>;
}

/** 跨端阅读进度响应；未保存过进度时 `update_time` 为 `null`。 */
export interface ReadingProgressResponse extends ApiMessageResult {
  progress?: Record<string, Object>;
  update_time?: string | null;
}

/** 书籍详情响应（此处只取属性相关字段，书籍模型解码见 `BookModels.ets`）。 */
export interface BookAttributesResponse extends ApiMessageResult {
  book?: Record<string, Object>;
}

/** 媒体类型设置响应：服务端额外回传落库结果。 */
export interface MediaTypeSetResponse extends ApiMessageResult {
  media_type?: string;
  media_type_locked?: boolean;
}

/** 书籍可见范围取值（`Item.scope`）。 */
export class BookScope {
  static readonly PUBLIC: string = 'public';
  static readonly PRIVATE: string = 'private';
}

/** 书籍媒体类型取值（webserver/constants.py）。 */
export class BookMediaType {
  static readonly EBOOK: string = 'ebook';
  static readonly COMIC: string = 'comic';
  static readonly UNKNOWN: string = 'unknown';
}

/** 在线书库连载状态筛选值（`models.py::OnlineBookMeta`）。 */
export class OnlineBookStatus {
  /** 空串 = 不筛选（上游 `status` 参数非枚举值时不加过滤）。 */
  static readonly ALL: string = '';
  static readonly SERIAL: string = 'serial';
  static readonly FINISHED: string = 'finished';
  static readonly UNKNOWN: string = 'unknown';
}

/** 书籍属性（由 `GET /api/book/{id}` 解码）。 */
export interface BookAttributes {
  bookId: number;
  title: string;
  /** `public` / `private` */
  scope: string;
  /** `ebook` / `comic` / `unknown` */
  mediaType: string;
  /** 是否已被用户手动锁定（无需再自动分析）。 */
  mediaTypeLocked: boolean;
  /** 现有格式列表（由 `files[].format` 汇总）。 */
  formats: string[];
}

interface ShelfPayload {
  shelf: boolean;
}

interface ProgressPayload {
  progress: Record<string, Object>;
}

interface MediaTypePayload {
  media_type: string;
}

/** 从 `GET /api/book/{id}` 的 `book` 字段解码书籍属性。 */
export function parseBookAttributes(json: Record<string, Object>): BookAttributes {
  const rawId = json['id'];
  const parsedId = typeof rawId === 'number' ? rawId : parseInt(`${rawId}`, 10);
  const formats: string[] = [];
  const files = json['files'] as Array<Record<string, Object>> | undefined;
  if (files !== undefined) {
    for (let i = 0; i < files.length; i++) {
      const format = `${files[i]['format'] ?? ''}`;
      if (format.length > 0) {
        formats.push(format);
      }
    }
  }
  return {
    bookId: Number.isNaN(parsedId) ? 0 : parsedId,
    title: `${json['title'] ?? ''}`,
    scope: `${json['scope'] ?? BookScope.PUBLIC}`,
    mediaType: `${json['media_type'] ?? BookMediaType.UNKNOWN}`,
    mediaTypeLocked: json['media_type_locked'] === true,
    formats: formats,
  };
}

/** 是否符合 `{err, msg}` 约定：`err` 缺省或为 `'ok'` 即成功。 */
export function isShelfApiOk(rsp: ApiMessageResult): boolean {
  return rsp.err === undefined || rsp.err === 'ok';
}

export class ShelfApi {
  /** 书架列表（GET /api/shelf）。上游一次性返回全部在架书籍，分页需在客户端完成。 */
  static async getShelf(): Promise<BookListResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/shelf');
    return JSON.parse(raw) as BookListResponse;
  }

  /** 加入 / 移出书架（POST /api/book/{id}/shelf）。 */
  static async setShelf(bookId: number, onShelf: boolean): Promise<ApiMessageResult> {
    const payload: ShelfPayload = { shelf: onShelf };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/shelf`, JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 读取跨端阅读进度（GET /api/book/{id}/progress）。 */
  static async getReadingProgress(bookId: number): Promise<ReadingProgressResponse> {
    const raw = await TalebookCoreService.talebookGet(`/api/book/${bookId}/progress`);
    return JSON.parse(raw) as ReadingProgressResponse;
  }

  /**
   * 写入跨端阅读进度（POST /api/book/{id}/progress）。
   * `progress` 为客户端自定义结构（章节、CFI、百分比等），服务端按 JSON 对象存储，上限 8KiB。
   * 上游为整体覆盖语义：如需保留既有字段，调用方应先 GET 再合并后 POST。
   */
  static async saveReadingProgress(bookId: number, progress: Record<string, Object>):
    Promise<ReadingProgressResponse> {
    const payload: ProgressPayload = { progress: progress };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/progress`, JSON.stringify(payload));
    return JSON.parse(raw) as ReadingProgressResponse;
  }

  /** 清空阅读进度：上游无删除端点，以空对象覆盖（等价于从未保存，`update_time` 仍会更新）。 */
  static async clearReadingProgress(bookId: number): Promise<ReadingProgressResponse> {
    const empty: Record<string, Object> = {};
    return ShelfApi.saveReadingProgress(bookId, empty);
  }

  /** 读取书籍属性（GET /api/book/{id}），用于展示可见范围与媒体类型。 */
  static async getBookAttributes(bookId: number): Promise<BookAttributesResponse> {
    const raw = await TalebookCoreService.talebookGet(`/api/book/${bookId}`);
    return JSON.parse(raw) as BookAttributesResponse;
  }

  /**
   * 切换书籍可见范围（POST /api/book/{id}/setscope）。
   * ⚠️ 上游不读请求体，仅在 `public` ↔ `private` 之间翻转；返回体不含新值，
   * 需要新值时应重新调用 `getBookAttributes`。
   */
  static async toggleBookScope(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/setscope`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /**
   * 设置书籍媒体类型（POST /api/book/{id}/media_type）。
   * 仅接受 `ebook` / `comic`；仅当书籍同时含电子书与漫画格式时上游才允许设置，
   * 否则返回 `media_type.not_mixed`（照原样展示服务端提示即可）。
   */
  static async setBookMediaType(bookId: number, mediaType: string): Promise<MediaTypeSetResponse> {
    const payload: MediaTypePayload = { media_type: mediaType };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/media_type`,
      JSON.stringify(payload));
    return JSON.parse(raw) as MediaTypeSetResponse;
  }

  /**
   * 在线书库列表（GET /api/library/online）。
   * `start` 为偏移量（从 0 开始），`size` 为每页条数；`status` 传空串表示不筛选。
   */
  static async getOnlineLibrary(start: number, size: number, status: string): Promise<BookListResponse> {
    const offset = start > 0 ? start : 0;
    const limit = size > 0 ? size : DEFAULT_PAGE_SIZE;
    let path = `/api/library/online?start=${offset}&size=${limit}`;
    if (status.length > 0) {
      path += `&status=${encodeURIComponent(status)}`;
    }
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as BookListResponse;
  }
}
