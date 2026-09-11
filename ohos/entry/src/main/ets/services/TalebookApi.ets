import { StorageKeys } from '../common/Constants';
import { BookNavResponse, UserInfoResponse } from '../common/Models';
import { AudioFileInfo, AudioInfoResponse, AudioConversionResponse, AudioCollectionResponse, AudioPurchaseResponse, EditBookRequest, ReferBook } from '../common/ApiTypes';
import { BookDetail, BookItem, parseBookDetail, parseBookItem } from './BookModels';
import { BookReviewItem, BookSocialStats, parseBookReview, parseBookReviews, parseSocialStats } from '../models/BookReviewModels';
import { HomeBook, ReadingDashboard, ReadingStatsSummary, parseHomeBooks, parseReadingDashboard, parseReadingStatsSummary } from '../models/HomeModels';
import { ExpectedItemModel, UserMemoItem, parseExpectedItems, parseUserMemos } from '../models/UserModels';
import { FormatReadingStat, ReadingDevice, parseFormatStats, parseReadingDevices } from '../models/DeviceModels';
import { TalebookCoreService } from './TalebookCoreService';

export { EditBookRequest, ReferBook, AudioFileInfo, AudioInfoResponse, AudioConversionResponse, AudioCollectionResponse, AudioPurchaseResponse };
export { AdminBookListResponse, ApiMessageResult, AccessStatusResponse, WhoAmIResponse, UploadBookResponse, CropCoverResult, ToolboxDataResponse, ToolboxTaskProgressResponse, MimoTtsConvertRequest, MimoTtsTestRequest, MimoTtsConfigResponse, MimoTtsClonesResponse, MimoTtsPromptsResponse, EpubBeautifyRunOptions, BookBarnApplyTokenResponse, BookFilePathResponse, TxtReadResponse, TxtParserResponse, BatchTagUpdateResponse, BatchCategoryResponse, ClearRareTagsResponse, LibraryStatsResponse, LibraryStatsData, SysInfoResponse, AdminRunningTasksResponse, BatchAddRunResponse, BatchAddStatusResponse, ImportStatusResponse, AudioImportStatusResponse, ToolboxStoreIndexResponse, BarcodeResponse, InstallStatusResponse, InstallRequest, StampStatusResponse, ThanksNotesResponse, AdminTokenResponse, BookbarnAdminTokenResponse };

interface BookListPayload {
  books?: Array<Record<string, Object>>;
  total?: number;
}

interface IndexPayload {
  random?: Array<Record<string, Object>>;
  recent?: Array<Record<string, Object>>;
}

interface BookDetailPayload {
  err?: string;
  book?: Record<string, Object>;
}

interface ApiResult {
  err?: string;
}

interface ApiMessageResult extends ApiResult {
  msg?: string;
}
interface AccessStatusResponse extends ApiMessageResult {
  version?: string;
  welcome?: string;
}

interface WhoAmIResponse extends ApiResult {
  userId?: number;
  username?: string;
  canRead?: boolean;
  isActive?: boolean;
  is_guest?: boolean;
  msg?: string;
}

/** 取服务端错误响应中人类可读的提示（优先 msg，回退 err 错误码）。 */
export function apiErrorMessage(rsp: ApiResult): string {
  const msg = (rsp as ApiMessageResult).msg;
  if (msg !== undefined && msg.length > 0) {
    return msg;
  }
  return rsp.err !== undefined && rsp.err !== 'ok' ? rsp.err : '';
}

interface AdminSettingsResponse extends ApiMessageResult {
  settings?: Record<string, Object>;
  sns?: Array<Record<string, Object>>;
  site_url?: string;
}

interface AdminBookListResponse extends ApiMessageResult {
  items?: Array<Record<string, Object>>;
  total?: number;
}

interface AdminUserPage {
  items?: Array<Record<string, Object>>;
  total?: number;
}

interface AdminUsersResponse extends ApiMessageResult {
  users?: AdminUserPage;
  settings?: Record<string, Object>;
}

interface TrashBooksResponse extends ApiMessageResult {
  books?: Array<Record<string, Object>>;
}

interface TrashSizeResponse extends ApiMessageResult {
  sizes?: Record<string, Object>;
}

interface AdminReviewsResponse extends ApiMessageResult {
  total?: number;
  page?: number;
  page_size?: number;
  reviews?: Array<Record<string, Object>>;
}

interface AdminImportListResponse extends ApiMessageResult {
  items?: Array<Record<string, Object>>;
  total?: number;
  scanning?: boolean;
  importing?: boolean;
  summary?: Record<string, Object>;
  scan_dir?: string;
}

interface AdminSyslogResponse extends ApiMessageResult {
  lines?: Array<string>;
  href?: string;
}

interface AdminResourcesResponse extends ApiMessageResult {
  resources?: Array<Record<string, Object>>;
}

/** 书库统计数据 */
interface LibraryStatsData {
  total_books?: number;
  ebook_count?: number;
  physical_count?: number;
  month_ebook_count?: number;
  month_physical_count?: number;
  current_year?: number;
  current_month?: number;
}

/** GET /api/library/stats */
interface LibraryStatsResponse extends ApiMessageResult {
  stats?: LibraryStatsData;
}

/** GET /api/sysinfo */
interface SysInfoResponse extends ApiMessageResult {
  data?: Record<string, Object>;
}

/** GET /api/admin/tasks/running */
interface AdminRunningTasksResponse extends ApiMessageResult {
  tasks?: Array<Record<string, Object>>;
  messages?: Array<Record<string, Object>>;
}

/** POST /api/admin/batch_add/run */
interface BatchAddRunResponse extends ApiMessageResult {
  total?: number;
}

/** GET /api/admin/batch_add/status */
interface BatchAddStatusResponse extends ApiMessageResult {
  status?: Record<string, Object>;
  summary?: Record<string, Object>;
  batch_adding?: boolean;
}

/** GET /api/admin/import/status */
interface ImportStatusResponse extends ApiMessageResult {
  task?: Record<string, Object>;
  status?: Record<string, Object>;
  summary?: Record<string, Object>;
  scanning?: boolean;
  ignored_errors?: Object;
  importing?: boolean;
}

/** GET /api/admin/audio_import/status */
interface AudioImportStatusResponse extends ApiMessageResult {
  status?: Record<string, Object>;
  summary?: Record<string, Object>;
  audio_importing?: boolean;
}

/** POST /api/admin/barcode */
interface BarcodeResponse extends ApiMessageResult {
  isbn?: string;
}

/** GET /api/admin/install */
interface InstallStatusResponse extends ApiMessageResult {
  installed?: boolean;
}

/** POST /api/admin/install 表单/查询参数 */
interface InstallRequest {
  username: string;
  password: string;
  email: string;
  title: string;
  language?: string;
  invite?: string;
  code?: string;
}

/** GET /api/admin/stamp */
interface StampStatusResponse extends ApiMessageResult {
  exists?: boolean;
}

/** GET /api/admin/thanks/notes */
interface ThanksNotesResponse extends ApiMessageResult {
  names?: string[];
}

/** GET /api/admin/token */
interface AdminTokenResponse extends ApiMessageResult {
  token?: string;
}

/** POST /api/admin/bookbarn/token/apply */
interface BookbarnAdminTokenResponse extends ApiMessageResult {
  token?: string;
}


interface UploadBookResponse extends ApiMessageResult {
  book_id?: number;
}
export interface UploadBatchItem {
  id?: number;
  path?: string;
  name?: string;
  title?: string;
  author?: string;
  status?: string;
  book_id?: number;
}

export interface UploadBatchStatusResponse extends ApiMessageResult {
  items?: UploadBatchItem[];
  importing?: boolean;
}

export interface UploadBatchStartResponse extends ApiMessageResult {
  import_id?: number;
  file_count?: number;
}
export interface BatchUploadFile {
  localPath: string;
  name: string;
  relativePath?: string;
}
/** GET /api/sync 拉取结果；各 kind 为变更记录数组，未请求的 kind 可能为 null。 */
export interface SyncPullResponse {
  err?: string;
  msg?: string;
  books?: Array<Record<string, Object>> | null;
  notes?: Array<Record<string, Object>> | null;
  configs?: Array<Record<string, Object>> | null;
}

/** POST /api/sync 推送体：按 kind 分组的记录列表。 */
export interface SyncPushPayload {
  books?: Array<Record<string, Object>>;
  notes?: Array<Record<string, Object>>;
  configs?: Array<Record<string, Object>>;
}

export interface SyncImportAnchor {
  id: string;
  text?: string;
  chapterHint?: string;
  note?: string;
}

export interface SyncImportRequest {
  bookId: number;
  anchors: SyncImportAnchor[];
  onAmbiguous?: string;
  dryRun?: boolean;
  force?: boolean;
}

export interface SyncImportResponse extends ApiMessageResult {
  book_id?: number;
  book_hash?: string;
  dry_run?: boolean;
  results?: Array<Record<string, Object>>;
  pushed?: Record<string, Object>;
}

export interface SyncImportClearResponse extends ApiMessageResult {
  book_id?: number;
  book_hash?: string;
  cleared?: number;
}

interface AdminToolListResponse extends ApiMessageResult {
  tools?: Array<Record<string, Object>>;
}
interface ToolboxStoreIndexResponse extends ApiMessageResult {
  enabled?: boolean;
  tools?: Array<Record<string, Object>>;
}

interface ToolboxDataResponse extends ApiMessageResult {
  data?: Record<string, Object>;
}

/** VIP 配额与到期（GET /api/user/vip）。 */
export interface VipInfoResponse extends ApiResult {
  vipquota?: number;
  vip_expire?: string;
}

/** 书籍文件路径（GET /api/book/:id/filepath?format=）。 */
interface BookFilePathResponse extends ApiMessageResult {
  data?: Record<string, Object>;
}

/** TXT 在线阅读内容（GET /api/read/txt/:id）。 */
interface TxtReadResponse extends ApiMessageResult {
  content?: string;
}

/** TXT 解析结果（GET /api/book/txt/parser）。 */
interface TxtParserResponse extends ApiMessageResult {
  data?: Record<string, Object>;
}

/** 按标签批量更新书籍标签（POST /api/book/update_tags?tag=）。 */
interface BatchTagUpdateResponse extends ApiMessageResult {
  count?: number;
  total?: number;
}

/** 批量设置分类（POST /api/book/category）。 */
interface BatchCategoryResponse extends ApiMessageResult {
  count?: number;
}

interface BatchCategoryOpts {
  author?: string;
  tag?: string;
  series?: string;
}

/** 清理稀有标签（POST /api/clear_rare_tags）。 */
interface ClearRareTagsResponse extends ApiMessageResult {
  book_count?: number;
  tag_count?: number;
}

interface ToolboxTaskProgressResponse extends ApiMessageResult {
  data?: Record<string, Object>;
}

/** MiMo TTS 转换请求（POST /api/toolbox/mimo_tts/convert）。 */
interface MimoTtsConvertRequest {
  bookId: number;
  apiKey: string;
  voiceDesc?: string;
  apiUrl?: string;
  modelName?: string;
  apiType?: string;
  voiceName?: string;
  authType?: string;
  cloneVoice?: string;
}

/** MiMo TTS 连接测试请求（POST /api/toolbox/mimo_tts/test，无 book_id）。 */
interface MimoTtsTestRequest {
  apiKey: string;
  voiceDesc?: string;
  apiUrl?: string;
  modelName?: string;
  apiType?: string;
  voiceName?: string;
  authType?: string;
  cloneVoice?: string;
}

interface MimoTtsConfigResponse extends ApiMessageResult {
  config?: Record<string, Object> | null;
}

interface MimoTtsClonesResponse extends ApiMessageResult {
  clones?: Array<Record<string, Object>>;
}

interface MimoTtsPromptsResponse extends ApiMessageResult {
  prompts?: Array<Record<string, Object>>;
}

/** EPUB 美化运行可选参数（POST /api/toolbox/epub_beautify/run）。 */
interface EpubBeautifyRunOptions {
  preset?: string;
  tocStyle?: string;
  useSystemFonts?: boolean;
  suffix?: string;
  fontOverrides?: Record<string, Object>;
  tocDepth?: number;
  cleanup?: Record<string, Object>;
  paletteOverrides?: Record<string, Object>;
  pageTint?: boolean | string;
  dialogue?: boolean;
  titleSplit?: boolean;
  paraMode?: string;
  paraIndent?: boolean;
  paraGap?: number;
  tocColumns?: boolean;
  notes?: boolean;
  noteMark?: string;
  bgImage?: boolean;
}

interface BookBarnApplyTokenResponse extends ApiMessageResult {
  token?: string;
}


interface AdminMemoListResponse extends ApiMessageResult {
  data?: Record<string, Object>;
}

interface PageQuery {
  page: number;
  limit: number;
}

interface SearchQuery {
  name: string;
  page: number;
  limit: number;
}

interface LimitQuery {
  limit: number;
}

interface MetaQuery {
  page: number;
  limit: number;
}

interface ReferQuery {
  title: string;
}

/** 解析 JSON；若响应体为 HTML/重定向等非 JSON，返回 { err: 'ok' } 避免崩溃。 */
function parseJsonOrOk(raw: string): ApiMessageResult {
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

function appendQuery(base: string, key: string, value: string | number): string {
  const sep = base.indexOf('?') >= 0 ? '&' : '?';
  return `${base}${sep}${encodeURIComponent(key)}=${encodeURIComponent(String(value))}`;
}

function buildPagePath(base: string, page: number, limit: number): string {
  let path = base;
  path = appendQuery(path, 'page', page);
  path = appendQuery(path, 'limit', limit);
  return path;
}

function parseList(raw: string): BookItem[] {
  const data = JSON.parse(raw) as Array<Record<string, Object>> | BookListPayload;
  let books: Array<Record<string, Object>> = [];
  if (Array.isArray(data)) {
    books = data;
  } else if (data.books !== undefined) {
    books = data.books;
  }
  const result: BookItem[] = [];
  for (let i = 0; i < books.length; i++) {
    result.push(parseBookItem(books[i]));
  }
  return result;
}

/** High-level Talebook REST API via C++ core. */
export class TalebookApi {
  static async resolveCoverUrl(coverUrl: string): Promise<string> {
    if (coverUrl.length === 0) {
      return '';
    }
    if (coverUrl.startsWith('http://') || coverUrl.startsWith('https://')) {
      return coverUrl;
    }
    const base = await TalebookCoreService.secureGet(StorageKeys.TALEBOOK_URL);
    if (base === null || base.length === 0) {
      return coverUrl;
    }
    const normalized = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return coverUrl.startsWith('/') ? `${normalized}${coverUrl}` : `${normalized}/${coverUrl}`;
  }

  static async getIndex(): Promise<BookItem[]> {
    const raw = await TalebookCoreService.talebookGet('/api/index');
    const data = JSON.parse(raw) as IndexPayload;
    const recent = data.recent ?? [];
    const result: BookItem[] = [];
    for (let i = 0; i < recent.length; i++) {
      result.push(parseBookItem(recent[i]));
    }
    return result;
  }

  static async getRecent(page?: number, limit?: number): Promise<BookItem[]> {
    const raw = await TalebookCoreService.talebookGet(
      buildPagePath('/api/recent', page ?? 1, limit ?? 20));
    return parseList(raw);
  }

  static async getHot(page?: number, limit?: number): Promise<BookItem[]> {
    const raw = await TalebookCoreService.talebookGet(
      buildPagePath('/api/hot', page ?? 1, limit ?? 20));
    return parseList(raw);
  }

  static async search(name: string, page?: number, limit?: number): Promise<BookItem[]> {
    let path = '/api/search';
    path = appendQuery(path, 'name', name);
    path = appendQuery(path, 'page', page ?? 1);
    path = appendQuery(path, 'limit', limit ?? 20);
    const raw = await TalebookCoreService.talebookGet(path);
    return parseList(raw);
  }

  static async getBookDetail(bookId: number): Promise<BookDetail | null> {
    const raw = await TalebookCoreService.talebookGet(`/api/book/${bookId}`);
    const resp = JSON.parse(raw) as BookDetailPayload;
    if (resp.err !== undefined && resp.err !== 'ok' && resp.err.length > 0) {
      throw new Error(resp.err);
    }
    if (resp.book === undefined) {
      return null;
    }
    return parseBookDetail(resp.book);
  }

  static async signIn(username: string, password: string): Promise<void> {
    const form = `username=${encodeURIComponent(username)}&password=${encodeURIComponent(password)}`;
    await TalebookCoreService.talebookPostForm('/api/user/sign_in', form);
  }

  static async signOut(): Promise<void> {
    await TalebookCoreService.talebookPost('/api/user/sign_out', '{}');
  }

  static async getUserInfo(_detail?: boolean): Promise<UserInfoResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/user/info');
    return JSON.parse(raw) as UserInfoResponse;
  }
  /** 访问码状态（GET /api/access）。err=free 表示无需/已通过，ok 表示仍需输入。 */
  static async getAccessStatus(): Promise<AccessStatusResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/access');
    return JSON.parse(raw) as AccessStatusResponse;
  }

  /** 提交访问码（POST /api/access，JSON body: invite_code）。 */
  static async submitAccessCode(inviteCode: string): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'invite_code': inviteCode };
    const raw = await TalebookCoreService.talebookPost('/api/access', JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 用户注册（POST /api/user/sign_up，form：username/nickname/email/password）。 */
  static async signUp(
    username: string,
    nickname: string,
    email: string,
    password: string,
  ): Promise<ApiMessageResult> {
    const form = `username=${encodeURIComponent(username)}` +
      `&nickname=${encodeURIComponent(nickname)}` +
      `&email=${encodeURIComponent(email)}` +
      `&password=${encodeURIComponent(password)}`;
    const raw = await TalebookCoreService.talebookPostForm('/api/user/sign_up', form);
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 重置密码（POST /api/user/reset，form：username/email）。新密码由服务端邮件下发。 */
  static async resetPassword(username: string, email: string): Promise<ApiMessageResult> {
    const form = `username=${encodeURIComponent(username)}&email=${encodeURIComponent(email)}`;
    const raw = await TalebookCoreService.talebookPostForm('/api/user/reset', form);
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 当前登录身份摘要（GET /api/user/whoami）。未登录且允许访客阅读时 is_guest=true。 */
  static async whoAmI(): Promise<WhoAmIResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/user/whoami');
    return JSON.parse(raw) as WhoAmIResponse;
  }

  /** 重发激活邮件（GET /api/user/active/send）。 */
  static async sendActiveEmail(): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookGet('/api/user/active/send');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** VIP 信息（GET /api/user/vip）。 */
  static async getVipInfo(): Promise<VipInfoResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/user/vip');
    return JSON.parse(raw) as VipInfoResponse;
  }

  /** 清空站内消息（POST /api/user/messages/clear）。 */
  static async clearUserMessages(): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/user/messages/clear', '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 账号激活链接路径（服务端重定向至 /active/success；供 WebView/外链使用）。 */
  static userActivePath(username: string, code: string): string {
    return `/api/active/${encodeURIComponent(username)}/${encodeURIComponent(code)}`;
  }

  /** 执行账号激活（GET /api/active/:user/:code；可能返回 HTML/重定向）。 */
  static async activateUser(username: string, code: string): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookGet(TalebookApi.userActivePath(username, code));
    return parseJsonOrOk(raw);
  }

  /** OAuth 完成回调路径（GET /api/done/；资源路径，供 WebView 跳转）。 */
  static oauthDonePath(): string {
    return '/api/done/';
  }


  static async getReadingBooks(limit?: number): Promise<BookItem[]> {
    const path = appendQuery('/api/reading', 'limit', limit ?? 20);
    const raw = await TalebookCoreService.talebookGet(path);
    return parseList(raw);
  }

  static async getFavorites(limit?: number): Promise<BookItem[]> {
    const path = appendQuery('/api/favorites', 'limit', limit ?? 20);
    const raw = await TalebookCoreService.talebookGet(path);
    return parseList(raw);
  }

  static async getMessages(): Promise<Array<Record<string, Object>>> {
    const raw = await TalebookCoreService.talebookGet('/api/user/messages');
    return JSON.parse(raw) as Array<Record<string, Object>>;
  }

  static async getAdminBooks(page: number, limit: number): Promise<BookItem[]> {
    const raw = await TalebookCoreService.talebookGet(buildPagePath('/api/admin/books', page, limit));
    return parseList(raw);
  }

  static async getAdminBookList(page: number, num: number, search: string = ''): Promise<AdminBookListResponse> {
    let path = '/api/admin/book/list';
    path = appendQuery(path, 'page', page);
    path = appendQuery(path, 'num', num);
    if (search.length > 0) {
      path = appendQuery(path, 'search', search);
    }
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as AdminBookListResponse;
  }

  static async getAdminUserList(page: number, num: number): Promise<AdminUsersResponse> {
    let path = '/api/admin/users';
    path = appendQuery(path, 'page', page);
    path = appendQuery(path, 'num', num);
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as AdminUsersResponse;
  }

  static async updateAdminUser(payload: Record<string, Object>): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/admin/users', JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async createAdminUser(
    username: string,
    password: string,
    nickname: string,
    email: string,
  ): Promise<ApiMessageResult> {
    const form = `username=${encodeURIComponent(username)}&password=${encodeURIComponent(password)}` +
      `&nickname=${encodeURIComponent(nickname)}&email=${encodeURIComponent(email)}`;
    const raw = await TalebookCoreService.talebookPostForm('/api/user/new', form);
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async getTrashBooks(): Promise<TrashBooksResponse> {
    const raw = await TalebookCoreService.adminTrashBooks();
    return JSON.parse(raw) as TrashBooksResponse;
  }

  static async getTrashSize(): Promise<TrashSizeResponse> {
    const raw = await TalebookCoreService.adminTrashSize();
    return JSON.parse(raw) as TrashSizeResponse;
  }

  static async restoreTrashBooks(bookIds: number[]): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.adminTrashRestore(JSON.stringify(bookIds));
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async purgeTrashBooks(bookIds: number[]): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.adminTrashPurge(JSON.stringify(bookIds));
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async clearTrash(): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.adminTrashClear();
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async getAdminReviews(status: string, page: number, pageSize: number): Promise<AdminReviewsResponse> {
    const raw = await TalebookCoreService.adminBookReviews(status, page, pageSize);
    return JSON.parse(raw) as AdminReviewsResponse;
  }

  static async moderateAdminReview(reviewId: number, action: string): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.adminBookReviewAction(reviewId, action);
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async getAdminImportList(page: number, num: number, filter: string): Promise<AdminImportListResponse> {
    const raw = await TalebookCoreService.adminImportList(page, num, filter);
    return JSON.parse(raw) as AdminImportListResponse;
  }

  static async runAdminImport(filelistJson: string, force: boolean): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.adminImportRun(filelistJson, force);
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async cancelAdminImport(): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.adminImportCancel();
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async deleteAdminImportRecords(hashlistJson: string): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.adminImportDelete(hashlistJson);
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async getAdminSyslog(): Promise<AdminSyslogResponse> {
    const raw = await TalebookCoreService.adminSyslog();
    return JSON.parse(raw) as AdminSyslogResponse;
  }

  static async getAdminResources(): Promise<AdminResourcesResponse> {
    const raw = await TalebookCoreService.adminResources();
    return JSON.parse(raw) as AdminResourcesResponse;
  }

  /** 书库统计（GET /api/library/stats）。 */
  static async getLibraryStats(): Promise<LibraryStatsResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/library/stats');
    return JSON.parse(raw) as LibraryStatsResponse;
  }

  /** 系统信息（GET /api/sysinfo）。 */
  static async getSysInfo(): Promise<SysInfoResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/sysinfo');
    return JSON.parse(raw) as SysInfoResponse;
  }

  /** 正在运行的管理任务（GET /api/admin/tasks/running）。 */
  static async getAdminRunningTasks(): Promise<AdminRunningTasksResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/tasks/running');
    return JSON.parse(raw) as AdminRunningTasksResponse;
  }

  /** 批量添加（POST /api/admin/batch_add/run，multipart 字段 csv_file）。 */
  static async runBatchAdd(localPath: string, fileName: string): Promise<BatchAddRunResponse> {
    const raw = await TalebookCoreService.talebookUploadFile(
      '/api/admin/batch_add/run', localPath, 'csv_file', fileName);
    return JSON.parse(raw) as BatchAddRunResponse;
  }

  /** 批量添加状态（GET /api/admin/batch_add/status）。 */
  static async getBatchAddStatus(): Promise<BatchAddStatusResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/batch_add/status');
    return JSON.parse(raw) as BatchAddStatusResponse;
  }

  /** 导入任务状态（GET /api/admin/import/status）。 */
  static async getImportStatus(): Promise<ImportStatusResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/import/status');
    return JSON.parse(raw) as ImportStatusResponse;
  }

  /** 启动有声导入（POST /api/admin/audio_import/run）。 */
  static async runAudioImport(): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/admin/audio_import/run', '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 有声导入状态（GET /api/admin/audio_import/status）。 */
  static async getAudioImportStatus(): Promise<AudioImportStatusResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/audio_import/status');
    return JSON.parse(raw) as AudioImportStatusResponse;
  }

  /** 测试有声连接（POST /api/admin/audio/test）。非空时才带 proxy。 */
  static async testAudioConnection(
    proxy: string = '',
    useBookbarnProxy: boolean = false,
  ): Promise<ApiMessageResult> {
    const body: Record<string, Object> = {
      'use_bookbarn_proxy': useBookbarnProxy,
    };
    if (proxy.length > 0) {
      body['proxy'] = proxy;
    }
    const raw = await TalebookCoreService.talebookPost('/api/admin/audio/test', JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 条码识别（POST /api/admin/barcode，multipart 字段 barcode_image）。 */
  static async recognizeBarcode(localPath: string, fileName: string): Promise<BarcodeResponse> {
    const raw = await TalebookCoreService.talebookUploadFile(
      '/api/admin/barcode', localPath, 'barcode_image', fileName);
    return JSON.parse(raw) as BarcodeResponse;
  }

  /** 申请书栈 Token（POST /api/admin/bookbarn/token/apply）。 */
  static async applyBookbarnToken(): Promise<BookbarnAdminTokenResponse> {
    const raw = await TalebookCoreService.talebookPost('/api/admin/bookbarn/token/apply', '{}');
    return JSON.parse(raw) as BookbarnAdminTokenResponse;
  }

  /** 安装状态（GET /api/admin/install）。 */
  static async getInstallStatus(): Promise<InstallStatusResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/install');
    return JSON.parse(raw) as InstallStatusResponse;
  }

  /** 执行首次安装（POST /api/admin/install，服务端读 query/form 参数）。 */
  static async runInstall(opts: InstallRequest): Promise<ApiMessageResult> {
    let path = '/api/admin/install?username=' + encodeURIComponent(opts.username)
      + '&password=' + encodeURIComponent(opts.password)
      + '&email=' + encodeURIComponent(opts.email)
      + '&title=' + encodeURIComponent(opts.title);
    if (opts.language !== undefined && opts.language.length > 0) {
      path += '&language=' + encodeURIComponent(opts.language);
    }
    if (opts.invite !== undefined && opts.invite.length > 0) {
      path += '&invite=' + encodeURIComponent(opts.invite);
    }
    if (opts.code !== undefined && opts.code.length > 0) {
      path += '&code=' + encodeURIComponent(opts.code);
    }
    const raw = await TalebookCoreService.talebookPost(path, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 图章是否存在（GET /api/admin/stamp）。 */
  static async getStampStatus(): Promise<StampStatusResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/stamp');
    return JSON.parse(raw) as StampStatusResponse;
  }

  /** 上传图章 PNG（POST /api/admin/stamp，multipart 字段 file）。 */
  static async uploadStamp(localPath: string, fileName: string): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookUploadFile(
      '/api/admin/stamp', localPath, 'file', fileName);
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 系统日志下载相对路径（GET /api/admin/syslog/download，二进制）。 */
  static adminSyslogDownloadPath(): string {
    return '/api/admin/syslog/download';
  }

  /** 致谢名单（GET /api/admin/thanks/notes）。 */
  static async getThanksNotes(): Promise<ThanksNotesResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/thanks/notes');
    return JSON.parse(raw) as ThanksNotesResponse;
  }

  /** 生成 MCP Token（GET /api/admin/token）。 */
  static async generateAdminToken(): Promise<AdminTokenResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/token');
    return JSON.parse(raw) as AdminTokenResponse;
  }


  /**
   * 上传 SSL 证书（POST /api/admin/ssl）。
   * multipart 字段：ssl_crt、ssl_key（需 native 重建后生效）。
   */
  static async uploadAdminSsl(
    crtLocalPath: string,
    crtFileName: string,
    keyLocalPath: string,
    keyFileName: string,
  ): Promise<ApiMessageResult> {
    const files: Array<Record<string, Object>> = [
      { 'path': crtLocalPath, 'name': crtFileName, 'field': 'ssl_crt' },
      { 'path': keyLocalPath, 'name': keyFileName, 'field': 'ssl_key' },
    ];
    const raw = await TalebookCoreService.talebookUploadFiles(
      '/api/admin/ssl', JSON.stringify(files), '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 经书栈更新作者（POST /api/admin/update_author）。 */
  static async adminUpdateAuthor(name: string): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'name': name };
    const raw = await TalebookCoreService.talebookPost('/api/admin/update_author', JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 工具列表（GET /api/toolbox/list）。管理页请传 includeDisabled=true。 */
  static async getAdminToolList(includeDisabled: boolean = false): Promise<AdminToolListResponse> {
    const path = includeDisabled ? '/api/toolbox/list?include_disabled=1' : '/api/toolbox/list';
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as AdminToolListResponse;
  }

  /** 启用/禁用工具（POST /api/toolbox/:id/enable|disable）。 */
  static async adminToolAction(toolId: string, action: string): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.adminToolAction(toolId, action);
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async enableToolboxTool(toolId: string): Promise<ApiMessageResult> {
    return TalebookApi.adminToolAction(toolId, 'enable');
  }

  static async disableToolboxTool(toolId: string): Promise<ApiMessageResult> {
    return TalebookApi.adminToolAction(toolId, 'disable');
  }

  /** 卸载工具（DELETE /api/toolbox/:id）。 */
  static async uninstallToolboxTool(toolId: string): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookDelete(`/api/toolbox/${toolId}`);
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 工具商店索引（GET /api/toolbox/store/index）。 */
  static async getToolboxStoreIndex(refresh: boolean = false): Promise<ToolboxStoreIndexResponse> {
    const path = refresh ? '/api/toolbox/store/index?refresh=1' : '/api/toolbox/store/index';
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as ToolboxStoreIndexResponse;
  }

  /** 从商店安装/更新工具（POST /api/toolbox/:id/install）。 */
  static async installToolboxStoreTool(toolId: string): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/toolbox/${toolId}/install`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /**
   * 通用工具箱 GET：path 为 `/api/toolbox/` 之后的后缀，如 `mimo_tts/progress`。
   * 覆盖各工具细接口的查询/进度类路由。
   */
  static async toolboxGet(path: string): Promise<Record<string, Object>> {
    const normalized = path.startsWith('/') ? path.substring(1) : path;
    const raw = await TalebookCoreService.talebookGet(`/api/toolbox/${normalized}`);
    return JSON.parse(raw) as Record<string, Object>;
  }

  /**
   * 通用工具箱 POST：path 为 `/api/toolbox/` 之后的后缀。
   * 覆盖各工具细接口的启动/提交类路由。
   */
  static async toolboxPost(path: string, body: Record<string, Object> = {}): Promise<Record<string, Object>> {
    const normalized = path.startsWith('/') ? path.substring(1) : path;
    const raw = await TalebookCoreService.talebookPost(`/api/toolbox/${normalized}`,
      JSON.stringify(body));
    return JSON.parse(raw) as Record<string, Object>;
  }

  /** 通用工具箱上传（multipart），如 minify_pdf/upload、install/upload。 */
  static async toolboxUpload(
    path: string,
    localPath: string,
    fieldName: string,
    fileName: string,
    fields: Record<string, Object> = {},
  ): Promise<Record<string, Object>> {
    const normalized = path.startsWith('/') ? path.substring(1) : path;
    const raw = await TalebookCoreService.talebookUploadFile(
      `/api/toolbox/${normalized}`, localPath, fieldName, fileName, JSON.stringify(fields));
    return JSON.parse(raw) as Record<string, Object>;
  }

  /** 古书下载（POST /api/toolbox/rare_book_downloader）。 */
  static async rareBookDownload(url: string): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/rare_book_downloader',
      JSON.stringify({ 'url': url } as Record<string, Object>));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 合并格式（POST /api/toolbox/merge_formats/merge）。 */
  static async mergeBookFormats(sourceId: number, targetId: number): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'source_id': sourceId, 'target_id': targetId };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/merge_formats/merge',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 书名语言检测（POST /api/toolbox/review_book_language）。 */
  static async reviewBookLanguage(): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/review_book_language', '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 作者清理/替换（POST /api/toolbox/author_clean，action: clean|replace）。 */
  static async authorClean(
    action: string,
    authorName: string,
    newAuthorName: string = '',
  ): Promise<ApiMessageResult> {
    const body: Record<string, Object> = {
      'action': action,
      'author_name': authorName,
    };
    if (newAuthorName.length > 0) {
      body['new_author_name'] = newAuthorName;
    }
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/author_clean',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }


  // ---- mimo_tts ----

  /** MiMo TTS 转换（POST /api/toolbox/mimo_tts/convert）。 */
  static async mimoTtsConvert(req: MimoTtsConvertRequest): Promise<ApiMessageResult> {
    const body: Record<string, Object> = {
      'book_id': req.bookId,
      'api_key': req.apiKey,
    };
    if (req.voiceDesc !== undefined) {
      body['voice_desc'] = req.voiceDesc;
    }
    if (req.apiUrl !== undefined) {
      body['api_url'] = req.apiUrl;
    }
    if (req.modelName !== undefined) {
      body['model_name'] = req.modelName;
    }
    if (req.apiType !== undefined) {
      body['api_type'] = req.apiType;
    }
    if (req.voiceName !== undefined) {
      body['voice_name'] = req.voiceName;
    }
    if (req.authType !== undefined) {
      body['auth_type'] = req.authType;
    }
    if (req.cloneVoice !== undefined) {
      body['clone_voice'] = req.cloneVoice;
    }
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/mimo_tts/convert',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** MiMo TTS 进度（GET /api/toolbox/mimo_tts/progress）。 */
  static async mimoTtsProgress(): Promise<ToolboxTaskProgressResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/mimo_tts/progress');
    return JSON.parse(raw) as ToolboxTaskProgressResponse;
  }

  /** MiMo TTS 已保存配置（GET /api/toolbox/mimo_tts/config）。 */
  static async mimoTtsGetConfig(): Promise<MimoTtsConfigResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/mimo_tts/config');
    return JSON.parse(raw) as MimoTtsConfigResponse;
  }

  /** 清除 MiMo TTS 已保存配置（DELETE /api/toolbox/mimo_tts/config）。 */
  static async mimoTtsDeleteConfig(): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookDelete('/api/toolbox/mimo_tts/config');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** MiMo TTS 连接测试（POST /api/toolbox/mimo_tts/test）。 */
  static async mimoTtsTest(req: MimoTtsTestRequest): Promise<ApiMessageResult> {
    const body: Record<string, Object> = {
      'api_key': req.apiKey,
    };
    if (req.voiceDesc !== undefined) {
      body['voice_desc'] = req.voiceDesc;
    }
    if (req.apiUrl !== undefined) {
      body['api_url'] = req.apiUrl;
    }
    if (req.modelName !== undefined) {
      body['model_name'] = req.modelName;
    }
    if (req.apiType !== undefined) {
      body['api_type'] = req.apiType;
    }
    if (req.voiceName !== undefined) {
      body['voice_name'] = req.voiceName;
    }
    if (req.authType !== undefined) {
      body['auth_type'] = req.authType;
    }
    if (req.cloneVoice !== undefined) {
      body['clone_voice'] = req.cloneVoice;
    }
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/mimo_tts/test',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 上传克隆音色（POST /api/toolbox/mimo_tts/clone/upload，multipart field=file）。 */
  static async mimoTtsCloneUpload(
    localPath: string,
    fileName: string,
    voiceName: string,
  ): Promise<ToolboxDataResponse> {
    const fields: Record<string, Object> = { 'voice_name': voiceName };
    const raw = await TalebookCoreService.talebookUploadFile(
      '/api/toolbox/mimo_tts/clone/upload', localPath, 'file', fileName, JSON.stringify(fields));
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** 克隆音色列表（GET /api/toolbox/mimo_tts/clone/list）。 */
  static async mimoTtsCloneList(): Promise<MimoTtsClonesResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/mimo_tts/clone/list');
    return JSON.parse(raw) as MimoTtsClonesResponse;
  }

  /** 删除克隆音色（POST /api/toolbox/mimo_tts/clone/delete）。 */
  static async mimoTtsCloneDelete(voiceName: string): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'voice_name': voiceName };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/mimo_tts/clone/delete',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 克隆音色音频二进制路径（GET /api/toolbox/mimo_tts/clone/audio）。 */
  static mimoTtsCloneAudioPath(voiceName: string): string {
    return `/api/toolbox/mimo_tts/clone/audio?voice_name=${encodeURIComponent(voiceName)}`;
  }

  /** 音色提示词列表（GET /api/toolbox/mimo_tts/prompt/list）。 */
  static async mimoTtsPromptList(): Promise<MimoTtsPromptsResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/mimo_tts/prompt/list');
    return JSON.parse(raw) as MimoTtsPromptsResponse;
  }

  /** 保存音色提示词（POST /api/toolbox/mimo_tts/prompt/save）。 */
  static async mimoTtsPromptSave(name: string, desc: string): Promise<ToolboxDataResponse> {
    const body: Record<string, Object> = { 'name': name, 'desc': desc };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/mimo_tts/prompt/save',
      JSON.stringify(body));
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** 删除音色提示词（POST /api/toolbox/mimo_tts/prompt/delete）。 */
  static async mimoTtsPromptDelete(name: string): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'name': name };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/mimo_tts/prompt/delete',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  // ---- epub_beautify ----

  /** EPUB 美化预览（POST /api/toolbox/epub_beautify/preview）。 */
  static async epubBeautifyPreview(bookId: number): Promise<ToolboxDataResponse> {
    const body: Record<string, Object> = { 'book_id': bookId };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/epub_beautify/preview',
      JSON.stringify(body));
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** EPUB 美化运行（POST /api/toolbox/epub_beautify/run）；bookIds 长度 1 即单本。 */
  static async epubBeautifyRun(
    bookIds: number[],
    options?: EpubBeautifyRunOptions,
  ): Promise<ApiMessageResult> {
    const body: Record<string, Object> = {
      'book_ids': bookIds as Object,
    };
    if (options !== undefined) {
      if (options.preset !== undefined) {
        body['preset'] = options.preset;
      }
      if (options.tocStyle !== undefined) {
        body['toc_style'] = options.tocStyle;
      }
      if (options.useSystemFonts !== undefined) {
        body['use_system_fonts'] = options.useSystemFonts;
      }
      if (options.suffix !== undefined) {
        body['suffix'] = options.suffix;
      }
      if (options.fontOverrides !== undefined) {
        body['font_overrides'] = options.fontOverrides;
      }
      if (options.tocDepth !== undefined) {
        body['toc_depth'] = options.tocDepth;
      }
      if (options.cleanup !== undefined) {
        body['cleanup'] = options.cleanup;
      }
      if (options.paletteOverrides !== undefined) {
        body['palette_overrides'] = options.paletteOverrides;
      }
      if (options.pageTint !== undefined) {
        body['page_tint'] = options.pageTint as Object;
      }
      if (options.dialogue !== undefined) {
        body['dialogue'] = options.dialogue;
      }
      if (options.titleSplit !== undefined) {
        body['title_split'] = options.titleSplit;
      }
      if (options.paraMode !== undefined) {
        body['para_mode'] = options.paraMode;
      }
      if (options.paraIndent !== undefined) {
        body['para_indent'] = options.paraIndent;
      }
      if (options.paraGap !== undefined) {
        body['para_gap'] = options.paraGap;
      }
      if (options.tocColumns !== undefined) {
        body['toc_columns'] = options.tocColumns;
      }
      if (options.notes !== undefined) {
        body['notes'] = options.notes;
      }
      if (options.noteMark !== undefined) {
        body['note_mark'] = options.noteMark;
      }
      if (options.bgImage !== undefined) {
        body['bg_image'] = options.bgImage;
      }
    }
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/epub_beautify/run',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** EPUB 美化进度（GET /api/toolbox/epub_beautify/progress）。 */
  static async epubBeautifyProgress(): Promise<ToolboxTaskProgressResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/epub_beautify/progress');
    return JSON.parse(raw) as ToolboxTaskProgressResponse;
  }

  /** 上传 EPUB 美化背景图（POST /api/toolbox/epub_beautify/bg_upload，multipart file）。 */
  static async epubBeautifyBgUpload(
    localPath: string,
    fileName: string,
  ): Promise<ToolboxDataResponse> {
    const raw = await TalebookCoreService.talebookUploadFile(
      '/api/toolbox/epub_beautify/bg_upload', localPath, 'file', fileName, '{}');
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** 选用内置背景图（POST /api/toolbox/epub_beautify/bg_upload，form: builtin_id）。 */
  static async epubBeautifyBgUploadBuiltin(builtinId: string): Promise<ToolboxDataResponse> {
    const form = `builtin_id=${encodeURIComponent(builtinId)}`;
    const raw = await TalebookCoreService.talebookPostForm(
      '/api/toolbox/epub_beautify/bg_upload', form);
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** EPUB 美化背景图元信息（GET /api/toolbox/epub_beautify/bg_meta）。 */
  static async epubBeautifyBgMeta(): Promise<ToolboxDataResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/epub_beautify/bg_meta');
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** EPUB 美化背景图二进制路径（GET /api/toolbox/epub_beautify/bg_raw）。 */
  static epubBeautifyBgRawPath(): string {
    return '/api/toolbox/epub_beautify/bg_raw';
  }

  /** 删除 EPUB 美化背景图（POST /api/toolbox/epub_beautify/bg_delete）。 */
  static async epubBeautifyBgDelete(): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/epub_beautify/bg_delete', '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  // ---- minify_pdf ----

  /** PDF 瘦身上传（POST /api/toolbox/minify_pdf/upload）。 */
  static async minifyPdfUpload(localPath: string, fileName: string): Promise<ToolboxDataResponse> {
    const raw = await TalebookCoreService.talebookUploadFile(
      '/api/toolbox/minify_pdf/upload', localPath, 'file', fileName, '{}');
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** PDF 瘦身处理（POST /api/toolbox/minify_pdf/process）。 */
  static async minifyPdfProcess(
    filename: string,
    params?: Record<string, Object>,
  ): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'filename': filename };
    if (params !== undefined) {
      body['params'] = params;
    }
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/minify_pdf/process',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** PDF 瘦身进度（GET /api/toolbox/minify_pdf/progress?filename=）。 */
  static async minifyPdfProgress(filename: string): Promise<ToolboxTaskProgressResponse> {
    const path = `/api/toolbox/minify_pdf/progress?filename=${encodeURIComponent(filename)}`;
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as ToolboxTaskProgressResponse;
  }

  /** PDF 瘦身下载路径（GET /api/toolbox/minify_pdf/download?filename=）。 */
  static minifyPdfDownloadPath(filename: string): string {
    return `/api/toolbox/minify_pdf/download?filename=${encodeURIComponent(filename)}`;
  }

  // ---- formats_pruning ----

  /** 格式精简启动（POST /api/toolbox/formats_pruning/start）。 */
  static async formatsPruningStart(deleteFormats: string[]): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'delete': deleteFormats as Object };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/formats_pruning/start',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 格式精简进度（GET /api/toolbox/formats_pruning/progress）。 */
  static async formatsPruningProgress(): Promise<ToolboxTaskProgressResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/formats_pruning/progress');
    return JSON.parse(raw) as ToolboxTaskProgressResponse;
  }

  // ---- epub_fixer ----

  /** EPUB 修复（POST /api/toolbox/epub_fixer/fix）。 */
  static async epubFixerFix(bookId: number, backup: boolean = false): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'book_id': bookId, 'backup': backup };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/epub_fixer/fix',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  // ---- epub_split ----

  /** EPUB 拆分章节列表（POST /api/toolbox/epub_split/chapters）。 */
  static async epubSplitChapters(bookId: number): Promise<ToolboxDataResponse> {
    const body: Record<string, Object> = { 'book_id': bookId };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/epub_split/chapters',
      JSON.stringify(body));
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** EPUB 拆分生成（POST /api/toolbox/epub_split/generate）。 */
  static async epubSplitGenerate(
    bookId: number,
    chapters: number[],
    useFirstChapterCover: boolean = false,
  ): Promise<ToolboxDataResponse> {
    const body: Record<string, Object> = {
      'book_id': bookId,
      'chapters': chapters as Object,
      'use_first_chapter_cover': useFirstChapterCover,
    };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/epub_split/generate',
      JSON.stringify(body));
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  // ---- chinese_converter ----

  /** 繁简转换（POST /api/toolbox/chinese_converter/convert）。 */
  static async chineseConverterConvert(
    bookId: number,
    direction: string = 't2s',
    mode: string = 'book',
    convertTitle: boolean = true,
    useA5: boolean = false,
    backup: boolean = false,
  ): Promise<ApiMessageResult> {
    const body: Record<string, Object> = {
      'book_id': bookId,
      'direction': direction,
      'mode': mode,
      'convert_title': convertTitle,
      'use_a5': useA5,
      'backup': backup,
    };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/chinese_converter/convert',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 繁简转换进度（GET /api/toolbox/chinese_converter/progress）。 */
  static async chineseConverterProgress(): Promise<ToolboxTaskProgressResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/chinese_converter/progress');
    return JSON.parse(raw) as ToolboxTaskProgressResponse;
  }

  // ---- txt_encoding_fixer ----

  /** TXT 编码分析（POST /api/toolbox/txt_encoding_fixer/analyze）。 */
  static async txtEncodingFixerAnalyze(bookId: number): Promise<ToolboxDataResponse> {
    const body: Record<string, Object> = { 'book_id': bookId };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/txt_encoding_fixer/analyze',
      JSON.stringify(body));
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** TXT 编码修复（POST /api/toolbox/txt_encoding_fixer/fix）。 */
  static async txtEncodingFixerFix(bookId: number): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'book_id': bookId };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/txt_encoding_fixer/fix',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** TXT 编码修复进度（GET /api/toolbox/txt_encoding_fixer/progress）。 */
  static async txtEncodingFixerProgress(): Promise<ToolboxTaskProgressResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/txt_encoding_fixer/progress');
    return JSON.parse(raw) as ToolboxTaskProgressResponse;
  }

  // ---- text_replace ----

  /** 正文替换预览（POST /api/toolbox/text_replace/preview）。 */
  static async textReplacePreview(
    bookId: number,
    pattern: string,
    replacement: string = '',
    useRegex: boolean = false,
    format: string = '',
  ): Promise<ToolboxDataResponse> {
    const body: Record<string, Object> = {
      'book_id': bookId,
      'pattern': pattern,
      'replacement': replacement,
      'use_regex': useRegex,
    };
    if (format.length > 0) {
      body['format'] = format;
    }
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/text_replace/preview',
      JSON.stringify(body));
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** 正文替换执行（POST /api/toolbox/text_replace/run）。 */
  static async textReplaceRun(
    bookId: number,
    pattern: string,
    replacement: string = '',
    useRegex: boolean = false,
    suffix: string = '',
    format: string = '',
  ): Promise<ApiMessageResult> {
    const body: Record<string, Object> = {
      'book_id': bookId,
      'pattern': pattern,
      'replacement': replacement,
      'use_regex': useRegex,
    };
    if (suffix.length > 0) {
      body['suffix'] = suffix;
    }
    if (format.length > 0) {
      body['format'] = format;
    }
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/text_replace/run',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 正文替换进度（GET /api/toolbox/text_replace/progress）。 */
  static async textReplaceProgress(): Promise<ToolboxTaskProgressResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/text_replace/progress');
    return JSON.parse(raw) as ToolboxTaskProgressResponse;
  }

  // ---- bookbarn_acceptor ----

  /** 书仓接收器状态（GET /api/toolbox/bookbarn_acceptor/status）。 */
  static async bookbarnAcceptorStatus(): Promise<ToolboxDataResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/bookbarn_acceptor/status');
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** 书仓接收开关（POST /api/toolbox/bookbarn_acceptor/toggle）。 */
  static async bookbarnAcceptorToggle(enabled: boolean): Promise<ToolboxDataResponse> {
    const body: Record<string, Object> = { 'enabled': enabled };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/bookbarn_acceptor/toggle',
      JSON.stringify(body));
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** 申请书仓 Token（POST /api/toolbox/bookbarn_acceptor/apply_token）。 */
  static async bookbarnAcceptorApplyToken(): Promise<BookBarnApplyTokenResponse> {
    const raw = await TalebookCoreService.talebookPost(
      '/api/toolbox/bookbarn_acceptor/apply_token', '{}');
    return JSON.parse(raw) as BookBarnApplyTokenResponse;
  }

  /** 设置书仓采集小时（POST /api/toolbox/bookbarn_acceptor/set_collection_hour）。 */
  static async bookbarnAcceptorSetCollectionHour(hour: number): Promise<ToolboxDataResponse> {
    const body: Record<string, Object> = { 'hour': hour };
    const raw = await TalebookCoreService.talebookPost(
      '/api/toolbox/bookbarn_acceptor/set_collection_hour', JSON.stringify(body));
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  // ---- install uploads ----

  /** 本地上传安装工具包（POST /api/toolbox/install/upload）。 */
  static async installToolboxUpload(
    localPath: string,
    fileName: string,
  ): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookUploadFile(
      '/api/toolbox/install/upload', localPath, 'file', fileName, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 本地上传更新指定工具（POST /api/toolbox/:id/update/upload）。 */
  static async updateToolboxUpload(
    toolId: string,
    localPath: string,
    fileName: string,
  ): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookUploadFile(
      `/api/toolbox/${toolId}/update/upload`, localPath, 'file', fileName, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async getAdminMemos(page: number, pageSize: number): Promise<AdminMemoListResponse> {
    const raw = await TalebookCoreService.adminMemoList(page, pageSize);
    return JSON.parse(raw) as AdminMemoListResponse;
  }

  static async resolveAdminMemo(memoId: number, reply: string): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.adminMemoAction(memoId, 'done', reply);
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async deleteAdminMemo(memoId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.adminMemoDelete(memoId);
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async deleteAdminBooks(idlist: number[]): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'idlist': idlist as Object };
    const raw = await TalebookCoreService.talebookPost('/api/admin/books/delete', JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async fillAdminBooks(idlist: number[] | string): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'idlist': idlist as Object };
    const raw = await TalebookCoreService.talebookPost('/api/admin/book/fill', JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async aiFillAdminBooks(idlist: number[]): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'idlist': idlist as Object };
    const raw = await TalebookCoreService.talebookPost('/api/admin/book/aifill', JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async updateAllAdminMeta(): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/admin/book/update_all_meta', '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async updateAdminDynamicCover(idlist: number[] | string): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'idlist': idlist as Object };
    const raw = await TalebookCoreService.talebookPost('/api/admin/book/update_all_dynamic_cover', JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async resetAdminCover(idlist: number[] | string): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'idlist': idlist as Object };
    const raw = await TalebookCoreService.talebookPost('/api/admin/book/reset_cover', JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async updateAdminTitleSort(idlist?: number[]): Promise<ApiMessageResult> {
    const body: Record<string, Object> = idlist === undefined ? {} : { 'idlist': idlist as Object };
    const raw = await TalebookCoreService.talebookPost('/api/admin/book/update_title_sort', JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async epubConvertAdminBooks(idlist?: number[]): Promise<ApiMessageResult> {
    const body: Record<string, Object> = idlist === undefined ? {} : { 'idlist': idlist as Object };
    const raw = await TalebookCoreService.talebookPost('/api/admin/book/epubconvert', JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async saveAdminMetaToFiles(idlist: number[]): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'idlist': idlist as Object };
    const raw = await TalebookCoreService.talebookPost('/api/admin/books/save_meta', JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async clearAdminInvalidItems(): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/admin/clear/invalid/items', '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async getAdminSettings(): Promise<AdminSettingsResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/settings');
    return JSON.parse(raw) as AdminSettingsResponse;
  }

  static async saveAdminSettings(settings: Record<string, Object>): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/admin/settings', JSON.stringify(settings));
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async restartAdminServer(): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/admin/restart', '');
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async testAdminMail(
    smtpServer: string,
    smtpUsername: string,
    smtpPassword: string,
    smtpEncryption: string,
  ): Promise<ApiMessageResult> {
    const form = `smtp_server=${encodeURIComponent(smtpServer)}&smtp_username=${encodeURIComponent(smtpUsername)}` +
      `&smtp_password=${encodeURIComponent(smtpPassword)}&smtp_encryption=${encodeURIComponent(smtpEncryption)}`;
    const raw = await TalebookCoreService.talebookPostForm('/api/admin/testmail', form);
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async testAdminAI(apiUrl: string, apiKey: string, apiModel: string): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'api_url': apiUrl, 'api_key': apiKey, 'api_model': apiModel };
    const raw = await TalebookCoreService.talebookPost('/api/admin/ai/test', JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async getBookNav(): Promise<BookNavResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/book/nav');
    return JSON.parse(raw) as BookNavResponse;
  }

  static async getBooksByMeta(metaType: string, name: string, page: number, limit: number): Promise<BookItem[]> {
    const raw = await TalebookCoreService.talebookGet(
      buildPagePath(`/api/${metaType}/${encodeURIComponent(name)}`, page, limit));
    return parseList(raw);
  }

  /** 上传本地书籍文件到服务器（multipart，字段 ebook）；bookId 非空时表示向已有书籍追加格式 */
  static async uploadBookFile(filePath: string, fileName: string, bookId: number = 0):
    Promise<UploadBookResponse> {
    const raw = await TalebookCoreService.talebookUploadBook(filePath, fileName, bookId > 0 ? `${bookId}` : '');
    return JSON.parse(raw) as UploadBookResponse;
  }

  static async editBook(bookId: number, data: EditBookRequest): Promise<void> {    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/edit`, JSON.stringify(data));
    const resp = JSON.parse(raw) as ApiResult;
    if (resp.err !== undefined && resp.err !== 'ok') {
      throw new Error(resp.err);
    }
  }

  static async searchRefer(bookId: number, opts?: ReferSearchOpts): Promise<ReferSearchResponse> {
    let path = `/api/book/${bookId}/refer`;
    if (opts !== undefined) {
      if (opts.title !== undefined && opts.title.length > 0) {
        path = appendQuery(path, 'title', opts.title);
      }
      if (opts.isbn !== undefined && opts.isbn.length > 0) {
        path = appendQuery(path, 'isbn', opts.isbn);
      }
      if (opts.publisher !== undefined && opts.publisher.length > 0) {
        path = appendQuery(path, 'publisher', opts.publisher);
      }
    }
    const raw = await TalebookCoreService.talebookGet(path);
    const resp = JSON.parse(raw) as ReferListPayload;
    const books = resp.books ?? [];
    const result: ReferBook[] = [];
    for (let i = 0; i < books.length; i++) {
      const item = books[i];
      result.push({
        cover_url: String(item['cover_url'] ?? ''),
        source: String(item['source'] ?? ''),
        website: String(item['website'] ?? ''),
        title: String(item['title'] ?? ''),
        author_sort: String(item['author_sort'] ?? ''),
        authors: (item['authors'] as string[] | undefined) ?? [],
        comments: String(item['comments'] ?? ''),
        isbn: String(item['isbn'] ?? ''),
        isbn13: String(item['isbn13'] ?? ''),
        publisher: String(item['publisher'] ?? ''),
        language: String(item['language'] ?? ''),
        identifiers: item['identifiers'] as Record<string, Object> | undefined,
        tags: (item['tags'] as string[] | undefined) ?? [],
        series: String(item['series'] ?? ''),
        pubdate: String(item['pubdate'] ?? ''),
        pubyear: String(item['pubyear'] ?? ''),
        provider_key: String(item['provider_key'] ?? ''),
        provider_value: String(item['provider_value'] ?? ''),
        rating: Number(item['rating'] ?? 0),
      });
    }
    const out: ReferSearchResponse = {
      books: result,
    };
    if (resp.err !== undefined) {
      out.err = resp.err;
    }
    if (resp.msg !== undefined) {
      out.msg = resp.msg;
    }
    if (resp.cached !== undefined) {
      out.cached = resp.cached;
    }
    return out;
  }

  /** 应用引用元数据（POST /api/book/:id/refer，form：provider_key/provider_value/metadata）。 */
  static async applyRefer(bookId: number, data: ReferBook, onlyMeta: boolean = false,
    onlyCover: boolean = false): Promise<ApiMessageResult> {
    let path = `/api/book/${bookId}/refer`;
    if (onlyMeta) {
      path = appendQuery(path, 'only_meta', 'yes');
    } else if (onlyCover) {
      path = appendQuery(path, 'only_cover', 'yes');
    }
    const form = `provider_key=${encodeURIComponent(data.provider_key ?? '')}` +
      `&provider_value=${encodeURIComponent(data.provider_value ?? '')}` +
      `&metadata=${encodeURIComponent(JSON.stringify(data))}`;
    const raw = await TalebookCoreService.talebookPostForm(path, form);
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 重置引用（用本地信息覆盖，POST /api/book/:id/refer?reset=yes）。 */
  static async resetRefer(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/refer?reset=yes`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async getAudioList(bookId: number): Promise<AudioInfoResponse> {
    const raw = await TalebookCoreService.talebookGet(`/api/audio/${bookId}`);
    return JSON.parse(raw) as AudioInfoResponse;
  }
  /** 有声书列表（GET /api/audiobooks?start=&size=）。 */
  static async getAudiobooks(page: number = 1, size: number = 60): Promise<BookItem[]> {
    const start = (page - 1) * size;
    const path = `/api/audiobooks?start=${start}&size=${size}`;
    const raw = await TalebookCoreService.talebookGet(path);
    return parseList(raw);
  }

  /** 查询有声转换进度（GET /api/audio/:id/conversion）。 */
  static async getAudioConversionStatus(bookId: number): Promise<AudioConversionResponse> {
    const raw = await TalebookCoreService.talebookGet(`/api/audio/${bookId}/conversion`);
    return JSON.parse(raw) as AudioConversionResponse;
  }

  /** 启动有声转换（POST /api/audio/:id/conversion，管理员；默认云健 Neural）。 */
  static async startAudioConversion(
    bookId: number,
    voice: string = 'zh-CN-YunjianNeural',
    language: string = 'zh-CN',
  ): Promise<AudioConversionResponse> {
    const body: Record<string, Object> = { 'voice': voice, 'language': language };
    const raw = await TalebookCoreService.talebookPost(`/api/audio/${bookId}/conversion`,
      JSON.stringify(body));
    return JSON.parse(raw) as AudioConversionResponse;
  }

  /** 取消有声转换（POST /api/audio/:id/cancel，管理员）。 */
  static async cancelAudioConversion(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/audio/${bookId}/cancel`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 删除书籍音频文件（POST /api/audio/:id/delete，管理员）。 */
  static async deleteAudio(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/audio/${bookId}/delete`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 购买有声书（POST /api/audio/:id/purchase）。 */
  static async purchaseAudio(bookId: number): Promise<AudioPurchaseResponse> {
    const raw = await TalebookCoreService.talebookPost(`/api/audio/${bookId}/purchase`, '{}');
    return JSON.parse(raw) as AudioPurchaseResponse;
  }

  /** 生成合集下载链接（GET /api/audios/:id/collection）。 */
  static async createAudioCollectionDownload(bookId: number): Promise<AudioCollectionResponse> {
    const raw = await TalebookCoreService.talebookGet(`/api/audios/${bookId}/collection`);
    return JSON.parse(raw) as AudioCollectionResponse;
  }

  /** 单章音频相对路径（GET /api/audio/:id/:filename，二进制流）。 */
  static audioFilePath(bookId: number, filename: string): string {
    return `/api/audio/${bookId}/${encodeURIComponent(filename)}`;
  }

  /** 合集 zip 相对路径（GET /api/audios/:id/collection/download?key=）。 */
  static audioCollectionDownloadPath(bookId: number, key: string): string {
    return `/api/audios/${bookId}/collection/download?key=${encodeURIComponent(key)}`;
  }

  /** 设置阅读状态：0 未读 / 1 在读 / 2 已读完（POST /api/book/:id/readstate）。 */
  static async setReadState(bookId: number, readState: number): Promise<ApiMessageResult> {
    const payload: ReadStatePayload = { read_state: readState };
    const raw = await TalebookCoreService.talebookPost(
      `/api/book/${bookId}/readstate`, JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 在读/读完/收藏/推荐人数（游客可访问）。 */
  static async getSocialStats(bookId: number): Promise<BookSocialStats | null> {
    const raw = await TalebookCoreService.talebookGet(`/api/book/${bookId}/social-stats`);
    const resp = JSON.parse(raw) as ApiResult;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return null;
    }
    return parseSocialStats(resp as Record<string, Object>);
  }

  /** 书籍书评列表（最近最多 50 条，当前用户置顶）。 */
  static async getBookReviews(bookId: number): Promise<BookReviewItem[]> {
    const raw = await TalebookCoreService.talebookGet(`/api/book/${bookId}/reviews`);
    const resp = JSON.parse(raw) as ReviewsPayload;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return [];
    }
    return parseBookReviews(resp.reviews);
  }

  /** 取当前用户对该书的评价（未评价时返回 null）。 */
  static async getOwnReview(bookId: number): Promise<BookReviewItem | null> {
    const raw = await TalebookCoreService.talebookGet(`/api/book/${bookId}/review`);
    const resp = JSON.parse(raw) as OwnReviewPayload;
    if (resp.err !== undefined && resp.err !== 'ok' || resp.review === undefined || resp.review === null) {
      return null;
    }
    return parseBookReview(resp.review as Record<string, Object>);
  }

  /** 提交/更新当前用户评价（rating 0-10）。 */
  static async submitReview(bookId: number, rating: number, comment: string):
    Promise<ApiMessageResult> {
    const payload: ReviewPayload = { rating: rating, comment: comment };
    const raw = await TalebookCoreService.talebookPost(
      `/api/book/${bookId}/review`, JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 删除当前用户评价。 */
  static async deleteReview(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookDelete(`/api/book/${bookId}/review`);
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 当前用户阅读统计（/api/reading/stats，需登录）。 */
  static async getReadingStats(): Promise<ReadingStatsSummary | null> {
    const raw = await TalebookCoreService.talebookGet('/api/reading/stats');
    const resp = JSON.parse(raw) as ReadingStatsPayload;
    if (resp.err !== undefined && resp.err !== 'ok' || resp.stats === undefined) {
      return null;
    }
    return parseReadingStatsSummary(resp.stats as Record<string, Object>);
  }

  /** 当前用户在读书籍（/api/reading/stats 内嵌列表）。 */
  static async getCurrentReadingBooks(): Promise<HomeBook[]> {
    const raw = await TalebookCoreService.talebookGet('/api/reading/stats');
    const resp = JSON.parse(raw) as ReadingStatsPayload;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return [];
    }
    return parseHomeBooks(resp.current_reading_books);
  }

  /** 首页阅读时长横幅（/api/user/reading_stats，未启用/未登录返回 null）。 */
  static async getReadingDashboard(): Promise<ReadingDashboard | null> {
    const raw = await TalebookCoreService.talebookGet('/api/user/reading_stats');
    const resp = JSON.parse(raw) as Record<string, Object>;
    if (resp['err'] !== 'ok' || resp['enabled'] !== true) {
      return null;
    }
    return parseReadingDashboard(resp);
  }

  /** 首页随机推荐 + 社交推荐 + 新书推荐（/api/index）。 */
  static async getIndexHome(): Promise<IndexHomeData> {
    const raw = await TalebookCoreService.talebookGet('/api/index');
    const resp = JSON.parse(raw) as Record<string, Object>;
    return {
      randomBooks: parseHomeBooks(resp['random_books']),
      socialBooks: parseHomeBooks(resp['social_recommend_books']),
      newBooks: parseHomeBooks(resp['new_books']),
    };
  }

  /** 想读清单（/api/wants，需登录，start/size 分页）。 */
  static async getWantsBooks(page: number, size: number): Promise<BookItem[]> {
    return fetchStateList('/api/wants', page, size);
  }

  /** 已读完书籍（/api/read-done，需登录）。 */
  static async getReadDoneBooks(page: number, size: number): Promise<BookItem[]> {
    return fetchStateList('/api/read-done', page, size);
  }

  /** 私有书籍（/api/soledbooks，需登录）。 */
  static async getSoledBooks(page: number, size: number): Promise<BookItem[]> {
    return fetchStateList('/api/soledbooks', page, size);
  }

  /** 保存个人设置（POST /api/user/update）。 */
  static async updateUserSettings(payload: UserUpdatePayload): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/user/update',
      JSON.stringify(payload as Record<string, Object>));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 当前用户留言列表（GET /api/user/memo）。 */
  static async getUserMemos(page: number, pageSize: number): Promise<UserMemoItem[]> {
    const raw = await TalebookCoreService.talebookGet(
      `/api/user/memo?page=${page}&page_size=${pageSize}`);
    const resp = JSON.parse(raw) as MemoDataPayload;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return [];
    }
    const data = (resp.data as Record<string, Object> | undefined) ?? {};
    return parseUserMemos(data['items']);
  }

  /** 新建留言（memo_type：0 建议 / 1 求书 / 2 求助）。 */
  static async createMemo(memo: string, memoType: number): Promise<ApiMessageResult> {
    const payload: MemoCreatePayload = { memo: memo, memo_type: memoType };
    const raw = await TalebookCoreService.talebookPost('/api/user/memo', JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 求书期望列表（GET /api/user/expected）。 */
  static async getExpectedItems(): Promise<ExpectedItemModel[]> {
    const raw = await TalebookCoreService.talebookGet('/api/user/expected');
    const resp = JSON.parse(raw) as MemoDataPayload;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return [];
    }
    const data = (resp.data as Record<string, Object> | undefined) ?? {};
    return parseExpectedItems(data['items']);
  }

  /** 新建求书期望。 */
  static async createExpectedItem(title: string, author: string, publisher: string):
    Promise<ApiMessageResult> {
    const payload: ExpectedCreatePayload = {
      title: title,
      author: author,
      publisher: publisher,
    };
    const raw = await TalebookCoreService.talebookPost('/api/user/expected', JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 删除求书期望。 */
  static async deleteExpectedItem(id: number): Promise<ApiMessageResult> {
    const payload: ExpectedDeletePayload = { id: id };
    const raw = await TalebookCoreService.talebookDeleteWithBody('/api/user/expected',
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 上传头像（POST /api/user/avatar，multipart 字段 avatar）。 */
  static async uploadAvatar(localPath: string, fileName: string): Promise<AvatarUploadResponse> {
    const raw = await TalebookCoreService.talebookUploadFile('/api/user/avatar', localPath,
      'avatar', fileName);
    return JSON.parse(raw) as AvatarUploadResponse;
  }

  /** 服务端版本更新说明（/api/admin/release/notes，无更新时 msg 为空）。 */
  static async getReleaseNotes(): Promise<string> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/release/notes');
    const resp = JSON.parse(raw) as ApiMessageResult;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return '';
    }
    return resp.msg !== undefined ? resp.msg : '';
  }

  /** 当前用户阅读设备列表（GET /api/user/devices）。 */
  static async getUserDevices(): Promise<ReadingDevice[]> {
    const raw = await TalebookCoreService.talebookGet('/api/user/devices');
    const resp = JSON.parse(raw) as DevicesPayload;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return [];
    }
    return parseReadingDevices(resp.devices);
  }

  /** 推送书籍到设备（POST /api/book/:id/send_to_device）。 */
  static async sendToDevice(bookId: number, deviceType: string, deviceUrl: string,
    mailbox: string, ftpUsername: string, ftpPassword: string, ftpPath: string):
    Promise<ApiMessageResult> {
    const payload: SendDevicePayload = {
      device_type: deviceType,
      device_url: deviceUrl,
      mailbox: mailbox,
      ftp_username: ftpUsername,
      ftp_password: ftpPassword,
      ftp_path: ftpPath,
    };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/send_to_device`,
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 邮件分享书籍（POST /api/book/:id/mailto）。 */
  static async sendToMail(bookId: number, email: string, format: string):
    Promise<ApiMessageResult> {
    const payload: SendMailPayload = { email: email, format: format };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/mailto`,
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** AI 补全单本元数据（POST /api/book/:id/aifill）。 */
  static async aiFillBook(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/aifill`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 设置/取消想读（POST /api/book/:id/wants）。 */
  static async setWants(bookId: number, wants: boolean): Promise<ApiMessageResult> {
    const payload: WantsPayload = { wants: wants };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/wants`,
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 每格式阅读统计（GET /api/book/:id/reading_stats）。 */
  static async getFormatReadingStats(bookId: number): Promise<FormatReadingStat[]> {
    const raw = await TalebookCoreService.talebookGet(`/api/book/${bookId}/reading_stats`);
    const resp = JSON.parse(raw) as FormatStatsPayload;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return [];
    }
    return parseFormatStats(resp.stats);
  }

  /** 同类推荐图书（GET /api/book/:id/suggestion）。 */
  static async getBookSuggestions(bookId: number): Promise<BookItem[]> {
    const raw = await TalebookCoreService.talebookGet(`/api/book/${bookId}/suggestion`);
    return parseList(raw);
  }

  /** 同名图书（GET /api/search?title=&exclude=）。 */
  static async searchSameTitleBooks(title: string, excludeId: number): Promise<BookItem[]> {
    const path = `/api/search?title=${encodeURIComponent(title)}&exclude=${excludeId}`;
    const raw = await TalebookCoreService.talebookGet(path);
    return parseList(raw);
  }

  /** 服务端在线阅读历史（GET /api/user/history，最多 12 本）。 */
  static async getOnlineReadingHistory(): Promise<BookItem[]> {
    const raw = await TalebookCoreService.talebookGet('/api/user/history');
    return parseList(raw);
  }

  /** 清空服务端在线阅读历史（POST /api/user/history/clear）。 */
  static async clearOnlineReadingHistory(): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/user/history/clear', '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 转换书籍格式（POST /api/book/:id/convert，EPUB/Kindle 互转）。 */
  static async convertBook(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/convert`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 转换为 PDF（POST /api/book/:id/topdf）。 */
  static async convertBookToPdf(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/topdf`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 将指定格式分离为新书籍（POST /api/book/:id/separate）。 */
  static async separateFormat(bookId: number, format: string): Promise<ApiMessageResult> {
    const payload: FormatPayload = { format: format };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/separate`,
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 删除书籍的指定格式（POST /api/book/:id/delete_format）。 */
  static async deleteFormat(bookId: number, format: string): Promise<ApiMessageResult> {
    const payload: FormatPayload = { format: format };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/delete_format`,
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }
  /** 删除整本书（POST /api/book/:id/delete）。需编辑/删除权限或书籍所有者。 */
  static async deleteBook(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/delete`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 上传封面（POST /api/book/:id/cover，multipart 字段 cover_data）。 */
  static async uploadCover(bookId: number, localPath: string, fileName: string):
    Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookUploadFile(`/api/book/${bookId}/cover`,
      localPath, 'cover_data', fileName);
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 生成默认封面（POST /api/book/:id/cover，无文件时服务端自动生成）。 */
  static async generateDefaultCover(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/cover`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 裁剪封面白边（POST /api/book/crop_cover）。 */
  static async cropCover(bookId: number): Promise<CropCoverResult> {
    const payload: CropCoverPayload = { id: bookId };
    const raw = await TalebookCoreService.talebookPost('/api/book/crop_cover',
      JSON.stringify(payload));
    return JSON.parse(raw) as CropCoverResult;
  }

  /** 批量裁剪封面白边（POST /api/book/crop_cover）。 */
  static async cropCovers(bookIds: number[]): Promise<CropCoverResult> {
    const payload: CropCoverIdsPayload = { ids: bookIds };
    const raw = await TalebookCoreService.talebookPost('/api/book/crop_cover',
      JSON.stringify(payload));
    return JSON.parse(raw) as CropCoverResult;
  }

  /** 分类列表（GET /api/categories）。 */
  static async getCategories(): Promise<MetaNameCount[]> {
    const raw = await TalebookCoreService.talebookGet('/api/categories');
    const resp = JSON.parse(raw) as CategoriesPayload;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return [];
    }
    return parseNameCounts(resp.categories);
  }

  /** 作者联想（GET /api/authors/search?q=）。 */
  static async searchAuthors(query: string): Promise<MetaNameCount[]> {
    const path = appendQuery('/api/authors/search', 'q', query);
    const raw = await TalebookCoreService.talebookGet(path);
    const resp = JSON.parse(raw) as AuthorsPayload;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return [];
    }
    return parseNameCounts(resp.authors);
  }
  /** 标签联想（GET /api/tags/search?q=&limit=）。 */
  static async searchTags(query: string, limit: number = 20): Promise<MetaNameCount[]> {
    let path = appendQuery('/api/tags/search', 'q', query);
    path = appendQuery(path, 'limit', limit);
    const raw = await TalebookCoreService.talebookGet(path);
    const resp = JSON.parse(raw) as TagsPayload;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return [];
    }
    return parseNameCounts(resp.tags);
  }

  /**
   * 元数据列表（GET /api/{meta}?show=all）。
   * meta: author|publisher|tag|rating|series|language
   */
  static async getMetaList(metaType: string, showAll: boolean = false): Promise<MetaListResponse> {
    let path = `/api/${metaType}`;
    if (showAll) {
      path = `${path}?show=all`;
    }
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as MetaListResponse;
  }

  /** 作者扩展信息（GET /api/author/info?name=）：bio/avatar/region 等。 */
  static async getAuthorInfo(name: string): Promise<AuthorInfoResponse> {
    const path = appendQuery('/api/author/info', 'name', name);
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as AuthorInfoResponse;
  }

  /** 保存作者简介（POST /api/author/bio，管理员）。 */
  static async updateAuthorBio(name: string, bio: string): Promise<AuthorInfoResponse> {
    const body: Record<string, Object> = { 'name': name, 'bio': bio };
    const raw = await TalebookCoreService.talebookPost('/api/author/bio', JSON.stringify(body));
    return JSON.parse(raw) as AuthorInfoResponse;
  }

  /** 更新作者名下书籍元数据（POST /api/author/:name/update；服务端可能 302 重定向）。 */
  static async updateAuthorBooks(authorName: string): Promise<ApiMessageResult> {
    const path = `/api/author/${encodeURIComponent(authorName)}/update`;
    const raw = await TalebookCoreService.talebookPost(path, '{}');
    return parseJsonOrOk(raw);
  }

  /** 更新出版社名下书籍元数据（POST /api/publisher/:name/update；服务端可能 302 重定向）。 */
  static async updatePublisherBooks(publisherName: string): Promise<ApiMessageResult> {
    const path = `/api/publisher/${encodeURIComponent(publisherName)}/update`;
    const raw = await TalebookCoreService.talebookPost(path, '{}');
    return parseJsonOrOk(raw);
  }

  /** 上传作者头像（POST /api/author_avatar，multipart 字段 avatar_data；author 走 query）。 */
  static async uploadAuthorAvatar(authorName: string, localPath: string, fileName: string):
    Promise<ApiMessageResult> {
    const path = `/api/author_avatar?author=${encodeURIComponent(authorName)}`;
    const raw = await TalebookCoreService.talebookUploadFile(path, localPath, 'avatar_data', fileName);
    return parseJsonOrOk(raw);
  }


  /** 置顶作者/标签（POST /api/user/pin，itemType 0=作者 1=标签）。 */
  static async pinItem(itemType: number, value: string): Promise<ApiMessageResult> {
    const payload: PinPayload = { item_type: itemType, value: value };
    const raw = await TalebookCoreService.talebookPost('/api/user/pin', JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 取消置顶（POST /api/user/unpin）。 */
  static async unpinItem(itemType: number, value: string): Promise<ApiMessageResult> {
    const payload: PinPayload = { item_type: itemType, value: value };
    const raw = await TalebookCoreService.talebookPost('/api/user/unpin', JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 批量移除阅读状态（POST /api/books/batch-remove-state，action: favorite/wants/reading/read-done）。 */
  static async batchRemoveState(bookIds: number[], action: string): Promise<ApiMessageResult> {
    const payload: BatchRemoveStatePayload = { book_ids: bookIds, action: action };
    const raw = await TalebookCoreService.talebookPost('/api/books/batch-remove-state',
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 设置书籍分类（POST /api/book/:id/category）。 */
  static async setBookCategory(bookId: number, category: string): Promise<ApiMessageResult> {
    const payload: CategoryPayload = { category: category };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/category`,
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 查询书籍文件路径（GET /api/book/:id/filepath?format=epub|pdf）。 */
  static async getBookFilePath(bookId: number, format: string): Promise<BookFilePathResponse> {
    const path = appendQuery(`/api/book/${bookId}/filepath`, 'format', format);
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as BookFilePathResponse;
  }

  /** 读取 TXT 内容片段（GET /api/read/txt/:id?start=&end=）。 */
  static async readTxtContent(bookId: number, start: number = 0, end: number = -1): Promise<TxtReadResponse> {
    let path = `/api/read/txt/${bookId}`;
    path = appendQuery(path, 'start', start);
    path = appendQuery(path, 'end', end);
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as TxtReadResponse;
  }

  /** TXT 书籍解析（GET /api/book/txt/parser?id=&test=）。 */
  static async parseTxtBook(bookId: number, testReady: boolean = true): Promise<TxtParserResponse> {
    let path = '/api/book/txt/parser';
    path = appendQuery(path, 'id', bookId);
    path = appendQuery(path, 'test', testReady ? '1' : '0');
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as TxtParserResponse;
  }

  /** 按标签名批量刷新书籍标签（POST /api/book/update_tags?tag=，body 为空）。 */
  static async updateBooksTagsByTag(tag: string): Promise<BatchTagUpdateResponse> {
    const path = appendQuery('/api/book/update_tags', 'tag', tag);
    const raw = await TalebookCoreService.talebookPost(path, '{}');
    return JSON.parse(raw) as BatchTagUpdateResponse;
  }

  /** 按作者/标签/系列批量设置分类（POST /api/book/category；与单本 setBookCategory 不同）。 */
  static async batchSetBookCategory(category: string, opts?: BatchCategoryOpts): Promise<BatchCategoryResponse> {
    const options: BatchCategoryOpts = opts !== undefined ? opts : {};
    const body: Record<string, Object> = { 'category': category };
    if (options.author !== undefined && options.author.length > 0) {
      body['author'] = options.author;
    }
    if (options.tag !== undefined && options.tag.length > 0) {
      body['tag'] = options.tag;
    }
    if (options.series !== undefined && options.series.length > 0) {
      body['series'] = options.series;
    }
    const raw = await TalebookCoreService.talebookPost('/api/book/category', JSON.stringify(body));
    return JSON.parse(raw) as BatchCategoryResponse;
  }

  /** 清理稀有标签（POST /api/clear_rare_tags）。 */
  static async clearRareTags(): Promise<ClearRareTagsResponse> {
    const raw = await TalebookCoreService.talebookPost('/api/clear_rare_tags', '{}');
    return JSON.parse(raw) as ClearRareTagsResponse;
  }

  /** 书籍下载路径（GET /api/book/:id.:format；二进制，供下载器/WebView）。 */
  static bookDownloadPath(bookId: number, format: string): string {
    return `/api/book/${bookId}.${format.toLowerCase()}`;
  }

  /** Web 阅读器跳转路径（GET /api/book/:id/read?format=）。 */
  static bookReadPath(bookId: number, format: string = ''): string {
    let path = `/api/book/${bookId}/read`;
    if (format.length > 0) {
      path = appendQuery(path, 'format', format);
    }
    return path;
  }


  /** 设置书籍馆藏位置（POST /api/book/:id/location）。 */
  static async setBookLocation(bookId: number, location: string): Promise<ApiMessageResult> {
    const payload: LocationPayload = { location: location };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/location`,
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 切换私藏状态（POST /api/book/:id/setsole）。 */
  static async setSole(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/setsole`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 通过 BookBarn 更新标签（POST /api/book/:id/tags）。 */
  static async updateBookTags(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/tags`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 将元数据保存到书籍文件（POST /api/book/:id/savemeta?fmt=）。 */
  static async saveBookMeta(bookId: number, format: string): Promise<ApiMessageResult> {
    let path = `/api/book/${bookId}/savemeta`;
    if (format.length > 0) {
      path = appendQuery(path, 'fmt', format);
    }
    const raw = await TalebookCoreService.talebookPost(path, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 为封面加盖图章（POST /api/book/:id/addstamp）。 */
  static async addStamp(bookId: number, position: string): Promise<ApiMessageResult> {
    const payload: StampPayload = { position: position };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/addstamp`,
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 今日下载配额（GET /api/book/download_quota）。 */
  static async getDownloadQuota(): Promise<DownloadQuotaResult> {
    const raw = await TalebookCoreService.talebookGet('/api/book/download_quota');
    return JSON.parse(raw) as DownloadQuotaResult;
  }

  /** 电子书/实体书类型互转（POST /api/book/exchange_type，管理员）。 */
  static async exchangeBookType(idlist: number[]): Promise<ApiMessageResult> {
    const payload: ExchangeTypePayload = { idlist: idlist };
    const raw = await TalebookCoreService.talebookPost('/api/book/exchange_type',
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 按 ISBN 添加实体书（POST /api/book/add）。 */
  static async addBookByIsbn(isbn: string): Promise<AddIsbnResult> {
    const payload: AddIsbnPayload = { isbn: isbn };
    const raw = await TalebookCoreService.talebookPost('/api/book/add', JSON.stringify(payload));
    return JSON.parse(raw) as AddIsbnResult;
  }

  /** 分块上传书籍（POST /api/book/upload/chunk，字段 chunk + 表单参数）。 */
  static async uploadBookChunk(chunkPath: string, fileName: string, chunkIndex: number,
    totalChunks: number, fileHash: string): Promise<UploadBookResponse> {
    const fields: Record<string, Object> = {
      'filename': fileName,
      'chunk_index': `${chunkIndex}`,
      'total_chunks': `${totalChunks}`,
      'file_hash': fileHash,
    };
    const raw = await TalebookCoreService.talebookUploadFile('/api/book/upload/chunk', chunkPath,
      'chunk', fileName, JSON.stringify(fields));
    return JSON.parse(raw) as UploadBookResponse;
  }
  /** 批量上传任务状态（GET /api/book/upload/batch/status?import_id=）。 */
  static async getUploadBatchStatus(importId: number, num: number = 200):
    Promise<UploadBatchStatusResponse> {
    const path = `/api/book/upload/batch/status?import_id=${importId}&num=${num}`;
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as UploadBatchStatusResponse;
  }

  /** 取消批量上传/导入（POST /api/book/upload/batch/cancel，JSON: import_id）。 */
  static async cancelUploadBatch(importId: number): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'import_id': importId };
    const raw = await TalebookCoreService.talebookPost('/api/book/upload/batch/cancel',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }
  /**
   * 批量上传书籍（POST /api/book/upload/batch，multipart 字段 ebooks + relative_paths）。
   * files: 本地已暂存的文件；relativePath 可选，用于目录结构导入。
   */
  static async uploadBookBatch(files: BatchUploadFile[]): Promise<UploadBatchStartResponse> {
    const payload: Array<Record<string, Object>> = [];
    for (let i = 0; i < files.length; i++) {
      const f = files[i];
      const item: Record<string, Object> = {
        'path': f.localPath,
        'name': f.name,
      };
      if (f.relativePath !== undefined && f.relativePath.length > 0) {
        item['relative_path'] = f.relativePath;
      }
      payload.push(item);
    }
    const raw = await TalebookCoreService.talebookUploadBookBatch(JSON.stringify(payload));
    return JSON.parse(raw) as UploadBatchStartResponse;
  }
  /** 拉取同步增量（GET /api/sync?since=&type=&book=&own=）。type: books|notes|configs。 */
  static async syncPull(since: number, type?: string, bookHash?: string, own: number = 1):
    Promise<SyncPullResponse> {
    let path = `/api/sync?since=${since}&own=${own}`;
    if (type !== undefined && type.length > 0) {
      path = `${path}&type=${encodeURIComponent(type)}`;
    }
    if (bookHash !== undefined && bookHash.length > 0) {
      path = `${path}&book=${encodeURIComponent(bookHash)}`;
    }
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as SyncPullResponse;
  }

  /** 推送同步记录（POST /api/sync，JSON body: books/notes/configs）。 */
  static async syncPush(payload: SyncPushPayload): Promise<Record<string, Object>> {
    const raw = await TalebookCoreService.talebookPost('/api/sync',
      JSON.stringify(payload as Record<string, Object>));
    return JSON.parse(raw) as Record<string, Object>;
  }

  /** 第三方批注导入预览/提交（POST /api/sync/import）。默认 dryRun=true。 */
  static async syncImport(request: SyncImportRequest): Promise<SyncImportResponse> {
    const body: Record<string, Object> = {
      'book_id': request.bookId,
      'anchors': request.anchors as Object,
      'on_ambiguous': request.onAmbiguous ?? 'error',
      'dry_run': request.dryRun ?? true,
      'force': request.force ?? false,
    };
    const raw = await TalebookCoreService.talebookPost('/api/sync/import', JSON.stringify(body));
    return JSON.parse(raw) as SyncImportResponse;
  }

  /** 清除本用户该书经 sync/import 写入的批注（POST /api/sync/import/clear）。 */
  static async syncImportClear(bookId: number): Promise<SyncImportClearResponse> {
    const body: Record<string, Object> = { 'book_id': bookId };
    const raw = await TalebookCoreService.talebookPost('/api/sync/import/clear', JSON.stringify(body));
    return JSON.parse(raw) as SyncImportClearResponse;
  }
}

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

interface MemoCreatePayload {
  memo: string;
  memo_type: number;
}

interface ExpectedCreatePayload {
  title: string;
  author: string;
  publisher: string;
}

interface ExpectedDeletePayload {
  id: number;
}

interface MemoDataPayload extends ApiResult {
  data?: Object;
}

interface DevicesPayload extends ApiResult {
  devices?: Object;
}

interface FormatStatsPayload extends ApiResult {
  stats?: Object;
}

interface SendDevicePayload {
  device_type: string;
  device_url: string;
  mailbox: string;
  ftp_username: string;
  ftp_password: string;
  ftp_path: string;
}

interface SendMailPayload {
  email: string;
  format: string;
}

interface WantsPayload {
  wants: boolean;
}

interface FormatPayload {
  format: string;
}

interface CropCoverPayload {
  id: number;
}

interface CropCoverIdsPayload {
  ids: number[];
}

interface CropCoverResult extends ApiMessageResult {
  data?: Record<string, Object>;
}

interface BatchRemoveStatePayload {
  book_ids: number[];
  action: string;
}

interface PinPayload {
  item_type: number;
  value: string;
}

interface CategoryPayload {
  category: string;
}

interface LocationPayload {
  location: string;
}

interface CategoriesPayload extends ApiResult {
  categories?: Array<Record<string, Object>>;
}

interface AuthorsPayload extends ApiResult {
  authors?: Array<Record<string, Object>>;
}
interface TagsPayload extends ApiResult {
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

interface ReferListPayload extends ApiResult {
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

interface StampPayload {
  position: string;
}

interface DownloadQuotaResult extends ApiResult {
  allowed?: boolean;
  used?: number;
  quota?: number;
}

interface ExchangeTypePayload {
  idlist: number[];
}

interface AddIsbnPayload {
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

function parseNameCounts(items: Array<Record<string, Object>> | undefined): MetaNameCount[] {
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

async function fetchStateList(path: string, page: number, size: number): Promise<BookItem[]> {
  const start = (page - 1) * size;
  const raw = await TalebookCoreService.talebookGet(`${path}?start=${start}&size=${size}`);
  return parseList(raw);
}

interface ReadStatePayload {
  read_state: number;
}

interface ReviewPayload {
  rating: number;
  comment: string;
}

interface ReviewsPayload extends ApiResult {
  total?: number;
  reviews?: Object;
}

interface OwnReviewPayload extends ApiResult {
  review?: Object;
}

interface ReadingStatsPayload extends ApiResult {
  stats?: Object;
  current_reading_books?: Object;
  month_read_done_books?: Object;
}

export interface IndexHomeData {
  randomBooks: HomeBook[];
  socialBooks: HomeBook[];
  newBooks: HomeBook[];
}
