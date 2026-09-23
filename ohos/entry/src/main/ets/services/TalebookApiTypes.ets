export interface BookListPayload {
  books?: Array<Record<string, Object>>;
  total?: number;
}

export interface IndexPayload {
  random?: Array<Record<string, Object>>;
  recent?: Array<Record<string, Object>>;
}

export interface BookDetailPayload {
  err?: string;
  book?: Record<string, Object>;
}

export interface ApiResult {
  err?: string;
}

export interface ApiMessageResult extends ApiResult {
  msg?: string;
}
export interface AccessStatusResponse extends ApiMessageResult {
  version?: string;
  welcome?: string;
}

export interface WhoAmIResponse extends ApiResult {
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

export interface AdminSettingsResponse extends ApiMessageResult {
  settings?: Record<string, Object>;
  sns?: Array<Record<string, Object>>;
  site_url?: string;
}

export interface AdminBookListResponse extends ApiMessageResult {
  items?: Array<Record<string, Object>>;
  total?: number;
}

export interface AdminUserPage {
  items?: Array<Record<string, Object>>;
  total?: number;
}

export interface AdminUsersResponse extends ApiMessageResult {
  users?: AdminUserPage;
  settings?: Record<string, Object>;
}

export interface TrashBooksResponse extends ApiMessageResult {
  books?: Array<Record<string, Object>>;
}

export interface TrashSizeResponse extends ApiMessageResult {
  sizes?: Record<string, Object>;
}

export interface AdminReviewsResponse extends ApiMessageResult {
  total?: number;
  page?: number;
  page_size?: number;
  reviews?: Array<Record<string, Object>>;
}

export interface AdminImportListResponse extends ApiMessageResult {
  items?: Array<Record<string, Object>>;
  total?: number;
  scanning?: boolean;
  importing?: boolean;
  summary?: Record<string, Object>;
  scan_dir?: string;
}

export interface AdminSyslogResponse extends ApiMessageResult {
  lines?: Array<string>;
  href?: string;
}

export interface AdminResourcesResponse extends ApiMessageResult {
  resources?: Array<Record<string, Object>>;
}

/** 书库统计数据 */
export interface LibraryStatsData {
  total_books?: number;
  ebook_count?: number;
  physical_count?: number;
  month_ebook_count?: number;
  month_physical_count?: number;
  current_year?: number;
  current_month?: number;
}

/** GET /api/library/stats */
export interface LibraryStatsResponse extends ApiMessageResult {
  stats?: LibraryStatsData;
}

/** GET /api/sysinfo */
export interface SysInfoResponse extends ApiMessageResult {
  data?: Record<string, Object>;
}

/** GET /api/admin/tasks/running */
export interface AdminRunningTasksResponse extends ApiMessageResult {
  tasks?: Array<Record<string, Object>>;
  messages?: Array<Record<string, Object>>;
}

/** POST /api/admin/batch_add/run */
export interface BatchAddRunResponse extends ApiMessageResult {
  total?: number;
}

/** GET /api/admin/batch_add/status */
export interface BatchAddStatusResponse extends ApiMessageResult {
  status?: Record<string, Object>;
  summary?: Record<string, Object>;
  batch_adding?: boolean;
}

/** GET /api/admin/import/status */
export interface ImportStatusResponse extends ApiMessageResult {
  task?: Record<string, Object>;
  status?: Record<string, Object>;
  summary?: Record<string, Object>;
  scanning?: boolean;
  ignored_errors?: Object;
  importing?: boolean;
}

/** GET /api/admin/audio_import/status */
export interface AudioImportStatusResponse extends ApiMessageResult {
  status?: Record<string, Object>;
  summary?: Record<string, Object>;
  audio_importing?: boolean;
}

/** POST /api/admin/barcode */
export interface BarcodeResponse extends ApiMessageResult {
  isbn?: string;
}

/** GET /api/admin/install */
export interface InstallStatusResponse extends ApiMessageResult {
  installed?: boolean;
}

/** POST /api/admin/install 表单/查询参数 */
export interface InstallRequest {
  username: string;
  password: string;
  email: string;
  title: string;
  language?: string;
  invite?: string;
  code?: string;
}

/** GET /api/admin/stamp */
export interface StampStatusResponse extends ApiMessageResult {
  exists?: boolean;
}

/** GET /api/admin/thanks/notes */
export interface ThanksNotesResponse extends ApiMessageResult {
  names?: string[];
}

/** GET /api/admin/token */
export interface AdminTokenResponse extends ApiMessageResult {
  token?: string;
}

/** POST /api/admin/bookbarn/token/apply */
export interface BookbarnAdminTokenResponse extends ApiMessageResult {
  token?: string;
}


export interface UploadBookResponse extends ApiMessageResult {
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

export interface AdminToolListResponse extends ApiMessageResult {
  tools?: Array<Record<string, Object>>;
}
export interface ToolboxStoreIndexResponse extends ApiMessageResult {
  enabled?: boolean;
  tools?: Array<Record<string, Object>>;
}

export interface ToolboxDataResponse extends ApiMessageResult {
  data?: Record<string, Object>;
}

/** VIP 配额与到期（GET /api/user/vip）。 */
export interface VipInfoResponse extends ApiResult {
  vipquota?: number;
  vip_expire?: string;
}

/** 书籍文件路径（GET /api/book/:id/filepath?format=）。 */
export interface BookFilePathResponse extends ApiMessageResult {
  data?: Record<string, Object>;
}

/** TXT 在线阅读内容（GET /api/read/txt/:id）。 */
export interface TxtReadResponse extends ApiMessageResult {
  content?: string;
}

/** TXT 解析结果（GET /api/book/txt/parser）。 */
export interface TxtParserResponse extends ApiMessageResult {
  data?: Record<string, Object>;
}

/** 按标签批量更新书籍标签（POST /api/book/update_tags?tag=）。 */
export interface BatchTagUpdateResponse extends ApiMessageResult {
  count?: number;
  total?: number;
}

/** 批量设置分类（POST /api/book/category）。 */
export interface BatchCategoryResponse extends ApiMessageResult {
  count?: number;
}

export interface BatchCategoryOpts {
  author?: string;
  tag?: string;
  series?: string;
}

/** 清理稀有标签（POST /api/clear_rare_tags）。 */
export interface ClearRareTagsResponse extends ApiMessageResult {
  book_count?: number;
  tag_count?: number;
}

export interface ToolboxTaskProgressResponse extends ApiMessageResult {
  data?: Record<string, Object>;
}

/** MiMo TTS 转换请求（POST /api/toolbox/mimo_tts/convert）。 */
export interface MimoTtsConvertRequest {
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
export interface MimoTtsTestRequest {
  apiKey: string;
  voiceDesc?: string;
  apiUrl?: string;
  modelName?: string;
  apiType?: string;
  voiceName?: string;
  authType?: string;
  cloneVoice?: string;
}

export interface MimoTtsConfigResponse extends ApiMessageResult {
  config?: Record<string, Object> | null;
}

export interface MimoTtsClonesResponse extends ApiMessageResult {
  clones?: Array<Record<string, Object>>;
}

export interface MimoTtsPromptsResponse extends ApiMessageResult {
  prompts?: Array<Record<string, Object>>;
}

/** EPUB 美化运行可选参数（POST /api/toolbox/epub_beautify/run）。 */
export interface EpubBeautifyRunOptions {
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

export interface BookBarnApplyTokenResponse extends ApiMessageResult {
  token?: string;
}


export interface AdminMemoListResponse extends ApiMessageResult {
  data?: Record<string, Object>;
}

export interface PageQuery {
  page: number;
  limit: number;
}

export interface SearchQuery {
  name: string;
  page: number;
  limit: number;
}

export interface LimitQuery {
  limit: number;
}

export interface MetaQuery {
  page: number;
  limit: number;
}

export interface ReferQuery {
  title: string;
}

