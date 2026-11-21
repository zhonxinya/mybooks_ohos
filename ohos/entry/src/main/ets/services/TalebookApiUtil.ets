/**
 * TalebookApi 拆分共享层（800 行门禁）：查询串/响应解析辅助与大 JSON taskpool 判定，
 * 以及各域请求/响应 payload 接口。域类：TalebookApi(CORE)/Admin/Toolbox/Books。
 */
import { taskpool } from '@kit.ArkTS';
import { ReferBook } from '../common/ApiTypes';
import { BookItem, parseBookItem } from './BookModels';
import { HomeBook } from '../models/HomeModels';
import { TalebookCoreService } from './TalebookCoreService';
import { parseJsonTask } from './TalebookJsonParser';
import { ServerRegistry } from './ServerProfile';
import { ApiMessageResult, ApiResult, BookListPayload } from './TalebookApiTypes';


/** 解析 JSON；若响应体为 HTML/重定向等非 JSON，返回 { err: 'ok' } 避免崩溃。 */
export function parseJsonOrOk(raw: string): ApiMessageResult {
  const trimmed = raw.trim();
  if (trimmed.length === 0) {
    return { err: 'ok' } as ApiMessageResult;
  }
  if (trimmed.charAt(0) !== '{' && trimmed.charAt(0) !== '[') {
    return { err: 'ok' } as ApiMessageResult;
  }
  try {
    return JSON.parse(raw) as ApiMessageResult;
  } catch (_e) {
    return { err: 'ok' } as ApiMessageResult;
  }
}

export function appendQuery(base: string, key: string, value: string | number): string {
  const sep = base.indexOf('?') >= 0 ? '&' : '?';
  return `${base}${sep}${encodeURIComponent(key)}=${encodeURIComponent(String(value))}`;
}

/**
 * 列表分页参数（start/size）。
 * 两端 ListHandler 系（mybooks `ListHandler.get_book_list`、talebook `ListHandler.render_book_list`）
 * 只识别 `start`（偏移）+ `size`（每页），传 `page`/`limit` 会被忽略而恒返回首页。
 */
export function buildPagePath(base: string, page: number, limit: number): string {
  const sep = base.indexOf('?') >= 0 ? '&' : '?';
  return `${base}${sep}${ServerRegistry.listQuery(page, limit)}`;
}

/**
 * 大响应体阈值（与 TalebookService.LARGE_JSON_THRESHOLD 一致）：
 * 超过阈值的 JSON.parse 下放 taskpool 工作线程，避免阻塞 UI 线程出帧。
 */
export const LARGE_JSON_THRESHOLD: number = 32768;

/** 解析 JSON；小响应同步解析（免 taskpool 往返），大响应在工作线程解析。 */
export async function parseJsonAsync(raw: string): Promise<Object> {
  if (raw.length < LARGE_JSON_THRESHOLD) {
    return JSON.parse(raw) as Object;
  }
  return await taskpool.execute(parseJsonTask, raw) as Object;
}

/**
 * 解析书籍列表响应。
 * 列表键两端不同：mybooks 用 `books`，talebook 用 `items`；直接返回数组也接受。
 */
export async function parseList(raw: string): Promise<BookItem[]> {
  const data = await parseJsonAsync(raw) as Array<Record<string, Object>> | BookListPayload;
  let books: Array<Record<string, Object>> = [];
  if (Array.isArray(data)) {
    books = data;
  } else if (data.books !== undefined) {
    books = data.books;
  } else {
    const items = (data as Record<string, Object>)['items'];
    if (items !== undefined) {
      books = items as Array<Record<string, Object>>;
    }
  }
  const result: BookItem[] = [];
  for (let i = 0; i < books.length; i++) {
    result.push(parseBookItem(books[i]));
  }
  return result;
}

/** High-level Talebook REST API via C++ core. */

export interface AvatarUploadResponse extends ApiMessageResult {
  avatar_url?: string;
}

export interface UserUpdatePayload {
  nickname?: string;
  password0?: string;
  password1?: string;
  password2?: string;
  kindle_email?: string;
  allow_sending_mail?: boolean;
  show_other_annotations?: boolean;
  share_annotations?: boolean;
  show_home_recommendations?: boolean;
  podcast_token?: string;
}

export interface MemoCreatePayload {
  memo: string;
  memo_type: number;
}

export interface ExpectedCreatePayload {
  title: string;
  author: string;
  publisher: string;
}

export interface ExpectedDeletePayload {
  id: number;
}

export interface MemoDataPayload extends ApiResult {
  data?: Object;
}

export interface DevicesPayload extends ApiResult {
  devices?: Object;
}

export interface FormatStatsPayload extends ApiResult {
  stats?: Object;
}

export interface SendDevicePayload {
  device_type: string;
  device_url: string;
  mailbox: string;
  ftp_username: string;
  ftp_password: string;
  ftp_path: string;
}

export interface SendMailPayload {
  email: string;
  format: string;
}

export interface WantsPayload {
  wants: boolean;
}

export interface FormatPayload {
  format: string;
}

export interface CropCoverPayload {
  id: number;
}

export interface CropCoverIdsPayload {
  ids: number[];
}

export interface CropCoverResult extends ApiMessageResult {
  data?: Record<string, Object>;
}

export interface BatchRemoveStatePayload {
  book_ids: number[];
  action: string;
}

export interface PinPayload {
  item_type: number;
  value: string;
}

export interface CategoryPayload {
  category: string;
}

export interface LocationPayload {
  location: string;
}

export interface CategoriesPayload extends ApiResult {
  categories?: Array<Record<string, Object>>;
}

export interface AuthorsPayload extends ApiResult {
  authors?: Array<Record<string, Object>>;
}
export interface TagsPayload extends ApiResult {
  tags?: Array<Record<string, Object>>;
}

export interface MetaListResponse extends ApiMessageResult {
  meta?: string;
  title?: string;
  items?: MetaNameCount[];
  total?: number;
  pins?: MetaNameCount[];
}

export interface AuthorProfile {
  id?: number;
  name?: string;
  author_id?: number;
  sort?: string;
  bio?: string;
  region?: string;
  avatar?: string;
  create_time?: string;
}

export interface AuthorInfoResponse extends ApiMessageResult {
  author?: AuthorProfile | null;
}

export interface ReferListPayload extends ApiResult {
  msg?: string;
  books?: Array<Record<string, Object>>;
  cached?: boolean;
}

export interface ReferSearchOpts {
  title?: string;
  isbn?: string;
  publisher?: string;
}

export interface ReferSearchResponse {
  err?: string;
  msg?: string;
  cached?: boolean;
  books: ReferBook[];
}

export interface StampPayload {
  position: string;
}

export interface DownloadQuotaResult extends ApiResult {
  allowed?: boolean;
  used?: number;
  quota?: number;
}

export interface ExchangeTypePayload {
  idlist: number[];
}

export interface AddIsbnPayload {
  isbn: string;
}

export interface AddIsbnResult extends ApiMessageResult {
  book_id?: number;
}

/** 名称+数量型元数据项（分类/作者联想等）。 */
export interface MetaNameCount {
  name: string;
  count: number;
}

export function parseNameCounts(items: Array<Record<string, Object>> | undefined): MetaNameCount[] {
  const result: MetaNameCount[] = [];
  if (items === undefined) {
    return result;
  }
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    const name = String(item['name'] ?? '');
    if (name.length > 0) {
      result.push({ name: name, count: Number(item['count'] ?? 0) });
    }
  }
  return result;
}

export async function fetchStateList(path: string, page: number, size: number): Promise<BookItem[]> {
  const start = (page - 1) * size;
  const raw = await TalebookCoreService.talebookGet(`${path}?start=${start}&size=${size}`);
  return parseList(raw);
}

export interface ReadStatePayload {
  read_state: number;
}

export interface ReviewPayload {
  rating: number;
  comment: string;
}

export interface ReviewsPayload extends ApiResult {
  total?: number;
  reviews?: Object;
}

export interface OwnReviewPayload extends ApiResult {
  review?: Object;
}

export interface ReadingStatsPayload extends ApiResult {
  stats?: Object;
  current_reading_books?: Object;
  month_read_done_books?: Object;
}

export interface IndexHomeData {
  randomBooks: HomeBook[];
  socialBooks: HomeBook[];
  newBooks: HomeBook[];
}


