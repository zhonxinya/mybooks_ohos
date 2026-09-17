import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PageScaffold, PrimaryButton, TextButton, SecondaryButton } from '../components';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { TalebookApi, UploadBookResponse, UploadBatchStartResponse, UploadBatchStatusResponse,
  BatchUploadFile, AddIsbnResult, apiErrorMessage } from '../services/TalebookApi';
import { BookUploadService, PickedBookFile } from '../services/BookUploadService';

interface UploadItem {
  id: number;
  name: string;
  size: number;
  localPath: string;
  status: string;
  message: string;
  bookId: number;
  progressText: string;
  /** 0~100，0 表示暂无确定进度（如批量导入等待服务端） */
  progress: number;
}

const ITEM_PENDING = 'pending';
const ITEM_UPLOADING = 'uploading';
const ITEM_SUCCESS = 'success';
const ITEM_FAILED = 'failed';
/** 超过该大小走分块上传（与服务端分块导入逻辑对齐） */
const CHUNK_THRESHOLD = 8 * 1024 * 1024;
const CHUNK_SIZE = 4 * 1024 * 1024;
const TAG: string = 'BookUpload';
/**
 * 本次运行内批量通道已被判定不可用的标记（AppStorage）。
 * 批量通道依赖服务端 scan_upload_path 暂存文件，实测有部署会在这步失败；一旦失败就不再重试，
 * 避免每次上传都白传一遍整批文件再弹一次错误。
 */
const BATCH_UNAVAILABLE_KEY = 'talebookUploadBatchUnavailable';

/** 把异常转成可读文本：优先取 message，避免界面上出现 "Error: xxx" 前缀。 */
function errorText(e: Object): string {
  const err = e as Error;
  const message = err.message;
  return message !== undefined && message.length > 0 ? message : `${e}`;
}

@Entry
@Component
struct BookUploadPage {
  @State items: UploadItem[] = [];
  @State uploading: boolean = false;
  @State showIsbnSheet: boolean = false;
  @State isbnInput: string = '';
  @State isbnError: string = '';
  @State addingBook: boolean = false;
  @State scanningBarcode: boolean = false;
  @State batchImportId: number = 0;
  @State batchHint: string = '';
  private nextItemId: number = 1;
  private batchPollTimer: number = -1;

  aboutToAppear(): void {
    TalebookService.ensureAuthenticated().catch(() => {});
  }

  aboutToDisappear(): void {
    this.stopBatchPoll();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  /** ISBN-10/13 校验（去连字符/空格后校验位验证）。 */
  private isValidIsbn(raw: string): boolean {
    const isbn = raw.replace(/[-\s]/g, '');
    if (isbn.length === 13 && /^[0-9]{13}$/.test(isbn)) {
      let sum = 0;
      for (let i = 0; i < 12; i++) {
        sum += Number(isbn.charAt(i)) * (i % 2 === 0 ? 1 : 3);
      }
      return (10 - sum % 10) % 10 === Number(isbn.charAt(12));
    }
    if (isbn.length === 10 && /^[0-9]{9}[0-9Xx]$/.test(isbn)) {
      let sum = 0;
      for (let i = 0; i < 10; i++) {
        const c = isbn.charAt(i);
        const v = c === 'X' || c === 'x' ? 10 : Number(c);
        sum += v * (10 - i);
      }
      return sum % 11 === 0;
    }
    return false;
  }

  private async addByIsbn(): Promise<void> {
    // ISBN 联网添加为 MyBooks 专有端点；入口已隐藏，这里兜底防止残留入口发起 404
    if (!ServerRegistry.supports(ServerFeature.BOOK_ISBN_ADD)) {
      this.toast(`${ServerRegistry.profile().displayName} 服务端不支持按 ISBN 添加实体书`);
      return;
    }
    const isbn = this.isbnInput.replace(/[-\s]/g, '');
    if (isbn.length === 0) {
      this.isbnError = '请输入 ISBN 号';
      return;
    }
    if (!this.isValidIsbn(isbn)) {
      this.isbnError = 'ISBN 校验位不正确，请检查输入';
      return;
    }
    if (this.addingBook) {
      return;
    }
    this.addingBook = true;
    this.isbnError = '';
    try {
      await TalebookService.ensureAuthenticated();
      const rsp: AddIsbnResult = await TalebookApi.addBookByIsbn(isbn);
      if (rsp.err !== 'ok') {
        this.isbnError = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '添加失败';
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '图书添加成功');
      this.showIsbnSheet = false;
      this.isbnInput = '';
      const bookId = Number(rsp.book_id ?? 0);
      if (bookId > 0) {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/BookDetailPage', params: { bookId: bookId } });
      }
    } catch (e) {
      this.isbnError = `添加失败：${e}`;
    } finally {
      this.addingBook = false;
    }
  }

  /** 选择条码图片 -> 服务端识别 ISBN -> 回填输入框（POST /api/admin/barcode）。 */
  private async scanBarcode(): Promise<void> {
    // 条码识别端点为 MyBooks 专有；入口已隐藏，这里兜底防止残留入口发起 404
    if (this.scanningBarcode || !ServerRegistry.supports(ServerFeature.ADMIN_BARCODE)) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.scanningBarcode = true;
    this.isbnError = '';
    let localPath = '';
    try {
      const picked = await BookUploadService.pickStagedFile(
        context, ['.jpg', '.jpeg', '.png', '.bmp', '.webp'], 'barcode');
      if (picked === null) {
        return;
      }
      localPath = picked.localPath;
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.recognizeBarcode(picked.localPath, picked.name);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.isbnError = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '未识别到条码';
        return;
      }
      const isbn = rsp.isbn !== undefined ? rsp.isbn : '';
      if (isbn.length === 0) {
        this.isbnError = '未识别到条码，请换一张更清晰的图片重试';
        return;
      }
      this.isbnInput = isbn;
      this.toast(`已识别 ISBN：${isbn}`);
    } catch (e) {
      this.isbnError = `识别失败：${e}`;
    } finally {
      this.scanningBarcode = false;
      if (localPath.length > 0) {
        BookUploadService.removeStagedFile(localPath);
      }
    }
  }

  /** 与 Web 端一致：基于文件名+大小的简易 hash（hex，作为分块暂存目录标识）。 */
  private fileHash(name: string, size: number): string {
    const str = `${name}:${size}`;
    let h1 = 0x811c9dc5;
    let h2 = 0x01000193;
    for (let i = 0; i < str.length; i++) {
      h1 = ((h1 ^ str.charCodeAt(i)) * 16777619) >>> 0;
      h2 = ((h2 + str.charCodeAt(i) * (i + 7)) * 2654435761) >>> 0;
    }
    return `${h1.toString(16)}${h2.toString(16)}`;
  }

  /**
   * 大文件分块上传：逐块写临时文件后上传，服务端按 file_hash 暂存、收齐后在最后一块的响应里
   * 完成合并导入并返回 book_id。
   *
   * 注意：**不能**靠「本地分块文件是否还在」来判断某一块已经传过。旧实现在缓存目录里留着分块
   * 做「断点续传」，结果同一个文件重传时每一块都被当成「已上传」跳过：一个请求都不发、服务端
   * 也没合并，界面却报「上传成功」（大文件尤其容易踩到：第一次失败留下了分块，之后怎么点都是
   * 假的成功）。现在改成用完即删、每次老老实实把所有分块重发一遍。
   *
   * @throws 内部调用可能抛出异常，由调用方处理
   */
  private async uploadChunked(item: UploadItem): Promise<boolean> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const chunkDir = `${context.cacheDir}/upload/chunks`;
    try {
      if (!fs.accessSync(chunkDir)) {
        fs.mkdirSync(chunkDir, true);
      }
    } catch (_error) {
      fs.mkdirSync(chunkDir, true);
    }
    const totalChunks = Math.ceil(item.size / CHUNK_SIZE);
    const hash = this.fileHash(item.name, item.size);
    const src = fs.openSync(item.localPath, fs.OpenMode.READ_ONLY);
    try {
      for (let i = 0; i < totalChunks; i++) {
        const chunkPath = `${chunkDir}/${hash}_${i}`;
        const start = i * CHUNK_SIZE;
        const length = Math.min(CHUNK_SIZE, item.size - start);
        const buf = new ArrayBuffer(length);
        const readLen = fs.readSync(src.fd, buf, { offset: start, length: length });
        const dst = fs.openSync(chunkPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE |
          fs.OpenMode.TRUNC);
        try {
          fs.writeSync(dst.fd, buf, { length: readLen });
        } finally {
          fs.closeSync(dst.fd);
        }
        this.patchItem(item.id, ITEM_UPLOADING, '', 0, `分块 ${i + 1}/${totalChunks}`,
          Math.round(((i + 1) / totalChunks) * 100));
        let rsp: UploadBookResponse;
        try {
          rsp = await TalebookApi.uploadBookChunk(chunkPath, item.name, i, totalChunks, hash);
        } finally {
          // 临时分块用完即删：不留在缓存里，重传时才不会误判成「已上传」
          BookUploadService.removeStagedFile(chunkPath);
        }
        if (rsp.err !== undefined && rsp.err !== 'ok' && rsp.err !== 'samebook') {
          const msg = apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '分块上传失败';
          this.patchItem(item.id, ITEM_FAILED, msg, Number(rsp.book_id ?? 0), '');
          return false;
        }
        if (rsp.err === 'samebook') {
          // 同名同格式已在库里：服务端没有重新导入，但书确实在（与单文件接口一致按「已上传」算）。
          // 旧实现把它当失败，于是回退整包上传又把同一个文件传了一遍。
          this.patchItem(item.id, ITEM_SUCCESS, '已存在该格式', Number(rsp.book_id ?? 0), '');
          BookUploadService.removeStagedFile(item.localPath);
          BookUploadService.markLibraryDirty();
          return true;
        }
        if (Number(rsp.book_id ?? 0) > 0) {
          // 最后一块：服务端已合并并导入
          this.patchItem(item.id, ITEM_SUCCESS, '', Number(rsp.book_id ?? 0), '');
          BookUploadService.removeStagedFile(item.localPath);
          BookUploadService.markLibraryDirty();
          return true;
        }
      }
      // 分块都返回 ok 却没拿到 book_id：服务端并没有真正合并（例如它那边已经合并过并把临时
      // 分块删了），此时报失败而不是「上传成功」，避免用户以为传上去了。
      this.patchItem(item.id, ITEM_FAILED, '服务端未完成合并，请重试', 0, '');
      return false;
    } finally {
      fs.closeSync(src.fd);
    }
  }


  private stopBatchPoll(): void {
    if (this.batchPollTimer >= 0) {
      clearTimeout(this.batchPollTimer);
      this.batchPollTimer = -1;
    }
  }

  private scheduleBatchPoll(): void {
    this.stopBatchPoll();
    if (this.batchImportId <= 0) {
      return;
    }
    this.batchPollTimer = setTimeout(() => {
      void this.pollBatchStatus();
    }, 2000);
  }

  private applyBatchItems(batchItems: Array<Record<string, Object>>): void {
    // 按文件名回写状态；同名时按队列顺序依次匹配
    const used: boolean[] = [];
    for (let i = 0; i < batchItems.length; i++) {
      used.push(false);
    }
    this.items = this.items.map((item: UploadItem) => {
      if (item.status !== ITEM_UPLOADING && item.status !== ITEM_PENDING) {
        return item;
      }
      let matchIdx = -1;
      for (let i = 0; i < batchItems.length; i++) {
        if (used[i]) {
          continue;
        }
        const bi = batchItems[i];
        const biName = String(bi['name'] ?? '');
        if (biName === item.name) {
          matchIdx = i;
          break;
        }
      }
      if (matchIdx < 0) {
        return item;
      }
      used[matchIdx] = true;
      const bi = batchItems[matchIdx];
      const st = String(bi['status'] ?? '');
      const bookId = Number(bi['book_id'] ?? 0);
      if (st === 'imported' || st === 'done' || st === 'success') {
        return {
          id: item.id, name: item.name, size: item.size, localPath: item.localPath,
          status: ITEM_SUCCESS, message: '上传成功', bookId: bookId, progressText: '',
          progress: 100,
        } as UploadItem;
      }
      // exist=同名同格式已存在；drop=重复文件（同一批次里已处理过/ISBN 已存在）
      if (st === 'exist' || st === 'drop') {
        return {
          id: item.id, name: item.name, size: item.size, localPath: item.localPath,
          status: ITEM_SUCCESS, message: st === 'exist' ? '已存在该格式' : '重复文件，已跳过',
          bookId: bookId, progressText: '', progress: 100,
        } as UploadItem;
      }
      if (st === 'invalid' || st === 'missed' || st === 'permission' || st === 'failed') {
        return {
          id: item.id, name: item.name, size: item.size, localPath: item.localPath,
          status: ITEM_FAILED, message: `导入失败：${st}`, bookId: bookId, progressText: '',
          progress: 0,
        } as UploadItem;
      }
      // 进行中 / 排队
      return {
        id: item.id, name: item.name, size: item.size, localPath: item.localPath,
        status: ITEM_UPLOADING, message: '', bookId: bookId,
        progressText: st.length > 0 ? st : '批量导入中',
        progress: item.progress,
      } as UploadItem;
    });
  }

  /** 批量导入进度后缀：已完成 x/y（服务端未返回明细时为空）。 */
  private batchProgress(batchItems: Array<Record<string, Object>>): string {
    if (batchItems.length === 0) {
      return '';
    }
    let done = 0;
    for (let i = 0; i < batchItems.length; i++) {
      const st = String(batchItems[i]['status'] ?? '');
      if (st === 'imported' || st === 'done' || st === 'success' || st === 'invalid' ||
        st === 'missed' || st === 'drop' || st === 'permission' || st === 'failed') {
        done++;
      }
    }
    return ` · 已完成 ${done}/${batchItems.length}`;
  }

  private sleepMs(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  private async pollBatchStatus(): Promise<void> {
    // 阻塞直到批量任务结束，再继续大文件分块，避免抢 uploading
    while (this.batchImportId > 0) {
      try {
        const rsp: UploadBatchStatusResponse =
          await TalebookApi.getUploadBatchStatus(this.batchImportId);
        if (rsp.err !== undefined && rsp.err !== 'ok') {
          this.batchHint = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : String(rsp.err);
          await this.sleepMs(2000);
          continue;
        }
        const batchItems = (rsp.items ?? []) as Array<Record<string, Object>>;
        this.applyBatchItems(batchItems);
        if (Boolean(rsp.importing)) {
          this.batchHint = `批量导入进行中（任务 ${this.batchImportId}）${this.batchProgress(batchItems)}`;
          await this.sleepMs(2000);
          continue;
        }
        this.stopBatchPoll();
        this.batchHint = '批量导入已结束';
        for (const item of this.items) {
          if (item.status === ITEM_SUCCESS && item.localPath.length > 0) {
            BookUploadService.removeStagedFile(item.localPath);
          }
          if (item.status === ITEM_UPLOADING) {
            this.patchItem(item.id, ITEM_FAILED, '未获取批量结果', 0, '');
          }
        }
        BookUploadService.markLibraryDirty();
        this.batchImportId = 0;
        return;
      } catch (e) {
        this.batchHint = `状态刷新失败：${e}`;
        if (this.batchImportId <= 0) {
          return;
        }
        await this.sleepMs(2000);
      }
    }
  }

  private cancelBatch(): void {
    if (this.batchImportId <= 0 || !this.uploading) {
      return;
    }
    const importId = this.batchImportId;
    TalebookApi.cancelUploadBatch(importId)
      .then((rsp) => {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已请求取消');
        this.stopBatchPoll();
        this.batchImportId = 0;
        this.batchHint = '';
        this.uploading = false;
        // 仍在上传中的标为失败
        for (const item of this.items) {
          if (item.status === ITEM_UPLOADING) {
            this.patchItem(item.id, ITEM_FAILED, '已取消', 0, '');
          }
        }
      })
      .catch((e: Object) => this.toast(`取消失败：${e}`));
  }

  private pendingCount(): number {
    return this.items.filter((item: UploadItem) => item.status === ITEM_PENDING ||
      item.status === ITEM_FAILED).length;
  }

  private async addFiles(): Promise<void> {
    if (this.uploading) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const result = await BookUploadService.pickBookFiles(context, 10);
      if (result.files.length > 0) {
        const added: UploadItem[] = result.files.map((file: PickedBookFile) => {
          const item: UploadItem = {
            id: this.nextItemId++,
            name: file.name,
            size: file.size,
            localPath: file.localPath,
            status: ITEM_PENDING,
            message: '',
            bookId: 0,
            progressText: '',
            progress: 0,
          };
          return item;
        });
        this.items = this.items.concat(added);
      }
      if (result.skipped.length > 0) {
        this.toast(`已跳过不支持的格式：${result.skipped.join('、')}`);
      } else if (result.files.length === 0) {
        this.toast('未选择文件');
      }
    } catch (e) {
      if (`${e}`.indexOf('cancel') < 0) {
        this.toast(`选择文件失败：${e}`);
      }
    }
  }

  private removeItem(id: number): void {
    if (this.uploading) {
      return;
    }
    const target = this.items.find((item: UploadItem) => item.id === id);
    if (target !== undefined && target.localPath.length > 0) {
      BookUploadService.removeStagedFile(target.localPath);
    }
    this.items = this.items.filter((item: UploadItem) => item.id !== id);
  }

  private patchItem(id: number, status: string, message: string, bookId: number,
    progressText: string = '', progress: number = 0): void {
    this.items = this.items.map((item: UploadItem) => {
      if (item.id !== id) {
        return item;
      }
      const patched: UploadItem = {
        id: item.id,
        name: item.name,
        size: item.size,
        localPath: item.localPath,
        status: status,
        message: message,
        bookId: bookId,
        progressText: progressText,
        progress: progress,
      };
      return patched;
    });
  }

  /** 仅更新进度，保留其余状态字段（分块上传时高频调用）。 */
  private patchProgress(id: number, progress: number): void {
    this.items = this.items.map((item: UploadItem) => {
      if (item.id !== id) {
        return item;
      }
      const patched: UploadItem = {
        id: item.id,
        name: item.name,
        size: item.size,
        localPath: item.localPath,
        status: item.status,
        message: item.message,
        bookId: item.bookId,
        progressText: item.progressText,
        progress: progress,
      };
      return patched;
    });
  }

  private async startUpload(): Promise<void> {
    if (this.uploading) {
      return;
    }
    if (this.pendingCount() === 0) {
      this.toast('没有待上传的文件');
      return;
    }
    if (!TalebookService.ensureTalebookConfigured()) {
      this.toast('请先配置 Talebook 服务器');
      return;
    }
    this.uploading = true;
    // 不在此处 await 登录校验：ensureTalebookConfigured() 已把服务端地址同步给
    // native（内部调用 syncBaseUrl），请求直接携带凭据发出。这样 startUpload
    // 在真正发起请求前没有任何 await，不存在卡死点。
    const queue = this.items.filter((item: UploadItem) => item.status === ITEM_PENDING ||
      item.status === ITEM_FAILED);

    // 大文件（>8MB）走分块；小文件走批量通道或单文件接口
    const chunkQueue: UploadItem[] = [];
    const smallQueue: UploadItem[] = [];
    for (const item of queue) {
      if (item.size > CHUNK_THRESHOLD) {
        chunkQueue.push(item);
      } else {
        smallQueue.push(item);
      }
    }
    this.batchHint = `正在上传 ${queue.length} 个文件…`;

    if (smallQueue.length > 0) {
      // 单个小文件直接走单文件接口：一次请求就能拿到 book_id，不必借道批量通道再轮询。
      // 多文件才尝试批量通道（那里会判断服务端是否支持、以及本次运行内是否已经失败过）。
      if (smallQueue.length === 1 || !(await this.tryBatchUpload(smallQueue))) {
        await this.uploadIndividually(smallQueue);
      }
    }

    for (const item of chunkQueue) {
      this.patchItem(item.id, ITEM_UPLOADING, '', 0, '');
      try {
        const chunkedOk = await this.uploadChunked(item);
        if (!chunkedOk) {
          // 分块通道失败时回退整包上传：部分服务端的 /api/book/upload/chunk 在导入「新书」时
          // 直接抛错（BookUploadChunk._add_new_book() takes 3 positional arguments but 4 were
          // given），分块对这类服务器永远传不上去，但整包 /api/book/upload 是好的。
          this.patchItem(item.id, ITEM_UPLOADING, '', 0, '分块失败，改为整包上传');
          await this.uploadIndividually([item]);
        }
      } catch (e) {
        this.patchItem(item.id, ITEM_FAILED, errorText(e), 0, '');
      }
    }

    this.uploading = false;
    this.reportResult(queue);
  }

  /** 批量通道不可用：只留一条中性提示（不弹错误、不显示服务端内部报错），并把失败原因写 hilog。
   * 调用方随即回退逐个上传 —— 那才是真正的结果来源，所以这里不该报「失败」吓用户。
   */
  private disableBatchChannel(reason: string): void {
    AppStorage.setOrCreate<boolean>(BATCH_UNAVAILABLE_KEY, true);
    hilog.warn(0x0000, TAG, 'batch channel unavailable, fallback to single upload: %{public}s', reason);
    this.batchHint = '服务端批量导入暂不可用，已自动改为逐个上传';
  }

  /**
   * 批量通道（POST /api/book/upload/batch，仅 MyBooks 提供）：服务端把文件暂存到扫描导入目录后
   * 异步扫描入库。该通道依赖服务端 scan_upload_path 可写，实测存在暂存就失败的部署（返回 internal
   * 「保存上传文件失败…」）；这类失败不作为错误提示，由调用方回退逐个上传。
   *
   * @returns true 表示批量通道已受理（含轮询到结束）；false 表示需要回退逐个上传。
   */
  private async tryBatchUpload(queue: UploadItem[]): Promise<boolean> {
    // 服务端不支持该端点、或本次运行内已经失败过：不再白跑一趟，直接走逐个上传
    if (!ServerRegistry.supports(ServerFeature.BATCH_UPLOAD) ||
      AppStorage.get<boolean>(BATCH_UNAVAILABLE_KEY) === true) {
      return false;
    }
    for (const item of queue) {
      this.patchItem(item.id, ITEM_UPLOADING, '', 0, '批量上传中');
    }
    let startRsp: UploadBatchStartResponse;
    try {
      const files: BatchUploadFile[] = queue.map((item: UploadItem) => {
        const f: BatchUploadFile = {
          localPath: item.localPath,
          name: item.name,
          relativePath: item.name,
        };
        return f;
      });
      startRsp = await TalebookApi.uploadBookBatch(files);
    } catch (e) {
      this.disableBatchChannel(errorText(e));
      return false;
    }
    if (startRsp.err !== undefined && startRsp.err !== 'ok') {
      const msg = apiErrorMessage(startRsp);
      this.disableBatchChannel(msg.length > 0 ? msg : `err=${startRsp.err}`);
      return false;
    }
    const importId = Number(startRsp.import_id ?? 0);
    if (importId > 0) {
      this.batchImportId = importId;
      this.batchHint = `已提交批量任务 ${importId}，共 ${Number(startRsp.file_count ?? queue.length)} 个文件`;
      // 轮询期间保持 uploading=true
      await this.pollBatchStatus();
      return true;
    }
    // 无 import_id：服务端按同步完成处理
    for (const item of queue) {
      this.patchItem(item.id, ITEM_SUCCESS, '', 0, '');
      BookUploadService.removeStagedFile(item.localPath);
    }
    BookUploadService.markLibraryDirty();
    return true;
  }

  /** 上传收尾汇总：成功不弹 Toast（每次上传都弹很吵），只有失败才提示。 */
  private reportResult(queue: UploadItem[]): void {
    let ok = 0;
    let failed = 0;
    for (const item of queue) {
      const cur = this.items.find((x: UploadItem) => x.id === item.id);
      if (cur === undefined) {
        continue;
      }
      if (cur.status === ITEM_SUCCESS) {
        ok++;
      } else if (cur.status === ITEM_FAILED) {
        failed++;
      }
    }
    if (failed > 0) {
      this.batchHint = `上传结束：成功 ${ok} 个，失败 ${failed} 个`;
      this.toast(`${failed} 个文件上传失败`);
    } else if (ok > 0) {
      this.batchHint = `上传完成：成功 ${ok} 个`;
    } else {
      this.batchHint = '';
    }
  }

  /** 逐个走单文件接口（POST /api/book/upload）上传：批量通道不可用时的正常路径，也是最终结果来源。 */
  private async uploadIndividually(queue: UploadItem[]): Promise<void> {
    for (let i = 0; i < queue.length; i++) {
      const item = queue[i];
      const cur = this.items.find((x: UploadItem) => x.id === item.id);
      if (cur === undefined) {
        continue;
      }
      if (cur.status !== ITEM_UPLOADING && cur.status !== ITEM_PENDING &&
        cur.status !== ITEM_FAILED) {
        continue;
      }
      // 多个文件时显示队列位置（上传中… 2/5），让用户知道还剩几个
      this.patchItem(item.id, ITEM_UPLOADING, '', 0, queue.length > 1 ? `${i + 1}/${queue.length}` : '');
      try {
        const rsp: UploadBookResponse = await TalebookApi.uploadBookFile(item.localPath, item.name);
        if (rsp.err === 'ok' || rsp.err === 'samebook') {
          // samebook：服务端已有同名同格式的书，属于「已上传」而不是失败
          this.patchItem(item.id, ITEM_SUCCESS, rsp.err === 'samebook' ? '已存在该格式' : '',
            Number(rsp.book_id ?? 0), '');
          BookUploadService.removeStagedFile(item.localPath);
          BookUploadService.markLibraryDirty();
        } else {
          const msg = apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '上传失败';
          this.patchItem(item.id, ITEM_FAILED, msg, Number(rsp.book_id ?? 0), '');
        }
      } catch (e) {
        this.patchItem(item.id, ITEM_FAILED, errorText(e), 0, '');
      }
    }
  }

  /** 条目状态文案（文件大小另外单独展示，不再混在一行里）。 */
  private statusWord(item: UploadItem): string {
    if (item.status === ITEM_UPLOADING) {
      return item.progressText.length > 0 ? `上传中… ${item.progressText}` : '上传中…';
    }
    if (item.status === ITEM_SUCCESS) {
      return '上传成功';
    }
    if (item.status === ITEM_FAILED) {
      return '失败';
    }
    return '待上传';
  }

  private statusColor(item: UploadItem): ResourceColor {
    if (item.status === ITEM_UPLOADING) {
      return $r('app.color.brand_primary');
    }
    if (item.status === ITEM_SUCCESS) {
      return $r('app.color.success');
    }
    if (item.status === ITEM_FAILED) {
      return $r('app.color.error');
    }
    return $r('app.color.text_secondary');
  }

  /** 状态图标底色：与文字色同色系的浅色块，避免用 Opacity/Clip 触发离屏合成。 */
  private statusBackground(item: UploadItem): ResourceColor {
    if (item.status === ITEM_SUCCESS) {
      return $r('app.color.success_light');
    }
    if (item.status === ITEM_FAILED) {
      return $r('app.color.error_light');
    }
    return $r('app.color.brand_primary_light');
  }

  private statusIcon(item: UploadItem): Resource {
    if (item.status === ITEM_SUCCESS) {
      return $r('sys.symbol.checkmark_circle_fill');
    }
    if (item.status === ITEM_FAILED) {
      return $r('sys.symbol.xmark');
    }
    return $r('sys.symbol.doc_text');
  }

  /** 顶部提示条配色：batchHint 是纯文本状态位，按文案判定失败/成功/其余。 */
  private hintTone(): string {
    if (this.batchHint.includes('失败') || this.batchHint.includes('错误')) {
      return 'error';
    }
    if (this.batchHint.includes('已提交') || this.batchHint.includes('完成')) {
      return 'success';
    }
    return 'info';
  }

  private hintBackground(): ResourceColor {
    const tone = this.hintTone();
    if (tone === 'error') {
      return $r('app.color.error_light');
    }
    if (tone === 'success') {
      return $r('app.color.success_light');
    }
    return $r('app.color.brand_primary_light');
  }

  private hintColor(): ResourceColor {
    const tone = this.hintTone();
    if (tone === 'error') {
      return $r('app.color.error');
    }
    if (tone === 'success') {
      return $r('app.color.success');
    }
    return $r('app.color.brand_primary');
  }

  /** 已选文件合计大小，用于列表标题行的「共 X」。 */
  private totalSizeText(): string {
    let bytes = 0;
    for (const item of this.items) {
      bytes += item.size;
    }
    return BookUploadService.formatSize(bytes);
  }

  @Builder
  hintBanner() {
    if (this.batchHint.length > 0) {
      Text(this.batchHint)
        .fontSize(12)
        .fontColor(this.hintColor())
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .borderRadius($r('app.float.chip_radius'))
        .backgroundColor(this.hintBackground())
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: 16, right: 16, top: 8 });
    }
  }

  /** 选择文件卡：空态与「继续添加」共用同一块，点击整卡即拉起系统文件选择器。 */
  @Builder
  pickCard() {
    Column({ space: 6 }) {
      Column() {
        SymbolGlyph($r('sys.symbol.arrowshape_turn_up_right'))
          .fontSize(26)
          .fontColor([$r('app.color.on_brand')]);
      }
      .width(56)
      .height(56)
      .justifyContent(FlexAlign.Center)
      .borderRadius(28)
      .backgroundColor($r('app.color.brand_primary'))
      .margin({ bottom: 6 });

      Text(this.items.length === 0 ? '选择书籍文件' : '继续添加文件')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'));
      Text('支持 EPUB / MOBI / AZW3 / TXT / PDF / DOCX，可多选')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'));
      Text('超过 8MB 的文件自动分块上传')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'));

      // 添加实体书（ISBN 联网查询）为 MyBooks 专有端点，talebook 上不显示该入口
      if (ServerRegistry.supports(ServerFeature.BOOK_ISBN_ADD)) {
        TextButton({
          label: '添加实体书（ISBN）',
          onTap: () => {
            this.isbnError = '';
            this.showIsbnSheet = true;
          },
        });
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 24, bottom: 16 })
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .border({
      width: 1,
      color: $r('app.color.divider'),
      radius: $r('app.float.card_radius'),
    })
    .onClick(() => {
      if (this.uploading) {
        return;
      }
      this.addFiles().catch((e: Object) => {
        this.toast(`选择文件失败：${e}`);
      });
    });
  }

  @Builder
  listHeader() {
    Row() {
      Text(this.uploading ? '上传中，请勿离开本页' : '已选文件')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'));
      Blank();
      Text(`${this.items.length} 个 · 共 ${this.totalSizeText()} · 待上传 ${this.pendingCount()}`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'));
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 6 });
  }

  @Builder
  itemMeta(item: UploadItem) {
    Text(item.name)
      .fontSize(15)
      .fontColor($r('app.color.text_primary'))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis });
    Row({ space: 8 }) {
      Text(this.statusWord(item))
        .fontSize(11)
        .fontColor(this.statusColor(item))
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        .borderRadius($r('app.float.badge_radius'))
        .backgroundColor(this.statusBackground(item));
      Text(BookUploadService.formatSize(item.size))
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'));
    };
    if (item.status === ITEM_UPLOADING && item.progress > 0) {
      Progress({ value: item.progress, total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(4)
        .color($r('app.color.brand_primary'))
        .backgroundColor($r('app.color.divider'));
    }
    // 只在文案能补充信息时展示（成功/待上传的状态词已经显示，避免重复一行「上传成功」）
    if (item.message.length > 0 && item.message !== this.statusWord(item)) {
      Text(item.message)
        .fontSize(12)
        .fontColor(item.status === ITEM_FAILED ? $r('app.color.error') : $r('app.color.text_secondary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
  }

  @Builder
  itemActions(item: UploadItem) {
    Row({ space: 4 }) {
      if (item.status === ITEM_SUCCESS || (item.status === ITEM_FAILED && item.bookId > 0)) {
        TextButton({
          label: '编辑元数据',
          onTap: () => this.getUIContext().getRouter().pushUrl({
            url: 'pages/BookEditPage',
            params: { bookId: item.bookId },
          }),
        });
        TextButton({
          label: '查看详情',
          onTap: () => this.getUIContext().getRouter().pushUrl({
            url: 'pages/BookDetailPage',
            params: { bookId: item.bookId },
          }),
        });
      }
      if (!this.uploading && (item.status === ITEM_PENDING || item.status === ITEM_FAILED)) {
        TextButton({
          label: '移除',
          tone: 'danger',
          onTap: () => this.removeItem(item.id),
        });
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.End);
  }

  @Builder
  uploadContent() {
    Column() {
      this.hintBanner();
      Column({ space: 10 }) {
        this.pickCard();
        if (this.items.length > 0) {
          this.listHeader();
          List({ space: 8 }) {
            ForEach(this.items, (item: UploadItem) => {
              ListItem() {
                Column({ space: 6 }) {
                  Row({ space: 12 }) {
                    Column() {
                      SymbolGlyph(this.statusIcon(item))
                        .fontSize(20)
                        .fontColor([this.statusColor(item)]);
                    }
                    .width(36)
                    .height(36)
                    .justifyContent(FlexAlign.Center)
                    .borderRadius(18)
                    .backgroundColor(this.statusBackground(item));

                    Column({ space: 4 }) {
                      this.itemMeta(item);
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1);
                  }
                  .width('100%');

                  this.itemActions(item);
                }
                .width('100%')
                .padding($r('app.float.card_padding'))
                .borderRadius($r('app.float.card_radius'))
                .backgroundColor($r('app.color.card_background'));
              }
            }, (item: UploadItem) =>
            `upload-${item.id}-${item.status}-${item.progress}-${item.progressText}-${item.message}`);
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ bottom: 8 });
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8 });
    }
    .width('100%')
    .height('100%');
  }

  build() {
    Column() {
      PageScaffold({
        title: '上传图书',
        showBack: true,
        content: () => {
          this.uploadContent();
        },
      })
        .layoutWeight(1);
      Column({ space: 8 }) {
        if (this.batchImportId > 0 && this.uploading) {
          SecondaryButton({
            label: '取消批量导入',
            buttonEnabled: true,
            onTap: () => this.cancelBatch(),
          });
        }
        PrimaryButton({
          label: this.uploading
            ? (this.batchImportId > 0 ? '批量导入中…' : '上传中…')
            : `开始上传（待上传 ${this.pendingCount()}）`,
          buttonEnabled: !this.uploading && this.pendingCount() > 0,
          onTap: () => {
            this.startUpload().catch((e: Object) => {
              // 未捕获的话异常会被静默吞掉：表现为无流量、无报错、无进度
              this.uploading = false;
              this.toast(`上传启动失败：${e}`);
            });
          },
        });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 16 });
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showIsbnSheet, this.isbnSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      title: { title: '添加实体书' },
    });
  }

  @Builder
  isbnSheet() {
    Column({ space: 12 }) {
      Text('输入图书 ISBN 号，服务器将联网查询并添加为实体书')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      TextInput({ text: this.isbnInput, placeholder: '如 9787115428028' })
        .type(InputType.Number)
        .maxLength(17)
        .width('100%')
        .height(42)
        .onChange((value: string) => {
          this.isbnInput = value;
          this.isbnError = '';
        });
      if (this.isbnError.length > 0) {
        Text(this.isbnError)
          .fontSize(13)
          .fontColor($r('app.color.error'))
          .width('100%');
      }
      // 条码识别端点（/api/admin/barcode）只有 MyBooks 提供
      if (ServerRegistry.supports(ServerFeature.ADMIN_BARCODE)) {
        SecondaryButton({
          label: this.scanningBarcode ? '正在识别…' : '扫描条码识别 ISBN',
          buttonEnabled: !this.scanningBarcode && !this.addingBook,
          onTap: () => {
            this.scanBarcode().catch((e: Object) => {
              this.toast(`扫码失败：${e}`);
            });
          },
        });
      }
      PrimaryButton({
        label: this.addingBook ? '正在添加…' : '联网查询并添加',
        buttonEnabled: !this.addingBook && !this.scanningBarcode,
        onTap: () => {
          this.addByIsbn().catch((e: Object) => {
            this.toast(`添加失败：${e}`);
          });
        },
      });
    }
    .width('100%')
    .padding($r('app.float.page_padding'));
  }
}
