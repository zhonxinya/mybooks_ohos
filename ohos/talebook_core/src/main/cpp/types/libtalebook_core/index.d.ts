export declare function initCore(filesDir: string, prefsDir?: string): boolean;

export declare function talebookGet(path: string): Promise<string>;
export declare function talebookPost(input: string): Promise<string>;
export declare function talebookPostForm(input: string): Promise<string>;
export declare function talebookDelete(path: string): Promise<string>;
export declare function talebookDeleteWithBody(input: string): Promise<string>;
export declare function talebookUploadBook(input: string): Promise<string>;
export declare function talebookUploadFile(input: string): Promise<string>;
export declare function talebookUploadBookBatch(filesJson: string): Promise<string>;
export declare function talebookUploadFiles(input: string): Promise<string>;
export declare function sonovelGet(path: string): Promise<string>;

export declare function adminTrashBooks(): Promise<string>;
export declare function adminTrashSize(): Promise<string>;
export declare function adminTrashRestore(bookIdsJson: string): Promise<string>;
export declare function adminTrashPurge(bookIdsJson: string): Promise<string>;
export declare function adminTrashClear(): Promise<string>;
export declare function adminBookReviews(input: string): Promise<string>;
export declare function adminBookReviewAction(input: string): Promise<string>;

export declare function adminImportList(input: string): Promise<string>;
export declare function adminImportRun(input: string): Promise<string>;
export declare function adminImportCancel(): Promise<string>;
export declare function adminImportDelete(hashlistJson: string): Promise<string>;
export declare function adminSyslog(): Promise<string>;

export declare function setBaseUrl(input: string): string;

export declare function adminResources(): Promise<string>;
export declare function adminToolList(): Promise<string>;
export declare function adminToolAction(input: string): Promise<string>;
export declare function adminMemoList(input: string): Promise<string>;
export declare function adminMemoAction(input: string): Promise<string>;
export declare function adminMemoDelete(memoId: string): Promise<string>;

export declare function getDownloadRecords(): Promise<string>;
export declare function addDownloadRecord(recordJson: string): Promise<string>;
export declare function deleteDownloadRecord(bookId: string): Promise<string>;

export declare function getReadingHistory(): Promise<string>;
export declare function recordReadingHistory(itemJson: string): Promise<string>;

export declare function getReaderConfig(): Promise<string>;
export declare function saveReaderConfig(configJson: string): Promise<string>;

export declare function downloadBookLocal(optionsJson: string): Promise<string>;

export declare function secureSet(input: string): Promise<string>;
export declare function secureGet(key: string): Promise<string>;
export declare function kvSet(input: string): Promise<string>;
export declare function kvGet(key: string): Promise<string>;

export declare function registerProgressCallback(): number;
