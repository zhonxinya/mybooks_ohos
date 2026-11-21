/**
 * TalebookApi 管理端操作域（拆分自 TalebookApi.ets，800 行门禁）：书库/用户/书评/导入/回收站/系统信息与设置、批处理与维护。
 */
import { BookItem } from './BookModels';
import { TalebookCoreService } from './TalebookCoreService';
import { ServerEndpoint, ServerRegistry } from './ServerProfile';
import { AdminBookListResponse, AdminImportListResponse, AdminMemoListResponse, AdminResourcesResponse, AdminReviewsResponse, AdminRunningTasksResponse, AdminSettingsResponse, AdminSyslogResponse, AdminTokenResponse, AdminUsersResponse, ApiMessageResult, AudioImportStatusResponse, BarcodeResponse, BatchAddRunResponse, BatchAddStatusResponse, BookbarnAdminTokenResponse, ImportStatusResponse, InstallRequest, InstallStatusResponse, LibraryStatsResponse, StampStatusResponse, SysInfoResponse, ThanksNotesResponse, TrashBooksResponse, TrashSizeResponse } from './TalebookApiTypes';
import { appendQuery, parseJsonAsync, parseList } from './TalebookApiUtil';

export class TalebookApiAdmin {
  static async getAdminBooks(page: number, limit: number): Promise<BookItem[]> {
    const raw = await TalebookCoreService.talebookGet(
      `${ServerRegistry.adminBooksPath()}?${ServerRegistry.adminBooksQuery(page, limit)}`);
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
    return await parseJsonAsync(raw) as AdminBookListResponse;
  }

  static async getAdminUserList(page: number, num: number): Promise<AdminUsersResponse> {
    let path = '/api/admin/users';
    path = appendQuery(path, 'page', page);
    path = appendQuery(path, 'num', num);
    const raw = await TalebookCoreService.talebookGet(path);
    return await parseJsonAsync(raw) as AdminUsersResponse;
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

  /** 回收站书籍列表（端点与响应键由 ServerProfile 决定：books/items）。 */
  static async getTrashBooks(): Promise<TrashBooksResponse> {
    const raw = await TalebookCoreService.talebookGet(ServerRegistry.trashBooksPath());
    const parsed = await parseJsonAsync(raw) as TrashBooksResponse;
    if (parsed.books === undefined) {
      const fallback = (parsed as Record<string, Object>)[ServerRegistry.trashItemsKey()];
      if (fallback !== undefined) {
        parsed.books = fallback as Array<Record<string, Object>>;
      }
    }
    return parsed;
  }

  static async getTrashSize(): Promise<TrashSizeResponse> {
    const raw = await TalebookCoreService.adminTrashSize();
    return JSON.parse(raw) as TrashSizeResponse;
  }

  /** 回收站 id 数组打包为当前服务端要求的请求体（book_ids / idlist）。 */
  private static trashBody(bookIds: number[], withConfirm: boolean): string {
    const payload: Record<string, Object> = {};
    payload[ServerRegistry.trashIdKey()] = bookIds;
    if (withConfirm && ServerRegistry.trashPurgeNeedsConfirm()) {
      payload['confirm'] = true;
    }
    return JSON.stringify(payload);
  }

  private static async trashRequest(endpoint: ServerEndpoint, body: string): Promise<ApiMessageResult> {
    let raw: string;
    if (endpoint.method === 'POST') {
      raw = await TalebookCoreService.talebookPost(endpoint.path, body);
    } else if (endpoint.method === 'PATCH') {
      raw = await TalebookCoreService.talebookPatch(endpoint.path, body);
    } else {
      raw = await TalebookCoreService.talebookDeleteWithBody(endpoint.path, body);
    }
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async restoreTrashBooks(bookIds: number[]): Promise<ApiMessageResult> {
    return TalebookApiAdmin.trashRequest(ServerRegistry.trashRestore(),
      TalebookApiAdmin.trashBody(bookIds, false));
  }

  static async purgeTrashBooks(bookIds: number[]): Promise<ApiMessageResult> {
    return TalebookApiAdmin.trashRequest(ServerRegistry.trashPurge(),
      TalebookApiAdmin.trashBody(bookIds, true));
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

  /** 系统日志（mybooks `/api/admin/syslog`；talebook `/api/admin/log`）。 */
  static async getAdminSyslog(): Promise<AdminSyslogResponse> {
    const raw = await TalebookCoreService.talebookGet(ServerRegistry.adminSyslogPath());
    return await parseJsonAsync(raw) as AdminSyslogResponse;
  }

  static async getAdminResources(): Promise<AdminResourcesResponse> {
    const raw = await TalebookCoreService.adminResources();
    return await parseJsonAsync(raw) as AdminResourcesResponse;
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

  /**
   * 执行首次安装（POST /api/admin/install，服务端读 query/form 参数）。
   * 管理员密码等凭据必须走请求体，不得拼入 URL——URL 会被服务端/代理访问日志、
   * 浏览器 Referer 等渠道记录。其余凭据接口（sign_in/sign_up/new）同样使用 form 体。
   */
  static async runInstall(opts: InstallRequest): Promise<ApiMessageResult> {
    let form = 'username=' + encodeURIComponent(opts.username)
      + '&password=' + encodeURIComponent(opts.password)
      + '&email=' + encodeURIComponent(opts.email)
      + '&title=' + encodeURIComponent(opts.title);
    if (opts.language !== undefined && opts.language.length > 0) {
      form += '&language=' + encodeURIComponent(opts.language);
    }
    if (opts.invite !== undefined && opts.invite.length > 0) {
      form += '&invite=' + encodeURIComponent(opts.invite);
    }
    if (opts.code !== undefined && opts.code.length > 0) {
      form += '&code=' + encodeURIComponent(opts.code);
    }
    const raw = await TalebookCoreService.talebookPostForm('/api/admin/install', form);
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

  /** 系统日志下载相对路径（二进制；路径随服务端变化）。 */
  static adminSyslogDownloadPath(): string {
    return `${ServerRegistry.adminSyslogPath()}/download`;
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
    const raw = await TalebookCoreService.talebookPost(
      ServerRegistry.profile().adminBookDeletePath, JSON.stringify(body));
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

}

