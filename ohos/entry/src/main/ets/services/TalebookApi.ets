/**
 * Talebook API 门面（800 行门禁拆分）：浏览/搜索/登录鉴权/上传同步核心在本类；
 * 管理端见 TalebookApiAdmin.ets，工具箱见 TalebookApiToolbox.ets，
 * 书籍详情与用户域见 TalebookApiBooks.ets，共享 helper/payload 见 TalebookApiUtil.ets。
 * 类型 re-export 面保持不变（外部页面 import 路径不受拆分影响）。
 */
import { StorageKeys } from '../common/Constants';
import { UserInfoResponse } from '../common/Models';
import { BookDetail, BookItem, parseBookDetail, parseBookItem } from './BookModels';
import { TalebookCoreService } from './TalebookCoreService';
import { ServerRegistry } from './ServerProfile';
import { AccessStatusResponse, ApiMessageResult, BatchUploadFile, BookDetailPayload, IndexPayload, SyncImportClearResponse, SyncImportRequest, SyncImportResponse, SyncPullResponse, SyncPushPayload, UploadBatchStartResponse, UploadBatchStatusResponse, UploadBookResponse, VipInfoResponse, WhoAmIResponse } from './TalebookApiTypes';
import { parseJsonOrOk, appendQuery, buildPagePath, parseList, LocationPayload, StampPayload, DownloadQuotaResult, ExchangeTypePayload, AddIsbnPayload, AddIsbnResult } from './TalebookApiUtil';

export {
  AccessStatusResponse,
  AdminBookListResponse,
  AdminImportListResponse,
  AdminMemoListResponse,
  AdminResourcesResponse,
  AdminReviewsResponse,
  AdminRunningTasksResponse,
  AdminSettingsResponse,
  AdminSyslogResponse,
  AdminTokenResponse,
  AdminToolListResponse,
  AdminUserPage,
  AdminUsersResponse,
  ApiMessageResult,
  ApiResult,
  AudioImportStatusResponse,
  BarcodeResponse,
  BatchAddRunResponse,
  BatchAddStatusResponse,
  BatchCategoryOpts,
  BatchCategoryResponse,
  BatchTagUpdateResponse,
  BatchUploadFile,
  BookBarnApplyTokenResponse,
  BookDetailPayload,
  BookFilePathResponse,
  BookListPayload,
  BookbarnAdminTokenResponse,
  ClearRareTagsResponse,
  EpubBeautifyRunOptions,
  ImportStatusResponse,
  IndexPayload,
  InstallRequest,
  InstallStatusResponse,
  LibraryStatsData,
  LibraryStatsResponse,
  LimitQuery,
  MetaQuery,
  MimoTtsClonesResponse,
  MimoTtsConfigResponse,
  MimoTtsConvertRequest,
  MimoTtsPromptsResponse,
  MimoTtsTestRequest,
  PageQuery,
  ReferQuery,
  SearchQuery,
  StampStatusResponse,
  SyncImportAnchor,
  SyncImportClearResponse,
  SyncImportRequest,
  SyncImportResponse,
  SyncPullResponse,
  SyncPushPayload,
  SysInfoResponse,
  ThanksNotesResponse,
  ToolboxDataResponse,
  ToolboxStoreIndexResponse,
  ToolboxTaskProgressResponse,
  TrashBooksResponse,
  TrashSizeResponse,
  TxtParserResponse,
  TxtReadResponse,
  UploadBatchItem,
  UploadBatchStartResponse,
  UploadBatchStatusResponse,
  UploadBookResponse,
  VipInfoResponse,
  WhoAmIResponse,
  apiErrorMessage
} from './TalebookApiTypes';
export { EditBookRequest, ReferBook, AudioFileInfo, AudioInfoResponse, AudioConversionResponse, AudioCollectionResponse, AudioPurchaseResponse } from '../common/ApiTypes';
export { AvatarUploadResponse, UserUpdatePayload, CropCoverResult, MetaListResponse, AuthorProfile, AuthorInfoResponse, ReferSearchOpts, ReferSearchResponse, AddIsbnResult, MetaNameCount, IndexHomeData } from './TalebookApiUtil';

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
  /** 访问码状态（mybooks `GET /api/access`；talebook `GET /api/welcome`）。
   * err=free 表示无需/已通过，ok 表示仍需输入。 */
  static async getAccessStatus(): Promise<AccessStatusResponse> {
    const raw = await TalebookCoreService.talebookGet(ServerRegistry.profile().accessCodePath);
    return JSON.parse(raw) as AccessStatusResponse;
  }

  /**
   * 提交访问码。
   *
   * mybooks 读 JSON body（`{invite_code}`）；talebook 用 `get_argument("invite_code")` 取值，
   * 必须走 form 编码，并在启用验证码时附带 `captcha_code`（场景 `welcome`）。
   */
  static async submitAccessCode(inviteCode: string, captchaCode: string = ''):
    Promise<ApiMessageResult> {
    const profile = ServerRegistry.profile();
    if (profile.accessCodeSubmitForm) {
      let form = `invite_code=${encodeURIComponent(inviteCode)}`;
      if (captchaCode.length > 0) {
        form += `&captcha_code=${encodeURIComponent(captchaCode)}`;
      }
      const raw = await TalebookCoreService.talebookPostForm(profile.accessCodePath, form);
      return JSON.parse(raw) as ApiMessageResult;
    }
    const body: Record<string, Object> = { 'invite_code': inviteCode };
    const raw = await TalebookCoreService.talebookPost(profile.accessCodePath, JSON.stringify(body));
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

  /** 管理端书籍列表（端点与分页由 ServerProfile 决定）。 */
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

