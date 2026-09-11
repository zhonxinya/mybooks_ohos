import { common } from '@kit.AbilityKit';
import { NativeCore } from 'mybooks_core';

/** Singleton wrapper around NativeCore. */
export class TalebookCoreService {
  private static instance: TalebookCoreService | null = null;
  private initialized: boolean = false;
  /** native 尚未就绪时暂存的 base URL，init 成功后补发（避免其 HttpClient 的 baseUrl 一直为空） */
  private pendingBaseUrls: Map<string, string> = new Map();
  /** native 尚未就绪时暂存的 TLS 校验开关，init 成功后补发 */
  private pendingSslVerify: boolean | null = null;

  static getInstance(): TalebookCoreService {
    if (TalebookCoreService.instance === null) {
      TalebookCoreService.instance = new TalebookCoreService();
    }
    return TalebookCoreService.instance;
  }

  static init(context: common.Context): void {
    TalebookCoreService.getInstance().init(context).catch(() => {
    });
  }

  /** 切换账号身份根（数据库/凭据/下载/历史/书签 + Cookie）。 */
  static setIdentityDir(dir: string): void {
    TalebookCoreService.getInstance().setIdentityDir(dir);
  }

  static ensureInitialized(context: common.Context): Promise<boolean> {
    return TalebookCoreService.getInstance().init(context);
  }

  static talebookGet(path: string): Promise<string> {
    return TalebookCoreService.getInstance().talebookGet(path);
  }

  static talebookPost(path: string, body: string): Promise<string> {
    return TalebookCoreService.getInstance().talebookPost(path, body);
  }

  static talebookPostForm(path: string, body: string): Promise<string> {
    return TalebookCoreService.getInstance().talebookPostForm(path, body);
  }

  static talebookDelete(path: string): Promise<string> {
    return TalebookCoreService.getInstance().talebookDelete(path);
  }

  static talebookDeleteWithBody(path: string, body: string): Promise<string> {
    return TalebookCoreService.getInstance().talebookDeleteWithBody(path, body);
  }

  static talebookPatch(path: string, body: string): Promise<string> {
    return TalebookCoreService.getInstance().talebookPatch(path, body);
  }

  static talebookPut(path: string, body: string): Promise<string> {
    return TalebookCoreService.getInstance().talebookPut(path, body);
  }

  static talebookUploadBook(filePath: string, fileName: string, bookId: string = ''): Promise<string> {
    return NativeCore.talebookUploadBook(filePath, fileName, bookId);
  }

  static talebookUploadFile(path: string, filePath: string, fieldName: string,
    fileName: string, fieldsJson: string = ''): Promise<string> {
    return NativeCore.talebookUploadFile(path, filePath, fieldName, fileName, fieldsJson);
  }
  static talebookUploadBookBatch(filesJson: string): Promise<string> {
    return NativeCore.talebookUploadBookBatch(filesJson);
  }
  static talebookUploadFiles(path: string, filesJson: string,
    fieldsJson: string = ''): Promise<string> {
    return NativeCore.talebookUploadFiles(path, filesJson, fieldsJson);
  }

  static sonovelGet(path: string): Promise<string> {
    return TalebookCoreService.getInstance().sonovelGet(path);
  }

  static adminTrashBooks(): Promise<string> {
    return NativeCore.adminTrashBooks();
  }

  static adminTrashSize(): Promise<string> {
    return NativeCore.adminTrashSize();
  }

  static adminTrashRestore(bookIdsJson: string): Promise<string> {
    return NativeCore.adminTrashRestore(bookIdsJson);
  }

  static adminTrashPurge(bookIdsJson: string): Promise<string> {
    return NativeCore.adminTrashPurge(bookIdsJson);
  }

  static adminTrashClear(): Promise<string> {
    return NativeCore.adminTrashClear();
  }

  static adminBookReviews(status: string, page: number, pageSize: number): Promise<string> {
    return NativeCore.adminBookReviews(status, page, pageSize);
  }

  static adminBookReviewAction(reviewId: number, action: string): Promise<string> {
    return NativeCore.adminBookReviewAction(reviewId, action);
  }

  static adminImportList(page: number, num: number, filter: string): Promise<string> {
    return NativeCore.adminImportList(page, num, filter);
  }

  static adminImportRun(filelistJson: string, force: boolean): Promise<string> {
    return NativeCore.adminImportRun(filelistJson, force);
  }

  static adminImportCancel(): Promise<string> {
    return NativeCore.adminImportCancel();
  }

  static adminImportDelete(hashlistJson: string): Promise<string> {
    return NativeCore.adminImportDelete(hashlistJson);
  }

  static adminSyslog(): Promise<string> {
    return NativeCore.adminSyslog();
  }

  static adminResources(): Promise<string> {
    return NativeCore.adminResources();
  }

  static adminToolList(): Promise<string> {
    return NativeCore.adminToolList();
  }

  static adminToolAction(toolId: string, action: string): Promise<string> {
    return NativeCore.adminToolAction(toolId, action);
  }

  static adminMemoList(page: number, pageSize: number): Promise<string> {
    return NativeCore.adminMemoList(page, pageSize);
  }

  static adminMemoAction(memoId: number, action: string, reply: string): Promise<string> {
    return NativeCore.adminMemoAction(memoId, action, reply);
  }

  static adminMemoDelete(memoId: number): Promise<string> {
    return NativeCore.adminMemoDelete(memoId);
  }

  /** 将服务端地址写入 mybooks_core 自身存储，供其 HttpClient 使用 */
  static syncBaseUrl(name: string, url: string): void {
    if (url.length === 0) {
      return;
    }
    const instance = TalebookCoreService.getInstance();
    if (!NativeCore.isInitialized()) {
      // native 尚未就绪：先暂存，待 init 成功后补发
      instance.pendingBaseUrls.set(name, url);
      return;
    }
    NativeCore.setBaseUrl(`${name}|${url}`);
  }

  /** 同步「跳过 SSL 验证」开关：allowInsecure=false 时默认校验证书 */
  static setSslVerify(allowInsecure: boolean): void {
    const instance = TalebookCoreService.getInstance();
    if (!NativeCore.isInitialized()) {
      instance.pendingSslVerify = allowInsecure;
      return;
    }
    NativeCore.setSslVerify(!allowInsecure);
  }

  static getDownloadRecords(): Promise<Array<Record<string, Object>>> {
    return TalebookCoreService.getInstance().getDownloadRecords();
  }

  static addDownloadRecord(record: Record<string, Object>): Promise<void> {
    return TalebookCoreService.getInstance().addDownloadRecord(record);
  }

  static deleteDownloadRecord(bookId: string): Promise<void> {
    return TalebookCoreService.getInstance().deleteDownloadRecord(bookId);
  }

  static getReadingHistory(): Promise<Array<Record<string, Object>>> {
    return TalebookCoreService.getInstance().getReadingHistory();
  }

  static recordReadingHistory(item: Record<string, Object>): Promise<void> {
    return TalebookCoreService.getInstance().recordReadingHistory(item);
  }

  static getReaderConfig(): Promise<Record<string, Object>> {
    return TalebookCoreService.getInstance().getReaderConfig();
  }

  static saveReaderConfig(config: Record<string, Object>): Promise<void> {
    return TalebookCoreService.getInstance().saveReaderConfig(config);
  }

  static downloadBookLocal(options: Record<string, Object>): Promise<Record<string, Object>> {
    return TalebookCoreService.getInstance().downloadBookLocal(options);
  }

  static secureSet(key: string, value: string): Promise<void> {
    return TalebookCoreService.getInstance().secureSet(key, value);
  }

  static secureGet(key: string): Promise<string | null> {
    return TalebookCoreService.getInstance().secureGet(key);
  }

  static kvSet(key: string, value: string): Promise<void> {
    return TalebookCoreService.getInstance().kvSet(key, value);
  }

  static kvGet(key: string): Promise<string | null> {
    return TalebookCoreService.getInstance().kvGet(key);
  }

  async init(context: common.Context): Promise<boolean> {
    if (this.initialized) {
      return true;
    }
    const ok: boolean = NativeCore.initCore(context.filesDir as string);
    this.initialized = ok;
    if (ok && this.pendingBaseUrls.size > 0) {
      // 补发 init 之前暂存的服务端地址，否则其 HttpClient 的 baseUrl 会一直为空
      this.pendingBaseUrls.forEach((url: string, name: string) => {
        NativeCore.setBaseUrl(`${name}|${url}`);
      });
      this.pendingBaseUrls.clear();
    }
    if (ok && this.pendingSslVerify !== null) {
      // 补发 init 之前暂存的 TLS 校验开关，否则其 HttpClient 会一直使用默认值
      NativeCore.setSslVerify(!this.pendingSslVerify);
      this.pendingSslVerify = null;
    }
    return ok;
  }

  /** 切换账号身份根（数据库/凭据/下载/历史/书签 + Cookie）。 */
  setIdentityDir(dir: string): void {
    NativeCore.setIdentityDir(dir);
  }

  talebookGet(path: string): Promise<string> {
    return NativeCore.talebookGet(path);
  }
  talebookPost(path: string, body: string): Promise<string> {
    return NativeCore.talebookPost(path, body);
  }

  talebookPostForm(path: string, body: string): Promise<string> {
    return NativeCore.talebookPostForm(path, body);
  }

  talebookDelete(path: string): Promise<string> {
    return NativeCore.talebookDelete(path);
  }

  talebookDeleteWithBody(path: string, body: string): Promise<string> {
    return NativeCore.talebookDeleteWithBody(path, body);
  }

  talebookPatch(path: string, body: string): Promise<string> {
    return NativeCore.talebookPatch(path, body);
  }

  talebookPut(path: string, body: string): Promise<string> {
    return NativeCore.talebookPut(path, body);
  }

  sonovelGet(path: string): Promise<string> {
    return NativeCore.sonovelGet(path);
  }

  getDownloadRecords(): Promise<Array<Record<string, Object>>> {
    return NativeCore.getDownloadRecords() as Promise<Array<Record<string, Object>>>;
  }

  addDownloadRecord(record: Record<string, Object>): Promise<void> {
    return NativeCore.addDownloadRecord(record);
  }

  deleteDownloadRecord(bookId: string): Promise<void> {
    return NativeCore.deleteDownloadRecord(bookId);
  }

  getReadingHistory(): Promise<Array<Record<string, Object>>> {
    return NativeCore.getReadingHistory() as Promise<Array<Record<string, Object>>>;
  }

  recordReadingHistory(item: Record<string, Object>): Promise<void> {
    return NativeCore.recordReadingHistory(item);
  }

  getReaderConfig(): Promise<Record<string, Object>> {
    return NativeCore.getReaderConfig() as Promise<Record<string, Object>>;
  }

  saveReaderConfig(config: Record<string, Object>): Promise<void> {
    return NativeCore.saveReaderConfig(config);
  }

  downloadBookLocal(options: Record<string, Object>): Promise<Record<string, Object>> {
    return NativeCore.downloadBookLocal(options) as Promise<Record<string, Object>>;
  }

  secureSet(key: string, value: string): Promise<void> {
    return NativeCore.secureSet(key, value);
  }

  secureGet(key: string): Promise<string | null> {
    return NativeCore.secureGet(key);
  }

  kvSet(key: string, value: string): Promise<void> {
    return NativeCore.kvSet(key, value);
  }

  kvGet(key: string): Promise<string | null> {
    return NativeCore.kvGet(key);
  }
}
