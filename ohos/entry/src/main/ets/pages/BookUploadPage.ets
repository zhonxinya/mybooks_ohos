import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
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
    this.getUIContext().getPromptAction().showToast({ message: message });
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
        router.pushUrl({ url: 'pages/BookDetailPage', params: { bookId: bookId } });
      }
    } catch (e) {
      this.isbnError = `添加失败：${e}`;
    } finally {
      this.addingBook = false;
    }
  }

  /** 选择条码图片 -> 服务端识别 ISBN -> 回填输入框（POST /api/admin/barcode）。 */
  private async scanBarcode(): Promise<void> {
    if (this.scanningBarcode) {
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
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

  /** 大文件分块上传：逐块写临时文件后上传，服务端收齐后自动合并导入。
   *  已上传的分块保留在缓存目录，中断后再次上传会先重传缺失分块（断点续传）。
   */
  private async uploadChunked(item: UploadItem): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
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
        if (fs.accessSync(chunkPath)) {
          // 该分块之前已上传成功，跳过（断点续传）
          continue;
        }
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
        const rsp: UploadBookResponse = await TalebookApi.uploadBookChunk(chunkPath, item.name,
          i, totalChunks, hash);
        if (rsp.err !== 'ok') {
          const msg = apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '分块上传失败';
          this.patchItem(item.id, ITEM_FAILED, msg, Number(rsp.book_id ?? 0), '');
          return;
        }
      }
      // 收齐分块后服务端在最后一个分块请求中完成合并导入并返回 book_id
      this.patchItem(item.id, ITEM_SUCCESS, '上传成功', 0, '');
      BookUploadService.removeStagedFile(item.localPath);
      BookUploadService.markLibraryDirty();
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
      if (st === 'invalid' || st === 'missed' || st === 'drop' || st === 'permission' || st === 'failed') {
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
    const context = getContext(this) as common.UIAbilityContext;
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
    // 诊断：batchHint 在页面常驻渲染，用它可以精确定位流程停在哪一步
    this.batchHint = '① 已触发上传';
    if (this.uploading) {
      this.batchHint = '② 已在上传中，忽略本次点击';
      return;
    }
    if (this.pendingCount() === 0) {
      this.batchHint = '② 没有待上传的文件';
      this.toast('没有待上传的文件');
      return;
    }
    if (!TalebookService.ensureTalebookConfigured()) {
      this.batchHint = '② 服务器未配置';
      this.toast('请先配置 Talebook 服务器');
      return;
    }
    this.batchHint = '③ 前置检查通过，正在上传…';
    this.uploading = true;
    // 不在此处 await 登录校验：ensureTalebookConfigured() 已把服务端地址同步给
    // native（内部调用 syncBaseUrl），请求直接携带凭据发出。这样 startUpload
    // 在真正发起请求前没有任何 await，不存在卡死点。
    const queue = this.items.filter((item: UploadItem) => item.status === ITEM_PENDING ||
      item.status === ITEM_FAILED);

    // 大文件仍走分块；小文件优先批量接口（需 native 重建后 uploadBookBatch 才可用）
    const largeQueue: UploadItem[] = [];
    const smallQueue: UploadItem[] = [];
    for (const item of queue) {
      // 当前服务端不支持批量上传时，全部改走分片上传通道
      if (item.size > CHUNK_THRESHOLD || !ServerRegistry.supports(ServerFeature.BATCH_UPLOAD)) {
        largeQueue.push(item);
      } else {
        smallQueue.push(item);
      }
    }
    this.batchHint = `⑥ 通道就绪，小文件 ${smallQueue.length} 个、大文件 ${largeQueue.length} 个`;

    if (smallQueue.length > 0) {
      for (const item of smallQueue) {
        this.patchItem(item.id, ITEM_UPLOADING, '', 0, '批量上传中');
      }
      try {
        const files: BatchUploadFile[] = smallQueue.map((item: UploadItem) => {
          const f: BatchUploadFile = {
            localPath: item.localPath,
            name: item.name,
            relativePath: item.name,
          };
          return f;
        });
        const startRsp: UploadBatchStartResponse = await TalebookApi.uploadBookBatch(files);
        if (startRsp.err !== undefined && startRsp.err !== 'ok') {
          // 服务端返回业务错误时透传其 msg 原文（如"服务器扫描导入目录未配置"）
          const msg = apiErrorMessage(startRsp).length > 0 ? apiErrorMessage(startRsp) : '批量上传失败';
          this.batchHint = `批量上传失败：${msg}`;
          this.toast(msg);
          for (const item of smallQueue) {
            this.patchItem(item.id, ITEM_FAILED, msg, 0, '');
          }
        } else {
          const importId = Number(startRsp.import_id ?? 0);
          if (importId > 0) {
            this.batchImportId = importId;
            this.batchHint = `已提交批量任务 ${importId}，共 ${Number(startRsp.file_count ?? smallQueue.length)} 个文件`;
            // 轮询期间保持 uploading=true
            await this.pollBatchStatus();
          } else {
            // 无 import_id：视为同步完成
            for (const item of smallQueue) {
              this.patchItem(item.id, ITEM_SUCCESS, '上传成功', 0, '');
              BookUploadService.removeStagedFile(item.localPath);
            }
            BookUploadService.markLibraryDirty();
          }
        }
      } catch (e) {
        // 批量接口失败：透传原因，再回退逐个 uploadBookFile
        const reason = errorText(e);
        this.batchHint = `批量接口不可用，回退单文件上传：${reason}`;
        this.toast(`批量上传失败，正在逐个重试：${reason}`);
        for (const item of smallQueue) {
          const cur = this.items.find((x: UploadItem) => x.id === item.id);
          if (cur === undefined) {
            continue;
          }
          if (cur.status !== ITEM_UPLOADING && cur.status !== ITEM_PENDING &&
            cur.status !== ITEM_FAILED) {
            continue;
          }
          this.patchItem(item.id, ITEM_UPLOADING, '', 0, '');
          try {
            const rsp: UploadBookResponse = await TalebookApi.uploadBookFile(item.localPath, item.name);
            if (rsp.err === 'ok') {
              this.patchItem(item.id, ITEM_SUCCESS, '上传成功', Number(rsp.book_id ?? 0), '');
              BookUploadService.removeStagedFile(item.localPath);
              BookUploadService.markLibraryDirty();
            } else {
              const msg = apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '上传失败';
              this.patchItem(item.id, ITEM_FAILED, msg, Number(rsp.book_id ?? 0), '');
            }
          } catch (e2) {
            this.patchItem(item.id, ITEM_FAILED, errorText(e2), 0, '');
          }
        }
      }
    }

    for (const item of largeQueue) {
      this.patchItem(item.id, ITEM_UPLOADING, '', 0, '');
      try {
        await this.uploadChunked(item);
      } catch (e) {
        this.patchItem(item.id, ITEM_FAILED, errorText(e), 0, '');
      }
    }

    this.uploading = false;
  }

  private statusLabel(item: UploadItem): string {
    if (item.status === ITEM_UPLOADING) {
      return item.progressText.length > 0 ? `上传中… ${item.progressText}` : '上传中…';
    }
    if (item.status === ITEM_SUCCESS) {
      return '上传成功';
    }
    if (item.status === ITEM_FAILED) {
      return '失败';
    }
    return BookUploadService.formatSize(item.size);
  }

  private statusColor(item: UploadItem): ResourceColor {
    if (item.status === ITEM_UPLOADING) {
      return $r('app.color.text_secondary');
    }
    if (item.status === ITEM_SUCCESS) {
      return $r('app.color.success');
    }
    if (item.status === ITEM_FAILED) {
      return $r('app.color.error');
    }
    return $r('app.color.text_secondary');
  }

  @Builder
  itemMeta(item: UploadItem) {
    Text(item.name)
      .fontSize(15)
      .fontColor($r('app.color.text_primary'))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis });
    Text(this.statusLabel(item))
      .fontSize(12)
      .fontColor(this.statusColor(item))
      .maxLines(1);
    if (item.status === ITEM_UPLOADING && item.progress > 0) {
      Progress({ value: item.progress, total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(4)
        .color($r('app.color.brand_primary'))
        .backgroundColor($r('app.color.divider'));
    }
    if (item.message.length > 0) {
      Text(item.message)
        .fontSize(12)
        .fontColor($r('app.color.error'))
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
          onTap: () => router.pushUrl({
            url: 'pages/BookEditPage',
            params: { bookId: item.bookId },
          }),
        });
        TextButton({
          label: '查看详情',
          onTap: () => router.pushUrl({
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
  }

  @Builder
  uploadContent() {
    Column() {
      if (this.batchHint.length > 0) {
        Text(this.batchHint)
          .fontSize(12)
          .fontColor($r('app.color.on_brand'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 4 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      Row({ space: 8 }) {
        Text(this.uploading
          ? (this.batchImportId > 0 ? '批量导入中，可取消或等待完成' : '正在上传，请勿离开本页')
          : '小文件走批量上传；超过 8MB 仍分块上传')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        TextButton({
          label: '添加实体书',
          onTap: () => {
            this.isbnError = '';
            this.showIsbnSheet = true;
          },
        });
        TextButton({
          label: '选择文件',
          onTap: () => {
            this.addFiles().catch((e: Object) => {
              this.toast(`选择文件失败：${e}`);
            });
          },
        });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 });

      if (this.items.length === 0) {
        Column({ space: 12 }) {
          Text('📚')
            .fontSize(48);
          Text('还没有选择书籍文件')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'));
        }
        .width('100%')
        .padding({ top: 80 })
      } else {
        List({ space: 8 }) {
          ForEach(this.items, (item: UploadItem) => {
            ListItem() {
              Row({ space: 10 }) {
                Column({ space: 3 }) {
                  this.itemMeta(item);
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1);
                this.itemActions(item);
              }
              .width('100%')
              .padding(12)
              .borderRadius($r('app.float.card_radius'))
              .backgroundColor($r('app.color.card_background'));
            }
          }, (item: UploadItem) => `upload-${item.id}`);
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16 });
      }
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
      SecondaryButton({
        label: this.scanningBarcode ? '正在识别…' : '扫描条码识别 ISBN',
        buttonEnabled: !this.scanningBarcode && !this.addingBook,
        onTap: () => {
          this.scanBarcode().catch((e: Object) => {
            this.toast(`扫码失败：${e}`);
          });
        },
      });
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
