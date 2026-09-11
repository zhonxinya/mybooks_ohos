import talebookCore from 'libtalebook_core.so';

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

export class TalebookNativeCore {
  private static initialized: boolean = false;

  static initCore(filesDir: string, prefsDir: string = ''): boolean {
    const ok = talebookCore.initCore(filesDir, prefsDir) as boolean;
    TalebookNativeCore.initialized = ok;
    return ok;
  }

  static isInitialized(): boolean {
    return TalebookNativeCore.initialized;
  }

  static setBaseUrl(input: string): string {
    return talebookCore.setBaseUrl(input) as string;
  }

  static async talebookGet(path: string): Promise<string> {
    const raw = await talebookCore.talebookGet(path) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async talebookPost(path: string, body: string): Promise<string> {
    const raw = await talebookCore.talebookPost(`${path}|${body}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async talebookPostForm(path: string, body: string): Promise<string> {
    const raw = await talebookCore.talebookPostForm(`${path}|${body}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async talebookDelete(path: string): Promise<string> {
    const raw = await talebookCore.talebookDelete(path) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async talebookDeleteWithBody(path: string, body: string): Promise<string> {
    const raw = await talebookCore.talebookDeleteWithBody(`${path}|${body}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async talebookUploadBook(filePath: string, fileName: string, bookId: string): Promise<string> {
    const safeName = fileName.replace(/\|/g, '_');
    const raw = await talebookCore.talebookUploadBook(`${filePath}|${safeName}|${bookId}`) as string;
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
    const raw = await talebookCore.talebookUploadFile(
      `${path}|${filePath}|${fieldName}|${safeName}|${safeFields}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'upload failed');
    }
    return dataToString(resp.data);
  }
  static async talebookUploadBookBatch(filesJson: string): Promise<string> {
    const raw = await talebookCore.talebookUploadBookBatch(filesJson) as string;
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
    const raw = await talebookCore.talebookUploadFiles(
      path + '|' + filesJson + '|' + safeFields) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'upload files failed');
    }
    return dataToString(resp.data);
  }

  static async sonovelGet(path: string): Promise<string> {
    const raw = await talebookCore.sonovelGet(path) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminTrashBooks(): Promise<string> {
    const raw = await talebookCore.adminTrashBooks() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminTrashSize(): Promise<string> {
    const raw = await talebookCore.adminTrashSize() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminTrashRestore(bookIdsJson: string): Promise<string> {
    const raw = await talebookCore.adminTrashRestore(bookIdsJson) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminTrashPurge(bookIdsJson: string): Promise<string> {
    const raw = await talebookCore.adminTrashPurge(bookIdsJson) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminTrashClear(): Promise<string> {
    const raw = await talebookCore.adminTrashClear() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminBookReviews(status: string, page: number, pageSize: number): Promise<string> {
    const raw = await talebookCore.adminBookReviews(`${status}|${page}|${pageSize}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminBookReviewAction(reviewId: number, action: string): Promise<string> {
    const raw = await talebookCore.adminBookReviewAction(`${reviewId}|${action}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminImportList(page: number, num: number, filter: string): Promise<string> {
    const raw = await talebookCore.adminImportList(`${page}|${num}|${filter}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminImportRun(filelistJson: string, force: boolean): Promise<string> {
    const raw = await talebookCore.adminImportRun(`${filelistJson}|${force ? 1 : 0}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminImportCancel(): Promise<string> {
    const raw = await talebookCore.adminImportCancel() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminImportDelete(hashlistJson: string): Promise<string> {
    const raw = await talebookCore.adminImportDelete(hashlistJson) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminSyslog(): Promise<string> {
    const raw = await talebookCore.adminSyslog() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminResources(): Promise<string> {
    const raw = await talebookCore.adminResources() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminToolList(): Promise<string> {
    const raw = await talebookCore.adminToolList() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminToolAction(toolId: string, action: string): Promise<string> {
    const raw = await talebookCore.adminToolAction(`${toolId}|${action}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminMemoList(page: number, pageSize: number): Promise<string> {
    const raw = await talebookCore.adminMemoList(`${page}|${pageSize}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminMemoAction(memoId: number, action: string, reply: string): Promise<string> {
    const raw = await talebookCore.adminMemoAction(`${memoId}|${action}|${reply}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async adminMemoDelete(memoId: number): Promise<string> {
    const raw = await talebookCore.adminMemoDelete(`${memoId}`) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok) {
      throw new Error(resp.error ?? 'request failed');
    }
    return dataToString(resp.data);
  }

  static async getDownloadRecords(): Promise<Array<Record<string, Object>>> {
    const raw = await talebookCore.getDownloadRecords() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok || resp.data === undefined || resp.data === null) {
      return [];
    }
    return resp.data as Array<Record<string, Object>>;
  }

  static async addDownloadRecord(record: Record<string, Object>): Promise<void> {
    await talebookCore.addDownloadRecord(JSON.stringify(record));
  }

  static async deleteDownloadRecord(bookId: string): Promise<void> {
    await talebookCore.deleteDownloadRecord(bookId);
  }

  static async getReadingHistory(): Promise<Array<Record<string, Object>>> {
    const raw = await talebookCore.getReadingHistory() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok || resp.data === undefined || resp.data === null) {
      return [];
    }
    return resp.data as Array<Record<string, Object>>;
  }

  static async recordReadingHistory(item: Record<string, Object>): Promise<void> {
    await talebookCore.recordReadingHistory(JSON.stringify(item));
  }

  static async getReaderConfig(): Promise<Record<string, Object>> {
    const raw = await talebookCore.getReaderConfig() as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok || resp.data === undefined || resp.data === null) {
      return {};
    }
    return resp.data as Record<string, Object>;
  }

  static async saveReaderConfig(config: Record<string, Object>): Promise<void> {
    await talebookCore.saveReaderConfig(JSON.stringify(config));
  }

  static async downloadBookLocal(options: Record<string, Object>): Promise<Record<string, Object>> {
    const raw = await talebookCore.downloadBookLocal(JSON.stringify(options)) as string;
    return JSON.parse(raw) as Record<string, Object>;
  }

  static async secureSet(key: string, value: string): Promise<void> {
    await talebookCore.secureSet(`${key}|${value}`);
  }

  static async secureGet(key: string): Promise<string | null> {
    const raw = await talebookCore.secureGet(key) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok || resp.data === null || resp.data === undefined) {
      return null;
    }
    return typeof resp.data === 'string' ? resp.data : JSON.stringify(resp.data);
  }

  static async kvSet(key: string, value: string): Promise<void> {
    await talebookCore.kvSet(`${key}|${value}`);
  }

  static async kvGet(key: string): Promise<string | null> {
    const raw = await talebookCore.kvGet(key) as string;
    const resp = parseCoreResponse(raw);
    if (!resp.ok || resp.data === null || resp.data === undefined) {
      return null;
    }
    return typeof resp.data === 'string' ? resp.data : JSON.stringify(resp.data);
  }
}
