import mybooksCore from 'libmybooks_core.so';

interface CoreResponse {
  ok: boolean;
  data?: Object | string | number | boolean | null;
  error?: string;
}

function parseCoreResponse(json: string): CoreResponse {
  try {
    return JSON.parse(json) as CoreResponse;
  } catch (_e) {
    const failed: CoreResponse = { ok: false, error: json };
    return failed;
  }
}

function dataToString(data: Object | string | number | boolean | null | undefined): string {
  if (data === undefined || data === null) {
    return '';
  }
  if (typeof data === 'string') {
    return data;
  }
  return JSON.stringify(data);
}

export class NativeCore {
  private static initialized: boolean = false;

  static initCore(filesDir: string, prefsDir: string = ''): boolean {
    const ok = mybooksCore.initCore(filesDir, prefsDir) as boolean;
    NativeCore.initialized = ok;
    return ok;
  }

  /** 切换账号身份根目录（数据库/凭据/下载/历史/书签 + Cookie）。 */
  static setIdentityDir(dir: string): void {
    mybooksCore.setIdentityDir(dir);
  }

  static isInitialized(): boolean {
    return NativeCore.initialized;
  }

  static setBaseUrl(input: string): string {
    return mybooksCore.setBaseUrl(input) as string;
  }

  /** 是否校验证书：false 时跳过 TLS 校验（仅用于用户显式允许的自签名服务端） */
  static setSslVerify(verify: boolean): void {
    mybooksCore.setSslVerify(verify);
  }

  /** 连接层性能日志开关（默认关，排查网络问题时打开） */
  static setHttpMetrics(enabled: boolean): void {
    mybooksCore.setHttpMetrics(enabled);
  }

  static async talebookGet(path: string): Promise<string> {
    const raw = await mybooksCore.talebookGet(path) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async talebookPost(path: string, body: string): Promise<string> {
    const raw = await mybooksCore.talebookPost(`${path}|${body}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async talebookPostForm(path: string, body: string): Promise<string> {
    const raw = await mybooksCore.talebookPostForm(`${path}|${body}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async talebookDelete(path: string): Promise<string> {
    const raw = await mybooksCore.talebookDelete(path) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async talebookDeleteWithBody(path: string, body: string): Promise<string> {
    const raw = await mybooksCore.talebookDeleteWithBody(`${path}|${body}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async talebookPatch(path: string, body: string): Promise<string> {
    const raw = await mybooksCore.talebookPatch(`${path}|${body}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async talebookPut(path: string, body: string): Promise<string> {
    const raw = await mybooksCore.talebookPut(`${path}|${body}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async talebookUploadBook(filePath: string, fileName: string, bookId: string): Promise<string> {
    const safeName = fileName.replace(/\|/g, '_');
    const raw = await mybooksCore.talebookUploadBook(`${filePath}|${safeName}|${bookId}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'upload failed');
    }
    return dataToString(resp.data);
  }

  static async talebookUploadFile(path: string, filePath: string, fieldName: string,
    fileName: string, fieldsJson: string = ''): Promise<string> {
    const safeName = fileName.replace(/\|/g, '_');
    const safeFields = fieldsJson.replace(/\|/g, ' ');
    const raw = await mybooksCore.talebookUploadFile(
      `${path}|${filePath}|${fieldName}|${safeName}|${safeFields}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'upload failed');
    }
    return dataToString(resp.data);
  }
  static async talebookUploadBookBatch(filesJson: string): Promise<string> {
    const raw = await mybooksCore.talebookUploadBookBatch(filesJson) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'batch upload failed');
    }
    return dataToString(resp.data);
  }

  /** 多文件且每文件独立 multipart 字段名。filesJson: [{path,name,field},...] */
  static async talebookUploadFiles(path: string, filesJson: string,
    fieldsJson: string = ''): Promise<string> {
    const safeFields = fieldsJson.replace(/\|/g, ' ');
    const raw = await mybooksCore.talebookUploadFiles(
      path + '|' + filesJson + '|' + safeFields) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'upload files failed');
    }
    return dataToString(resp.data);
  }

  static async sonovelGet(path: string): Promise<string> {
    const raw = await mybooksCore.sonovelGet(path) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminTrashBooks(): Promise<string> {
    const raw = await mybooksCore.adminTrashBooks() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminTrashSize(): Promise<string> {
    const raw = await mybooksCore.adminTrashSize() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminTrashRestore(bookIdsJson: string): Promise<string> {
    const raw = await mybooksCore.adminTrashRestore(bookIdsJson) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminTrashPurge(bookIdsJson: string): Promise<string> {
    const raw = await mybooksCore.adminTrashPurge(bookIdsJson) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminTrashClear(): Promise<string> {
    const raw = await mybooksCore.adminTrashClear() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminBookReviews(status: string, page: number, pageSize: number): Promise<string> {
    const raw = await mybooksCore.adminBookReviews(`${status}|${page}|${pageSize}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminBookReviewAction(reviewId: number, action: string): Promise<string> {
    const raw = await mybooksCore.adminBookReviewAction(`${reviewId}|${action}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminImportList(page: number, num: number, filter: string): Promise<string> {
    const raw = await mybooksCore.adminImportList(`${page}|${num}|${filter}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminImportRun(filelistJson: string, force: boolean): Promise<string> {
    const raw = await mybooksCore.adminImportRun(`${filelistJson}|${force ? 1 : 0}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminImportCancel(): Promise<string> {
    const raw = await mybooksCore.adminImportCancel() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminImportDelete(hashlistJson: string): Promise<string> {
    const raw = await mybooksCore.adminImportDelete(hashlistJson) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminSyslog(): Promise<string> {
    const raw = await mybooksCore.adminSyslog() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminResources(): Promise<string> {
    const raw = await mybooksCore.adminResources() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminToolList(): Promise<string> {
    const raw = await mybooksCore.adminToolList() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminToolAction(toolId: string, action: string): Promise<string> {
    const raw = await mybooksCore.adminToolAction(`${toolId}|${action}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminMemoList(page: number, pageSize: number): Promise<string> {
    const raw = await mybooksCore.adminMemoList(`${page}|${pageSize}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminMemoAction(memoId: number, action: string, reply: string): Promise<string> {
    const raw = await mybooksCore.adminMemoAction(`${memoId}|${action}|${reply}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminMemoDelete(memoId: number): Promise<string> {
    const raw = await mybooksCore.adminMemoDelete(`${memoId}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async getDownloadRecords(): Promise<Array<Record<string, Object>>> {
    const raw = await mybooksCore.getDownloadRecords() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok || resp.data === undefined || resp.data === null) {
      return [];
    }
    return resp.data as Array<Record<string, Object>>;
  }

  static async addDownloadRecord(record: Record<string, Object>): Promise<void> {
    await mybooksCore.addDownloadRecord(JSON.stringify(record));
  }

  static async deleteDownloadRecord(bookId: string): Promise<void> {
    await mybooksCore.deleteDownloadRecord(bookId);
  }

  static async getReadingHistory(): Promise<Array<Record<string, Object>>> {
    const raw = await mybooksCore.getReadingHistory() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok || resp.data === undefined || resp.data === null) {
      return [];
    }
    return resp.data as Array<Record<string, Object>>;
  }

  static async recordReadingHistory(item: Record<string, Object>): Promise<void> {
    await mybooksCore.recordReadingHistory(JSON.stringify(item));
  }

  static async getReaderConfig(): Promise<Record<string, Object>> {
    const raw = await mybooksCore.getReaderConfig() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok || resp.data === undefined || resp.data === null) {
      return {};
    }
    return resp.data as Record<string, Object>;
  }

  static async saveReaderConfig(config: Record<string, Object>): Promise<void> {
    await mybooksCore.saveReaderConfig(JSON.stringify(config));
  }

  static async downloadBookLocal(options: Record<string, Object>): Promise<Record<string, Object>> {
    const raw = await mybooksCore.downloadBookLocal(JSON.stringify(options)) as string;
    return JSON.parse(raw) as Record<string, Object>;
  }

  static async secureSet(key: string, value: string): Promise<void> {
    await mybooksCore.secureSet(`${key}|${value}`);
  }

  static async secureGet(key: string): Promise<string | null> {
    const raw = await mybooksCore.secureGet(key) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok || resp.data === null || resp.data === undefined) {
      return null;
    }
    return typeof resp.data === 'string' ? resp.data : JSON.stringify(resp.data);
  }

  static async kvSet(key: string, value: string): Promise<void> {
    await mybooksCore.kvSet(`${key}|${value}`);
  }

  static async kvGet(key: string): Promise<string | null> {
    const raw = await mybooksCore.kvGet(key) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok || resp.data === null || resp.data === undefined) {
      return null;
    }
    return typeof resp.data === 'string' ? resp.data : JSON.stringify(resp.data);
  }
}
