import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { PageScaffold, PrimaryButton, SecondaryButton, LoadingState, SettingCell, AuthImage, ChipButton, StarRating, SectionTitle } from '../components';
import { DownloadTask, TalebookService } from '../services/TalebookService';
import { ReaderLauncher, ReaderOpenParams } from '../services/ReaderLauncher';
import { TalebookApi, ApiMessageResult, apiErrorMessage } from '../services/TalebookApi';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { AccountManager } from '../services/AccountManager';
import { BookListApi } from '../services/BookListApi';
import { BookListQuickItem, booklistColorHex, parseBookListQuickItems } from '../models/BookListModels';
import { BookReviewItem, BookSocialStats } from '../models/BookReviewModels';
import { FormatReadingStat, ReadingDevice, deviceTypeLabel, formatStatDuration } from '../models/DeviceModels';
import { BookUploadService } from '../services/BookUploadService';
import { DownloadTaskService } from '../services/DownloadTaskService';
import { BookshelfRefresh } from '../utils/BookshelfRefresh';

interface BookFileFormat {
  format: string;
  size: number;
}

const PUSH_DEVICE_TYPES: string[] = [
  'kindle', 'duokan', 'ireader', 'hanwang', 'boox', 'dangdang', 'purelibro', 'ftp', 'koreader',
];

interface BookDetailSuggestion {
  id: number;
  title: string;
  cover: string;
}

@Entry
@Component
struct BookDetailPage {
  @State bookId: number = 0;
  @State title: string = '';
  @State author: string = '';
  @State authors: string[] = [];
  @State publisher: string = '';
  @State series: string = '';
  @State rating: string = '';
  @State tags: string[] = [];
  @State cover: string = '';
  @State description: string = '';
  @State loading: boolean = true;
  @State errorMessage: string = '';
  @State localFilePath: string = '';
  @State localFormat: string = '';
  @State localOnly: boolean = false;
  @State localBookId: string = '';
  @State isFavorite: boolean = false;
  @State formats: BookFileFormat[] = [];
  @State selectedFormat: string = '';
  @State downloadMessage: string = '';
  @State readEnabled: boolean = false;
  @State downloading: boolean = false;
  @StorageProp('downloadTasksTick') @Watch('onDownloadTasksChanged') downloadTasksTick: number = 0;
  @State activeSheet: string = '';
  @State showSheet: boolean = false;
  @State booklistItems: BookListQuickItem[] = [];
  @State booklistLoading: boolean = false;
  @State newBooklistName: string = '';
  @State readState: number = 0;
  @State socialStats: BookSocialStats | null = null;
  @State reviews: BookReviewItem[] = [];
  @State translator: string = '';
  @State isbn: string = '';
  @State extLink: string = '';
  @State reviewStars: number = 0;
  @State reviewComment: string = '';
  @State ownReview: BookReviewItem | null = null;
  @State submittingReview: boolean = false;
  @State isWants: boolean = false;
  @State formatStats: FormatReadingStat[] = [];
  @State suggestions: BookDetailSuggestion[] = [];
  @State sameTitleBooks: BookDetailSuggestion[] = [];
  @State devices: ReadingDevice[] = [];
  @State pushMailbox: string = '';
  @State pushDeviceType: string = 'kindle';
  @State pushDeviceUrl: string = '';
  @State pushFtpUsername: string = '';
  @State pushFtpPassword: string = '';
  @State pushFtpPath: string = '';
  @State pushing: boolean = false;
  @State mailAddress: string = '';
  @State mailFormat: string = '';
  @State sendingMail: boolean = false;
  @State aiFilling: boolean = false;
  @State formatBusy: boolean = false;
  @State manageFormat: string = '';
  @State coverBusy: boolean = false;
  @State deleteBusy: boolean = false;
  @State isSole: boolean = false;
  /** 本页入队的下载任务 id，用于精准跟踪该任务的进度。 */
  private downloadTaskId: string = '';

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    this.bookId = Number(params['bookId'] ?? 0);
    this.localOnly = Boolean(params['localOnly'] ?? false);
    this.localFilePath = String(params['filePath'] ?? '');
    this.localFormat = String(params['format'] ?? '');
    this.localBookId = String(params['localBookId'] ?? '');
    this.title = String(params['title'] ?? '');
    this.refreshReadEnabled();
    if (this.localOnly) {
      this.loading = false;
      return;
    }
    void this.loadDetail();
  }

  onPageShow(): void {
    // 从其他页面返回时同步本地文件与队列状态，避免按钮停留在旧状态
    if (this.bookId <= 0) {
      return;
    }
    this.syncLocalFileFromDownloads();
    this.refreshReadEnabled();
    this.syncDownloadState();
  }

  private async loadDetail(): Promise<void> {
    this.loading = true;
    this.errorMessage = '';
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.errorMessage = '请先配置 Talebook 服务器';
        return;
      }
      if (TalebookService.hasAuthCredentials()) {
        await TalebookService.ensureAuthenticated();
      }
      const envelope = await TalebookService.getBookDetailAsync(this.bookId);
      if (!TalebookService.isApiSuccess(envelope)) {
        this.errorMessage = envelope.error.length > 0 ? envelope.error : '加载失败';
        return;
      }
      const body = envelope.body ?? {};
      const book = (body['book'] as Record<string, Object> | undefined) ?? body;
      this.title = String(book['title'] ?? this.title);
      this.authors = this.parseAuthors(book);
      this.author = this.authors.join('、');
      this.publisher = String(book['publisher'] ?? '');
      this.series = String(book['series'] ?? '');
      const ratingValue = book['rating'];
      this.rating = ratingValue !== null && ratingValue !== undefined ? String(ratingValue) : '';
      const tagList = (book['tags'] as string[] | undefined) ?? [];
      if (tagList.length > 0) {
        this.tags = tagList.filter((tag) => tag.length > 0);
      } else {
        const tagText = String(book['tag'] ?? '');
        this.tags = tagText.length > 0 ?
          tagText.split('/').map((part) => part.trim()).filter((part) => part.length > 0) : [];
      }
      const rawCover = String(book['cover'] ?? book['cover_url'] ?? book['img'] ?? '');
      this.cover = TalebookService.resolveCoverUrl(rawCover);
      this.description = String(book['description'] ?? book['comments'] ?? '');
      this.isSole = Boolean(book['sole'] ?? false);

      const state = book['state'] as Record<string, Object> | undefined;
      if (state !== undefined) {
        this.isFavorite = Number(state['favorite'] ?? 0) > 0;
        this.readState = Number(state['read_state'] ?? 0);
        this.isWants = Number(state['wants'] ?? 0) > 0;
      }
      const translator = String(book['translator'] ?? '');
      if (translator.length > 0) {
        this.translator = translator;
      }
      const isbn = String(book['isbn'] ?? '');
      if (isbn.length > 0) {
        this.isbn = isbn;
      }
      const extLink = String(book['ext_link'] ?? '');
      if (extLink.length > 0) {
        this.extLink = extLink;
      }

      const files = book['files'] as Record<string, Object>[] | undefined;
      if (files !== undefined && files.length > 0) {
        const parsed: BookFileFormat[] = [];
        for (let i = 0; i < files.length; i++) {
          const file = files[i];
          const format = String(file['format'] ?? '').toUpperCase();
          if (format.length > 0) {
            parsed.push({ format: format, size: Number(file['size'] ?? 0) });
          }
        }
        this.formats = parsed;
        this.selectedFormat = this.pickDefaultFormat(this.formats);
      }

      const downloads = TalebookService.getDownloads();
      const local = downloads.find((item) => item.bookId === `${this.bookId}`);
      if (local?.filePath !== undefined && local.filePath.length > 0) {
        this.localFilePath = local.filePath;
        this.localFormat = local.format ?? this.selectedFormat;
      }
      this.refreshReadEnabled();
      this.loadSocialData();
    } catch (error) {
      this.errorMessage = `${error}`;
    } finally {
      this.loading = false;
    }
  }

  private parseAuthors(book: Record<string, Object>): string[] {
    const authorsList = (book['authors'] as string[] | undefined) ?? [];
    if (authorsList.length > 0) {
      return authorsList.map((name) => name.trim()).filter((name) => name.length > 0);
    }
    const authorSort = String(book['author_sort'] ?? '');
    const source = authorSort.length > 0 ? authorSort : String(book['author'] ?? '');
    if (source.length === 0) {
      return [];
    }
    return source.split(/[,，、/]/).map((part) => part.trim()).filter((part) => part.length > 0);
  }

  private pickDefaultFormat(items: BookFileFormat[]): string {
    const preferred = ['EPUB', 'PDF', 'MOBI', 'AZW3', 'AZW', 'TXT'];
    for (const format of preferred) {
      if (items.some((item) => item.format === format)) {
        return format;
      }
    }
    return items.length > 0 ? items[0].format : 'EPUB';
  }

  private plainDescription(): string {
    if (this.description.length === 0) {
      return '';
    }
    return this.description
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<\/p>/gi, '\n')
      .replace(/<[^>]+>/g, '')
      .replace(/&nbsp;/g, ' ')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
  }

  private resolveReadLocation(): string {
    const bookKey = this.localBookId.length > 0 ? this.localBookId : `${this.bookId}`;
    return TalebookService.resolveSavedLocation(bookKey, this.localFilePath);
  }

  private fileExists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (_error) {
      return false;
    }
  }

  private hasLocalFile(): boolean {
    return this.readEnabled;
  }

  private refreshReadEnabled(): void {
    this.readEnabled = this.localFilePath.length > 0 && this.fileExists(this.localFilePath);
    this.downloading = this.hasActiveDownload();
  }

  /** 本书是否已在下载队列中（排队/下载中），用于按钮置灰。 */
  private hasActiveDownload(): boolean {
    const bookId = `${this.bookId}`;
    const tasks = DownloadTaskService.getTasks();
    for (let i = 0; i < tasks.length; i++) {
      const task = tasks[i];
      if (task.bookId === bookId && (task.status === 'pending' || task.status === 'downloading')) {
        return true;
      }
    }
    return false;
  }

  /** 已下载记录里若含本书，则回填本地文件路径（下载完成后按钮要变成「开始阅读」）。 */
  private syncLocalFileFromDownloads(): void {
    const local = TalebookService.getDownloads().find((item) => item.bookId === `${this.bookId}`);
    if (local?.filePath !== undefined && local.filePath.length > 0) {
      this.localFilePath = local.filePath;
      this.localFormat = local.format ?? this.localFormat;
    }
  }

  private onDownloadTasksChanged(): void {
    this.syncDownloadState();
  }

  /**
   * 详情页下载不跳转下载管理，改为就地反映队列状态：
   * 优先跟踪本页入队的任务，其次回退到本书仍在进行中的任务。
   */
  private findDownloadTask(): DownloadTask | undefined {
    const tasks = DownloadTaskService.getTasks();
    if (this.downloadTaskId.length > 0) {
      return tasks.find((task: DownloadTask) => task.id === this.downloadTaskId);
    }
    const bookId = `${this.bookId}`;
    return tasks.find((task: DownloadTask) =>
      task.kind === 'talebook' && task.bookId === bookId &&
      (task.status === 'pending' || task.status === 'downloading'));
  }

  private syncDownloadState(): void {
    const task = this.findDownloadTask();
    if (task === undefined) {
      return;
    }
    if (task.status === 'completed') {
      this.downloading = false;
      this.downloadMessage = '下载完成';
      this.syncLocalFileFromDownloads();
      this.refreshReadEnabled();
      return;
    }
    if (task.status === 'failed') {
      this.downloading = false;
      this.downloadMessage = task.error.length > 0 ? task.error : '下载失败，可在「下载管理」重试';
      return;
    }
    this.downloading = true;
    this.downloadMessage = task.status === 'downloading'
      ? (task.message.length > 0 ? task.message : '正在下载中')
      : '已加入下载队列';
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private openMetaBooks(metaType: string, metaName: string): void {
    if (metaName.length === 0) {
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/BookListPage',
      params: { type: 'meta', metaType: metaType, metaName: metaName },
    });
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  /** 上传本地文件作为本书的新格式（bid 指向当前书籍） */
  private async pickAndUploadFormat(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const result = await BookUploadService.pickBookFiles(context, 1);
      if (result.files.length === 0) {
        if (result.skipped.length > 0) {
          this.toast(`不支持的格式：${result.skipped.join('、')}`);
        }
        return;
      }
      const file = result.files[0];
      const authed = await TalebookService.ensureAuthenticated();
      if (!authed) {
        this.toast('登录已失效，请重新登录后再上传');
        return;
      }
      this.toast('正在上传新格式…');
      const rsp = await TalebookApi.uploadBookFile(file.localPath, file.name, this.bookId);
      BookUploadService.removeStagedFile(file.localPath);
      if (rsp.err === 'ok') {
        BookUploadService.markLibraryDirty();
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '格式添加成功');
        await this.loadDetail();
      } else {
        this.toast(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '上传失败');
      }
    } catch (e) {
      this.toast(`上传失败：${e}`);
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private enqueueDownload(): void {
    if (this.selectedFormat.length === 0 || this.downloading) {
      return;
    }
    // 立即置灰，避免重复入队
    this.downloading = true;
    if (!ServerRegistry.supports(ServerFeature.DOWNLOAD_QUOTA)) {
      this.doEnqueueDownload();
      return;
    }
    TalebookApi.getDownloadQuota()
      .then((quota) => {
        if (quota.allowed === false) {
          this.downloading = false;
          this.toast(`今日下载配额已用完（${quota.used ?? 0}/${quota.quota ?? 0}），明天再试吧`);
          return;
        }
        this.doEnqueueDownload();
      })
      .catch(() => this.doEnqueueDownload());
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private doEnqueueDownload(): void {
    if (this.selectedFormat.length === 0) {
      this.downloading = false;
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const booksDir = AccountManager.booksDir(context.filesDir);
    try {
      if (!fs.accessSync(booksDir)) {
        fs.mkdirSync(booksDir, true);
      }
    } catch (_error) {
      fs.mkdirSync(booksDir, true);
    }
    const destPath = `${booksDir}/${this.bookId}.${this.selectedFormat.toLowerCase()}`;
    const task = DownloadTaskService.enqueueTalebook({
      bookId: this.bookId,
      bookName: this.title,
      author: this.author,
      cover: this.cover,
      format: this.selectedFormat,
      destPath: destPath,
    });
    this.downloadTaskId = task.id;
    DownloadTaskService.processQueue();
    this.downloadMessage = '已加入下载队列';
    this.getUIContext().getPromptAction().showToast({ message: '已加入下载队列，可继续浏览' });
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private openReader(): void {
    const filePath = this.localFilePath;
    if (!this.hasLocalFile()) {
      this.getUIContext().getPromptAction().showToast({ message: '请先下载书籍' });
      return;
    }
    // 设备缺 ReaderKit 时不能路由（会 cppcrash），改由守卫提示
    const readerParams: ReaderOpenParams = {
      filePath: filePath,
      bookId: this.localBookId.length > 0 ? this.localBookId : `${this.bookId}`,
      bookTitle: this.title,
      format: this.localFormat.length > 0 ? this.localFormat : this.selectedFormat,
      location: this.resolveReadLocation(),
    };
    const opened: boolean = ReaderLauncher.open(this.getUIContext(), readerParams);
    if (!opened) {
      this.getUIContext().getPromptAction().showToast({ message: ReaderLauncher.UNAVAILABLE_MESSAGE });
    }
  }

  private async loadSocialData(): Promise<void> {
    if (this.localOnly || this.bookId <= 0) {
      return;
    }
    if (ServerRegistry.supports(ServerFeature.BOOK_SOCIAL_STATS)) {
      try {
        const stats = await TalebookApi.getSocialStats(this.bookId);
        this.socialStats = stats;
      } catch (_error) {
        this.socialStats = null;
      }
    }
    if (ServerRegistry.supports(ServerFeature.BOOK_REVIEWS)) {
      try {
        this.reviews = await TalebookApi.getBookReviews(this.bookId);
      } catch (_error) {
        this.reviews = [];
      }
    }
    this.loadExtraData();
  }

  /** 每格式阅读统计 + 同类推荐/同名图书（服务端不支持的能力不发起请求，失败静默）。 */
  private loadExtraData(): void {
    if (ServerRegistry.supports(ServerFeature.BOOK_FORMAT_STATS)) {
      TalebookApi.getFormatReadingStats(this.bookId)
        .then((stats: FormatReadingStat[]) => {
          this.formatStats = stats;
        })
        .catch(() => {
          this.formatStats = [];
        });
    }
    if (ServerRegistry.supports(ServerFeature.BOOK_SUGGESTION)) {
      TalebookApi.getBookSuggestions(this.bookId)
        .then((items) => {
          this.suggestions = items.slice(0, 12).map((item): BookDetailSuggestion => ({
            id: item.id,
            title: item.title,
            cover: TalebookService.resolveCoverUrl(item.coverUrl),
          }));
        })
        .catch(() => {
          this.suggestions = [];
        });
      if (this.title.length > 0) {
        TalebookApi.searchSameTitleBooks(this.title, this.bookId)
          .then((items) => {
            this.sameTitleBooks = items.slice(0, 12).map((item): BookDetailSuggestion => ({
              id: item.id,
              title: item.title,
              cover: TalebookService.resolveCoverUrl(item.coverUrl),
            }));
          })
          .catch(() => {
            this.sameTitleBooks = [];
          });
      }
    }
  }

  private async toggleWants(): Promise<void> {
    const next = !this.isWants;
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.setWants(this.bookId, next);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp));
        return;
      }
      this.isWants = next;
      this.toast(next ? '已加入想读' : '已取消想读');
      this.loadSocialData();
    } catch (error) {
      this.toast(`操作失败：${error}`);
    }
  }

  private async aiFill(): Promise<void> {
    if (this.aiFilling) {
      return;
    }
    this.aiFilling = true;
    this.toast('正在 AI 补全元数据…');
    try {
      const rsp = await TalebookApi.aiFillBook(this.bookId);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp));
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : 'AI 更新成功');
      await this.loadDetail();
    } catch (error) {
      this.toast(`AI 补全失败：${error}`);
    } finally {
      this.aiFilling = false;
    }
  }

  private openSheet(name: string): void {
    this.activeSheet = name;
    this.showSheet = true;
  }

  private closeSheet(): void {
    this.showSheet = false;
  }

  private async openPushSheet(): Promise<void> {
    this.openSheet('push');
    try {
      await TalebookService.ensureAuthenticated();
      this.devices = await TalebookApi.getUserDevices();
      const kindle = this.devices.find((device: ReadingDevice) => device.type === 'kindle');
      if (kindle !== undefined && this.pushMailbox.length === 0) {
        this.pushMailbox = kindle.mailbox;
        this.pushDeviceType = 'kindle';
      }
    } catch (_error) {
      this.devices = [];
    }
  }

  private async pushToDevice(): Promise<void> {
    if (this.pushing) {
      return;
    }
    const type = this.pushDeviceType;
    if (type === 'kindle' && this.pushMailbox.trim().length === 0) {
      this.toast('请输入 Kindle 邮箱');
      return;
    }
    if (type === 'ftp') {
      if (this.pushDeviceUrl.trim().length === 0) {
        this.toast('请输入 FTP 地址');
        return;
      }
      if (this.pushFtpPath.trim().length === 0) {
        this.toast('请输入 FTP 路径');
        return;
      }
    } else if (type !== 'kindle' && this.pushDeviceUrl.trim().length === 0) {
      this.toast('请输入设备地址');
      return;
    }
    this.pushing = true;
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.sendToDevice(this.bookId, type, this.pushDeviceUrl.trim(),
        this.pushMailbox.trim(), this.pushFtpUsername.trim(), this.pushFtpPassword,
        this.pushFtpPath.trim());
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp));
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '推送成功');
      this.closeSheet();
    } catch (error) {
      this.toast(`推送失败：${error}`);
    } finally {
      this.pushing = false;
    }
  }

  private async openMailSheet(): Promise<void> {
    this.mailFormat = this.selectedFormat.length > 0 ? this.selectedFormat.toLowerCase() : '';
    this.openSheet('mail');
  }

  private async sendMail(): Promise<void> {
    const email = this.mailAddress.trim();
    if (email.length === 0) {
      this.toast('请输入邮箱地址');
      return;
    }
    if (this.sendingMail) {
      return;
    }
    this.sendingMail = true;
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.sendToMail(this.bookId, email, this.mailFormat);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp));
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '发送成功');
      this.closeSheet();
    } catch (error) {
      this.toast(`发送失败：${error}`);
    } finally {
      this.sendingMail = false;
    }
  }

  /** 格式操作统一入口：转换/分离/删除后刷新详情。 */
  private async runFormatAction(action: () => Promise<ApiMessageResult>, successHint: string):
    Promise<void> {
    if (this.formatBusy) {
      return;
    }
    this.formatBusy = true;
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await action();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp));
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : successHint);
      this.closeSheet();
      await this.loadDetail();
    } catch (error) {
      this.toast(`操作失败：${error}`);
    } finally {
      this.formatBusy = false;
    }
  }

  private confirmDeleteFormat(): void {
    this.getUIContext().showAlertDialog({
      title: '删除格式',
      message: `确定删除《${this.title}》的 ${this.manageFormat} 格式吗？`,
      primaryButton: {
        value: '删除',
        action: () => {
          void this.runFormatAction(() => TalebookApi.deleteFormat(this.bookId, this.manageFormat),
            '格式已删除');
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  /** 删除整本：服务端书籍移入回收站（可在「回收站管理」恢复），本地导入书籍删除本地文件与下载记录。 */
  private confirmDeleteBook(): void {
    this.getUIContext().showAlertDialog({
      title: '删除图书',
      message: this.localOnly
        ? `确定删除《${this.title}》的本地文件吗？`
        : `确定删除《${this.title}》吗？书籍会移入服务端回收站，可在「回收站管理」中恢复。`,
      primaryButton: {
        value: '删除',
        action: () => {
          void this.runDeleteBook();
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async runDeleteBook(): Promise<void> {
    if (this.deleteBusy) {
      return;
    }
    this.deleteBusy = true;
    try {
      if (this.localOnly) {
        TalebookService.removeDownloadRecord(this.localBookId);
        this.toast('已删除');
        this.getUIContext().getRouter().back();
        return;
      }
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.deleteBook(this.bookId);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp));
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已删除');
      BookshelfRefresh.notify();
      this.getUIContext().getRouter().back();
    } catch (error) {
      this.toast(`删除失败：${error}`);
    } finally {
      this.deleteBusy = false;
    }
  }

  private async pickAndUploadCover(): Promise<void> {
    if (this.coverBusy) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const file = await BookUploadService.pickAvatarImage(context);
      if (file === null) {
        return;
      }
      this.coverBusy = true;
      const authed = await TalebookService.ensureAuthenticated();
      if (!authed) {
        this.toast('登录已失效，请重新登录后再上传');
        return;
      }
      this.toast('正在上传封面…');
      const rsp = await TalebookApi.uploadCover(this.bookId, file.localPath, file.name);
      BookUploadService.removeStagedFile(file.localPath);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp));
        return;
      }
      this.toast('封面已更新');
      this.closeSheet();
      await this.loadDetail();
    } catch (error) {
      this.toast(`封面上传失败：${error}`);
    } finally {
      this.coverBusy = false;
    }
  }

  private async runCoverAction(action: () => Promise<ApiMessageResult>, successHint: string):
    Promise<void> {
    if (this.coverBusy) {
      return;
    }
    this.coverBusy = true;
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await action();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp));
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : successHint);
      this.closeSheet();
      await this.loadDetail();
    } catch (error) {
      this.toast(`操作失败：${error}`);
    } finally {
      this.coverBusy = false;
    }
  }

  private async toggleSole(): Promise<void> {
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.setSole(this.bookId);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp));
        return;
      }
      this.isSole = !this.isSole;
      this.toast(this.isSole ? '已设为私藏' : '已取消私藏');
    } catch (error) {
      this.toast(`操作失败：${error}`);
    }
  }

  private async updateTags(): Promise<void> {
    if (this.formatBusy) {
      return;
    }
    this.formatBusy = true;
    this.toast('正在更新标签…');
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.updateBookTags(this.bookId);
      this.toast(rsp.err !== undefined && rsp.err !== 'ok' ? apiErrorMessage(rsp) :
        (rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '标签已更新'));
      if (rsp.err === undefined || rsp.err === 'ok') {
        await this.loadDetail();
      }
    } catch (error) {
      this.toast(`更新失败：${error}`);
    } finally {
      this.formatBusy = false;
    }
  }

  private async saveMeta(): Promise<void> {
    if (this.formatBusy) {
      return;
    }
    this.formatBusy = true;
    this.toast('正在保存元数据到文件…');
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.saveBookMeta(this.bookId, this.selectedFormat);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp));
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '元数据已写入文件');
    } catch (error) {
      this.toast(`保存失败：${error}`);
    } finally {
      this.formatBusy = false;
    }
  }

  private readStateLabel(state: number): string {
    if (state === 1) {
      return '在读';
    }
    if (state === 2) {
      return '已读完';
    }
    return '未读';
  }

  private async setReadState(next: number): Promise<void> {
    if (next === this.readState) {
      return;
    }
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.setReadState(this.bookId, next);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp));
        return;
      }
      this.readState = next;
      this.toast(`已标记为：${this.readStateLabel(next)}`);
      this.loadSocialData();
    } catch (error) {
      this.toast(`操作失败：${error}`);
    }
  }

  private async openReviewSheet(): Promise<void> {
    this.openSheet('review');
    try {
      await TalebookService.ensureAuthenticated();
      const own = await TalebookApi.getOwnReview(this.bookId);
      this.ownReview = own;
      if (own !== null) {
        this.reviewStars = Math.round(own.rating / 2);
        this.reviewComment = own.comment;
      }
    } catch (_error) {
      this.ownReview = null;
    }
  }

  private async submitReview(): Promise<void> {
    if (this.submittingReview) {
      return;
    }
    if (this.reviewStars <= 0) {
      this.toast('请先选择评分');
      return;
    }
    this.submittingReview = true;
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.submitReview(this.bookId, this.reviewStars * 2,
        this.reviewComment.trim());
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp));
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '评价已提交');
      this.closeSheet();
      this.loadSocialData();
    } catch (error) {
      this.toast(`提交失败：${error}`);
    } finally {
      this.submittingReview = false;
    }
  }

  private confirmDeleteReview(): void {
    this.getUIContext().showAlertDialog({
      title: '删除评价',
      message: '确定删除我的这条评价吗？',
      primaryButton: {
        value: '删除',
        action: () => {
          TalebookApi.deleteReview(this.bookId)
            .then((rsp) => {
              if (rsp.err === undefined || rsp.err === 'ok') {
                this.toast('已删除');
                this.ownReview = null;
                this.reviewStars = 0;
                this.reviewComment = '';
                this.closeSheet();
                this.loadSocialData();
              } else {
                this.toast(apiErrorMessage(rsp));
              }
            })
            .catch((e: Object) => this.toast(`删除失败：${e}`));
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async toggleFavorite(): Promise<void> {
    const next = !this.isFavorite;
    const envelope = await TalebookService.setFavoriteAsync(this.bookId, next);
    if (TalebookService.isApiSuccess(envelope)) {
      this.isFavorite = next;
    } else {
      this.getUIContext().getPromptAction().showToast({
        message: envelope.error.length > 0 ? envelope.error : '操作失败',
      });
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async openBooklistSheet(): Promise<void> {
    if (this.localOnly || this.bookId <= 0) {
      return;
    }
    this.openSheet('booklist');
    this.booklistLoading = true;
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.getUIContext().getPromptAction().showToast({ message: '请先配置 Talebook 服务器' });
        this.closeSheet();
        return;
      }
      await TalebookService.ensureAuthenticated();
      const rsp = await BookListApi.getBookBooklists(this.bookId);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.getUIContext().getPromptAction().showToast({ message: apiErrorMessage(rsp) });
        this.closeSheet();
        return;
      }
      this.booklistItems = parseBookListQuickItems(rsp.booklists);
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: `加载失败：${error}` });
      this.closeSheet();
    } finally {
      this.booklistLoading = false;
    }
  }

  private async toggleBooklistItem(item: BookListQuickItem): Promise<void> {
    try {
      if (item.containsBook) {
        const rsp = await BookListApi.removeBook(item.id, this.bookId);
        if (rsp.err !== undefined && rsp.err !== 'ok') {
          this.toast(apiErrorMessage(rsp));
          return;
        }
        this.toast('已从书单移出');
      } else {
        const rsp = await BookListApi.addBooks(item.id, [this.bookId]);
        if (rsp.err !== undefined && rsp.err !== 'ok') {
          this.toast(apiErrorMessage(rsp));
          return;
        }
        this.toast('已加入书单');
      }
      const next = !item.containsBook;
      this.booklistItems = this.booklistItems.map((list: BookListQuickItem): BookListQuickItem => {
        if (list.id !== item.id) {
          return list;
        }
        return {
          id: list.id, name: list.name, color: list.color,
          isPublic: list.isPublic, containsBook: next,
        };
      });
    } catch (error) {
      this.toast(`操作失败：${error}`);
    }
  }

  private async createBooklistAndAdd(): Promise<void> {
    const name = this.newBooklistName.trim();
    if (name.length === 0) {
      this.toast('书单名称不能为空');
      return;
    }
    try {
      const rsp = await BookListApi.createBooklist(name, '', 'marine', false);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp));
        return;
      }
      const created = rsp.booklist as Record<string, Object> | undefined;
      const newId = created === undefined ? 0 : Number(created['id'] ?? 0);
      this.newBooklistName = '';
      if (newId > 0) {
        await BookListApi.addBooks(newId, [this.bookId]);
      }
      this.toast('已创建并加入书单');
      await this.openBooklistSheet();
    } catch (error) {
      this.toast(`创建失败：${error}`);
    }
  }

  @Builder
  metaChip(label: string, onTap: () => void) {
    ChipButton({
      label: label,
      onTap: onTap,
    })
      .margin({ right: 8, bottom: 8 });
  }

  @Builder
  quickAction(icon: Resource, label: string, active: boolean, onTap: () => void) {
    Column({ space: 4 }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([active ? $r('app.color.brand_primary') : $r('app.color.text_secondary')]);
      Text(label)
        .fontSize(11)
        .fontColor(active ? $r('app.color.brand_primary') : $r('app.color.text_secondary'));
    }
    .padding({ left: 14, right: 14, top: 6, bottom: 6 })
    .borderRadius($r('app.float.chip_radius'))
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(onTap);
  }

  @Builder
  menuDivider() {
    Row() {
      Divider().color($r('app.color.divider')).strokeWidth(0.5)
        .margin({ left: 52 });
    }
  }

  @Builder
  menuItem(icon: Resource, title: string, valueText: string, onTap: () => void, danger: boolean = false) {
    Row({ space: 12 }) {
      SymbolGlyph(icon)
        .fontSize(20)
        .fontColor([danger ? $r('app.color.error') : $r('app.color.brand_primary')]);
      Text(title)
        .fontSize(15)
        .fontColor(danger ? $r('app.color.error') : $r('app.color.text_primary'))
        .layoutWeight(1);
      if (valueText.length > 0) {
        Text(valueText)
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'));
      }
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([$r('app.color.text_tertiary')]);
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(onTap);
  }

  @Builder
  socialStatDivider() {
    Column()
      .width(1)
      .height(28)
      .backgroundColor($r('app.color.divider'));
  }

  @Builder
  socialStatItem(label: string, count: number) {
    Column({ space: 4 }) {
      Text(`${count}`)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'));
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'));
    }
    .alignItems(HorizontalAlign.Center);
  }

  @Builder
  reviewStarsRow(stars: number, starSize: number) {
    StarRating({
      rating: stars,
      starSize: starSize,
    });
  }

  @Builder
  reviewRow(review: BookReviewItem) {
    Row({ space: 10 }) {
      if (review.avatar.length > 0) {
        Column() {
          AuthImage({
            url: review.avatar,
            imageWidth: 34,
            imageHeight: 34,
          });
        }
        .borderRadius(17)
        .clip(true);
      } else {
        SymbolGlyph($r('sys.symbol.person_crop_circle_fill'))
          .fontSize(32)
          .fontColor([$r('app.color.text_tertiary')]);
      }
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(review.nickname.length > 0 ? review.nickname : '匿名读者')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1);
          this.reviewStarsRow(Math.round(review.rating / 2), 12);
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);
        if (review.comment.length > 0) {
          Text(review.comment)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .lineHeight(19)
            .width('100%');
        }
        if (review.isOwn) {
          Text('我的评价 · 点击「写书评」可修改')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'));
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
    }
    .width('100%')
    .alignItems(VerticalAlign.Top);
  }

  @Builder
  reviewSheet() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Text('评分')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'));
        this.reviewStarsRow(this.reviewStars, 26);
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);
      Row({ space: 6 }) {
        ForEach([1, 2, 3, 4, 5], (index: number) => {
          Column() {
            SymbolGlyph(index <= this.reviewStars ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
              .fontSize(30)
              .fontColor([index <= this.reviewStars ? $r('app.color.brand_primary') : $r('app.color.divider')]);
          }
          .onClick(() => {
            this.reviewStars = index;
          });
        }, (index: number) => `pick-${index}-${this.reviewStars}`);
      }
      .width('100%')
      .justifyContent(FlexAlign.Center);
      TextArea({ text: this.reviewComment, placeholder: '写下你的评价（可选）' })
        .width('100%')
        .height(100)
        .onChange((value: string) => {
          this.reviewComment = value;
        });
      Row({ space: 12 }) {
        if (this.ownReview !== null) {
          SecondaryButton({
            label: '删除我的评价',
            fullWidth: false,
            onTap: () => this.confirmDeleteReview(),
          })
            .layoutWeight(1);
        }
        PrimaryButton({
          label: '提交评价',
          fullWidth: false,
          buttonEnabled: !this.submittingReview,
          onTap: () => {
            void this.submitReview();
          },
        })
          .layoutWeight(1);
      }
      .width('100%');
    }
    .width('100%')
    .padding($r('app.float.page_padding'));
  }

  build() {
    Column() {
      PageScaffold({
        title: '书籍详情',
        showBack: true,
        content: () => {
          this.detailContent();
        },
      });
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showSheet, this.activeSheetContent(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      title: { title: this.sheetTitle() },
    });
  }

  @Builder
  activeSheetContent() {
    if (this.activeSheet === 'booklist') {
      this.booklistSheet();
    } else if (this.activeSheet === 'review') {
      this.reviewSheet();
    } else if (this.activeSheet === 'push') {
      this.pushSheet();
    } else if (this.activeSheet === 'mail') {
      this.mailSheet();
    } else if (this.activeSheet === 'format') {
      this.formatSheet();
    } else if (this.activeSheet === 'cover') {
      this.coverSheet();
    } else if (this.activeSheet === 'more') {
      this.moreSheet();
    }
  }

  private sheetTitle(): string {
    if (this.activeSheet === 'booklist') {
      return '加入书单';
    }
    if (this.activeSheet === 'review') {
      return this.ownReview !== null ? '修改我的评价' : '写书评';
    }
    if (this.activeSheet === 'push') {
      return '推送到设备';
    }
    if (this.activeSheet === 'mail') {
      return '邮件分享';
    }
    if (this.activeSheet === 'format') {
      return '格式管理';
    }
    if (this.activeSheet === 'cover') {
      return '封面管理';
    }
    if (this.activeSheet === 'more') {
      return '更多操作';
    }
    return '';
  }

  @Builder
  moreSheet() {
    Column({ space: 4 }) {
      Tabs({ barPosition: BarPosition.Start }) {
        TabContent() {
          List() {
            if (!this.localOnly && this.bookId > 0) {
              if (ServerRegistry.supports(ServerFeature.BOOKLISTS)) {
                ListItem() {
                  this.menuItem($r('sys.symbol.folder'), '加入书单', '', () => {
                    this.closeSheet();
                    void this.openBooklistSheet();
                  });
                }
              }
              if (ServerRegistry.supports(ServerFeature.BOOK_SET_SOLE)) {
                ListItem() {
                  this.menuItem($r('sys.symbol.lock'), this.isSole ? '取消私藏' : '设为私藏', '', () => {
                    this.closeSheet();
                    void this.toggleSole();
                  });
                }
              }
              ListItem() {
                this.menuItem($r('sys.symbol.square_and_pencil'), '编辑元数据', '', () => {
                  this.closeSheet();
                  this.getUIContext().getRouter().pushUrl({
                    url: 'pages/BookEditPage',
                    params: { bookId: this.bookId },
                  });
                });
              }
              ListItem() {
                this.menuItem($r('sys.symbol.doc_text'), '引用信息', '', () => {
                  this.closeSheet();
                  this.getUIContext().getRouter().pushUrl({
                    url: 'pages/ReferResultPage',
                    params: {
                      bookId: this.bookId,
                      title: this.title,
                      isbn: this.isbn,
                      publisher: this.publisher,
                    },
                  });
                });
              }
              // 音频文件页依赖 mybooks 专有的转换/购买/合集端点（talebook 上游是另一套 podcast 音频体系）
              if (ServerRegistry.supports(ServerFeature.AUDIOBOOKS)) {
                ListItem() {
                  this.menuItem($r('sys.symbol.headphones'), '音频文件', '', () => {
                    this.closeSheet();
                    this.getUIContext().getRouter().pushUrl({
                      url: 'pages/AudioFilesPage',
                      params: { bookId: this.bookId, title: this.title, author: this.author, cover: this.cover },
                    });
                  });
                }
              }
              if (ServerRegistry.supports(ServerFeature.COMIC)) {
                ListItem() {
                  this.menuItem($r('sys.symbol.square_grid_2x2'), '漫画阅读', '在线阅读', () => {
                    this.closeSheet();
                    this.getUIContext().getRouter().pushUrl({ url: 'pages/ComicReaderPage', params: { bookId: this.bookId } });
                  });
                }
              }
            }
            if (ServerRegistry.supports(ServerFeature.BOOK_TAGS_EDIT)) {
              ListItem() {
                this.menuItem($r('sys.symbol.paintbrush'), '更新标签', '', () => {
                  this.closeSheet();
                  void this.updateTags();
                });
              }
            }
            if (ServerRegistry.supports(ServerFeature.BOOK_AIFILL)) {
              ListItem() {
                this.menuItem($r('sys.symbol.wand_and_stars'),
                  this.aiFilling ? 'AI 补全中…' : 'AI 补全元数据', '', () => {
                    this.closeSheet();
                    void this.aiFill();
                  });
              }
            }
            ListItem() {
              this.menuItem($r('sys.symbol.plus_circle'), '上传新格式', '', () => {
                this.closeSheet();
                void this.pickAndUploadFormat();
              });
            }
          }
          .width('100%')
          .height('100%')
          .divider({ strokeWidth: 0.5, color: $r('app.color.divider') })
          .scrollBar(BarState.Off);
        }
        .tabBar('常用')
        TabContent() {
          List() {
            if (!this.localOnly && this.bookId > 0) {
              if (ServerRegistry.supports(ServerFeature.BOOKLISTS)) {
                ListItem() {
                  this.menuItem($r('sys.symbol.folder'), '加入书单', '', () => {
                    this.closeSheet();
                    void this.openBooklistSheet();
                  });
                }
              }
              if (ServerRegistry.supports(ServerFeature.BOOK_SET_SOLE)) {
                ListItem() {
                  this.menuItem($r('sys.symbol.lock'), this.isSole ? '取消私藏' : '设为私藏', '', () => {
                    this.closeSheet();
                    void this.toggleSole();
                  });
                }
              }
            }
          }
          .width('100%')
          .height('100%')
          .divider({ strokeWidth: 0.5, color: $r('app.color.divider') })
          .scrollBar(BarState.Off);
        }
        .tabBar('阅读')
        TabContent() {
          List() {
            if (!this.localOnly && this.bookId > 0) {
              ListItem() {
                this.menuItem($r('sys.symbol.square_and_pencil'), '编辑元数据', '', () => {
                  this.closeSheet();
                  this.getUIContext().getRouter().pushUrl({
                    url: 'pages/BookEditPage',
                    params: { bookId: this.bookId },
                  });
                });
              }
              ListItem() {
                this.menuItem($r('sys.symbol.doc_text'), '引用信息', '', () => {
                  this.closeSheet();
                  this.getUIContext().getRouter().pushUrl({
                    url: 'pages/ReferResultPage',
                    params: {
                      bookId: this.bookId,
                      title: this.title,
                      isbn: this.isbn,
                      publisher: this.publisher,
                    },
                  });
                });
              }
            }
            if (ServerRegistry.supports(ServerFeature.BOOK_TAGS_EDIT)) {
              ListItem() {
                this.menuItem($r('sys.symbol.paintbrush'), '更新标签', '', () => {
                  this.closeSheet();
                  void this.updateTags();
                });
              }
            }
            if (ServerRegistry.supports(ServerFeature.BOOK_AIFILL)) {
              ListItem() {
                this.menuItem($r('sys.symbol.wand_and_stars'),
                  this.aiFilling ? 'AI 补全中…' : 'AI 补全元数据', '', () => {
                    this.closeSheet();
                    void this.aiFill();
                  });
              }
            }
            ListItem() {
              this.menuItem($r('sys.symbol.archivebox_fill'), '保存元数据到文件', '', () => {
                this.closeSheet();
                void this.saveMeta();
              });
            }
            ListItem() {
              this.menuItem($r('sys.symbol.plus_circle'), '上传新格式', '', () => {
                this.closeSheet();
                void this.pickAndUploadFormat();
              });
            }
            ListItem() {
              this.menuItem($r('sys.symbol.doc_plaintext'), '格式管理', '', () => {
                this.manageFormat = this.selectedFormat;
                this.openSheet('format');
              });
            }
            ListItem() {
              this.menuItem($r('sys.symbol.paintpalette'), '封面管理', '', () => {
                this.openSheet('cover');
              });
            }
            if (ServerRegistry.supports(ServerFeature.ANNOTATIONS)) {
              ListItem() {
                this.menuItem($r('sys.symbol.doc_text'), '书内标注', '高亮、笔记与书签', () => {
                  this.closeSheet();
                  this.getUIContext().getRouter().pushUrl({
                    url: 'pages/BookAnnotationsPage',
                    params: { bookId: this.bookId, bookTitle: this.title },
                  });
                });
              }
            }
            if (ServerRegistry.supports(ServerFeature.BOOK_TXT)) {
              ListItem() {
                this.menuItem($r('sys.symbol.doc_plaintext'), 'TXT 工具', '内容片段 / 目录解析 / 位置', () => {
                  this.closeSheet();
                  this.getUIContext().getRouter().pushUrl({ url: 'pages/TxtBookPage', params: { bookId: this.bookId } });
                });
              }
            }
            if (ServerRegistry.supports(ServerFeature.BOOK_PROGRESS)) {
              ListItem() {
                this.menuItem($r('sys.symbol.clock'), '阅读进度与属性', '跨端进度、可见范围、媒体类型', () => {
                  this.closeSheet();
                  this.getUIContext().getRouter().pushUrl({ url: 'pages/ReadingProgressPage', params: { bookId: this.bookId } });
                });
              }
            }
            // 删除图书放最后：服务端书籍移入回收站（可恢复），本地导入书籍删除本地文件
            if (this.localOnly || this.bookId > 0) {
              ListItem() {
                this.menuItem($r('sys.symbol.trash'), '删除图书', '', () => {
                  this.closeSheet();
                  this.confirmDeleteBook();
                }, true);
              }
            }
          }
          .width('100%')
          .height('100%')
          .divider({ strokeWidth: 0.5, color: $r('app.color.divider') })
          .scrollBar(BarState.Off);
        }
        .tabBar('管理')
        if (!this.localOnly && this.bookId > 0) {
          // 整个「音频」页签只含 mybooks 专有的音频功能，加能力后再渲染页签本身
          if (ServerRegistry.supports(ServerFeature.AUDIOBOOKS)) {
            TabContent() {
              List() {
                ListItem() {
                  this.menuItem($r('sys.symbol.headphones'), '音频文件', '', () => {
                    this.closeSheet();
                    this.getUIContext().getRouter().pushUrl({
                      url: 'pages/AudioFilesPage',
                      params: { bookId: this.bookId, title: this.title, author: this.author, cover: this.cover },
                    });
                  });
                }
                if (ServerRegistry.supports(ServerFeature.COMIC)) {
                  ListItem() {
                    this.menuItem($r('sys.symbol.square_grid_2x2'), '漫画阅读', '在线阅读', () => {
                      this.closeSheet();
                      this.getUIContext().getRouter().pushUrl({ url: 'pages/ComicReaderPage', params: { bookId: this.bookId } });
                    });
                  }
                }
              }
              .width('100%')
              .height('100%')
              .scrollBar(BarState.Off);
            }
            .tabBar('音频')
          }
        }
      }
      .scrollable(false)
      .width('100%')
      .height(430);
    }
    .width('100%')
    .padding({ top: 4, bottom: 8 });
  }

  @Builder
  formatSheet() {
    Column({ space: 12 }) {
      Text('格式转换')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      Row({ space: 12 }) {
        SecondaryButton({
          label: '转 Kindle/EPUB',
          fullWidth: false,
          buttonEnabled: !this.formatBusy,
          onTap: () => {
            void this.runFormatAction(() => TalebookApi.convertBook(this.bookId), '转换任务已提交');
          },
        })
          .layoutWeight(1);
        SecondaryButton({
          label: '转 PDF',
          fullWidth: false,
          buttonEnabled: !this.formatBusy,
          onTap: () => {
            void this.runFormatAction(() => TalebookApi.convertBookToPdf(this.bookId), '转换任务已提交');
          },
        })
          .layoutWeight(1);
      }
      .width('100%');
      Text('分离 / 删除格式')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.formats, (item: BookFileFormat) => {
          ChipButton({
            label: item.format,
            selected: this.manageFormat === item.format,
            onTap: () => {
              this.manageFormat = item.format;
            },
          })
            .margin({ right: 8, bottom: 8 });
        }, (item: BookFileFormat) => `fmt-${item.format}`);
      }
      .width('100%');
      Row({ space: 12 }) {
        SecondaryButton({
          label: '分离为新书',
          fullWidth: false,
          buttonEnabled: !this.formatBusy && this.manageFormat.length > 0,
          onTap: () => {
            void this.runFormatAction(() => TalebookApi.separateFormat(this.bookId, this.manageFormat),
              '分离成功');
          },
        })
          .layoutWeight(1);
        SecondaryButton({
          label: '删除此格式',
          fullWidth: false,
          buttonEnabled: !this.formatBusy && this.manageFormat.length > 0,
          onTap: () => this.confirmDeleteFormat(),
        })
          .layoutWeight(1);
      }
      .width('100%');
    }
    .width('100%')
    .padding($r('app.float.page_padding'));
  }

  @Builder
  coverSheet() {
    Column({ space: 12 }) {
      SecondaryButton({
        label: '上传本地封面',
        buttonEnabled: !this.coverBusy,
        onTap: () => {
          void this.pickAndUploadCover();
        },
      });
      if (ServerRegistry.supports(ServerFeature.BOOK_CROP_COVER)) {
        SecondaryButton({
          label: '生成默认封面',
          buttonEnabled: !this.coverBusy,
          onTap: () => {
            void this.runCoverAction(() => TalebookApi.generateDefaultCover(this.bookId), '已生成默认封面');
          },
        });
        SecondaryButton({
          label: '裁剪封面白边',
          buttonEnabled: !this.coverBusy,
          onTap: () => {
            void this.runCoverAction(() => TalebookApi.cropCover(this.bookId), '封面已裁剪');
          },
        });
      }
      if (ServerRegistry.supports(ServerFeature.BOOK_ADD_STAMP)) {
        SecondaryButton({
          label: '封面盖章',
          buttonEnabled: !this.coverBusy,
          onTap: () => {
            void this.runCoverAction(() => TalebookApi.addStamp(this.bookId, 'bottom-right'), '图章已添加');
          },
        });
      }
    }
    .width('100%')
    .padding($r('app.float.page_padding'));
  }

  @Builder
  pushSheet() {
    Column({ space: 12 }) {
      if (this.selectedFormat.length > 0) {
        Text(`将发送格式：${this.selectedFormat.toUpperCase()}`)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      }
      Scroll() {
        Row({ space: 8 }) {
          ForEach(PUSH_DEVICE_TYPES, (type: string) => {
            ChipButton({
              label: deviceTypeLabel(type),
              selected: this.pushDeviceType === type,
              onTap: () => {
                this.pushDeviceType = type;
              },
            });
          }, (type: string) => `push-${type}`);
        }
        .padding({ right: 8 });
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%');
      if (this.pushDeviceType === 'kindle') {
        TextInput({ text: this.pushMailbox, placeholder: 'Kindle 邮箱地址' })
          .type(InputType.Email)
          .width('100%')
          .height(42)
          .onChange((value: string) => {
            this.pushMailbox = value;
          });
      } else if (this.pushDeviceType === 'ftp') {
        TextInput({ text: this.pushDeviceUrl, placeholder: 'FTP 地址（IP 或 ftp://…）' })
          .width('100%')
          .height(42)
          .onChange((value: string) => {
            this.pushDeviceUrl = value;
          });
        TextInput({ text: this.pushFtpPath, placeholder: 'FTP 路径（如 /books）' })
          .width('100%')
          .height(42)
          .onChange((value: string) => {
            this.pushFtpPath = value;
          });
        TextInput({ text: this.pushFtpUsername, placeholder: 'FTP 用户名（可选）' })
          .width('100%')
          .height(42)
          .onChange((value: string) => {
            this.pushFtpUsername = value;
          });
        TextInput({ text: this.pushFtpPassword, placeholder: 'FTP 密码（可选）' })
          .type(InputType.Password)
          .width('100%')
          .height(42)
          .onChange((value: string) => {
            this.pushFtpPassword = value;
          });
      } else {
        TextInput({ text: this.pushDeviceUrl, placeholder: '设备地址（IP 或 http://…）' })
          .width('100%')
          .height(42)
          .onChange((value: string) => {
            this.pushDeviceUrl = value;
          });
      }
      if (this.devices.length > 0) {
        Column({ space: 6 }) {
          Text('已保存设备')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'));
          ForEach(this.devices, (device: ReadingDevice) => {
            Row({ space: 8 }) {
              Text(deviceTypeLabel(device.type))
                .fontSize(13)
                .fontColor($r('app.color.brand_primary'));
              Text(this.deviceSummary(device))
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1);
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
            .onClick(() => {
              this.pushDeviceType = device.type;
              if (device.type === 'kindle') {
                this.pushMailbox = device.mailbox;
              } else if (device.type === 'ftp') {
                this.pushDeviceUrl = device.ip;
                this.pushFtpPath = device.ftpPath;
                this.pushFtpUsername = device.ftpUsername;
                this.pushFtpPassword = device.ftpPassword;
              } else {
                this.pushDeviceUrl = `${device.schema === 'https' ? 'https' : 'http'}://${device.ip}:${device.port}`;
              }
            });
          }, (device: ReadingDevice) => `dev-${device.name}-${device.type}`);
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start);
      }
      PrimaryButton({
        label: this.pushing ? '推送中…' : '推送',
        buttonEnabled: !this.pushing,
        onTap: () => {
          void this.pushToDevice();
        },
      });
    }
    .width('100%')
    .padding($r('app.float.page_padding'));
  }

  private deviceSummary(device: ReadingDevice): string {
    if (device.type === 'kindle') {
      return device.name.length > 0 ? device.name : device.mailbox;
    }
    if (device.type === 'ftp') {
      const base = device.name.length > 0 ? device.name : device.ip;
      return device.ftpPath.length > 0 ? `${base} ${device.ftpPath}` : base;
    }
    return device.name.length > 0 ? device.name : device.ip;
  }

  private formatLabel(item: BookFileFormat): string {
    if (item.size <= 0) {
      return item.format;
    }
    if (item.size >= 1024 * 1024) {
      return `${item.format} · ${(item.size / (1024 * 1024)).toFixed(1)} MB`;
    }
    return `${item.format} · ${Math.round(item.size / 1024)} KB`;
  }

  @Builder
  mailSheet() {
    Column({ space: 12 }) {
      TextInput({ text: this.mailAddress, placeholder: '收件邮箱地址' })
        .type(InputType.Email)
        .width('100%')
        .height(42)
        .onChange((value: string) => {
          this.mailAddress = value;
        });
      if (this.formats.length > 1) {
        Row({ space: 8 }) {
          Text('格式')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'));
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.formats, (item: BookFileFormat) => {
              ChipButton({
                label: this.formatLabel(item),
                selected: this.mailFormat === item.format.toLowerCase(),
                onTap: () => {
                  this.mailFormat = item.format.toLowerCase();
                },
              })
                .margin({ right: 8, bottom: 4 });
            }, (item: BookFileFormat) => `mail-${item.format}`);
          }
        }
        .width('100%');
      } else if (this.mailFormat.length > 0) {
        Text(`将发送格式：${this.mailFormat.toUpperCase()}`)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      }
      PrimaryButton({
        label: this.sendingMail ? '发送中…' : '发送',
        buttonEnabled: !this.sendingMail,
        onTap: () => {
          void this.sendMail();
        },
      });
    }
    .width('100%')
    .padding($r('app.float.page_padding'));
  }

  @Builder
  booklistSheet() {
    Column({ space: 10 }) {
      if (this.booklistLoading) {
        LoadingState({});
      } else if (this.booklistItems.length === 0) {
        Text('还没有书单，先创建一个吧')
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 12, bottom: 4 });
      } else {
        List({ space: 4 }) {
          ForEach(this.booklistItems, (item: BookListQuickItem) => {
            ListItem() {
              Row({ space: 10 }) {
                Column()
                  .width(10)
                  .height(10)
                  .borderRadius(5)
                  .backgroundColor(booklistColorHex(item.color));
                Text(item.name)
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1);
                if (!item.isPublic) {
                  SymbolGlyph($r('sys.symbol.lock'))
                    .fontSize(13)
                    .fontColor([$r('app.color.text_tertiary')]);
                }
                SymbolGlyph(item.containsBook ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
                  .fontSize(22)
                  .fontColor([item.containsBook ? $r('app.color.brand_primary') : $r('app.color.text_tertiary')]);
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .alignItems(VerticalAlign.Center)
              .stateStyles({
                pressed: {
                  .backgroundColor($r('app.color.surface_pressed'))
                },
              })
              .onClick(() => {
                void this.toggleBooklistItem(item);
              });
            }
          }, (item: BookListQuickItem) => `quick-${item.id}-${item.containsBook}`);
        }
        .constraintSize({ maxHeight: 320 })
        .width('100%');
      }
      Row({ space: 8 }) {
        TextInput({ placeholder: '新建书单名称', text: this.newBooklistName })
          .layoutWeight(1)
          .height(40)
          .onChange((value: string) => {
            this.newBooklistName = value;
          });
        SecondaryButton({
          label: '创建',
          fullWidth: false,
          onTap: () => {
            void this.createBooklistAndAdd();
          },
        });
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 });
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 });
  }

  @Builder
  detailContent() {
    if (this.loading) {
      LoadingState({});
    } else {
      Column() {
        Scroll() {
          Column({ space: 16 }) {
            Row({ space: 16 }) {
              if (this.cover.length > 0) {
                Column() {
                  AuthImage({
                    url: this.cover,
                    imageWidth: 120,
                    imageHeight: 170,
                  });
                }
                .shadow({ radius: 16, color: '#40000000', offsetY: 6 });
              } else {
                Column() {
                  Text((this.title.length > 0 ? this.title : '?').substring(0, 1))
                    .fontSize(36)
                    .fontColor($r('app.color.on_brand'));
                }
                .width(120)
                .height(170)
                .borderRadius($r('app.float.cover_radius'))
                .backgroundColor($r('app.color.cover_placeholder'))
                .justifyContent(FlexAlign.Center)
                .shadow({ radius: 16, color: '#40000000', offsetY: 6 });
              }
              Column({ space: 8 }) {
                Text(this.title)
                  .fontSize(21)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
                if (this.authors.length > 0) {
                  Flex({ wrap: FlexWrap.Wrap }) {
                    ForEach(this.authors, (name: string) => {
                      this.metaChip(name, () => this.openMetaBooks('author', name));
                    }, (name: string) => `author-${name}`);
                  }
                  .width('100%');
                }
                if (this.rating.length > 0) {
                  StarRating({
                    rating: Number(this.rating) / 2,
                    starSize: 13,
                    showValue: true,
                    valueText: this.rating,
                  });
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1);
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .padding(16)
            .borderRadius($r('app.float.card_radius'))
            .linearGradient({
              angle: 135,
              colors: [[$r('app.color.brand_primary_light'), 0.0], [$r('app.color.card_background'), 0.6]],
            });

            if (this.publisher.length > 0 || this.series.length > 0 || this.tags.length > 0 ||
              this.translator.length > 0 || this.isbn.length > 0 || this.extLink.length > 0) {
              Column({ space: 10 }) {
                if (this.publisher.length > 0) {
                  Row({ space: 12 }) {
                    Text('出版社')
                      .fontSize(13)
                      .fontColor($r('app.color.text_secondary'))
                      .width(52);
                    Text(this.publisher)
                      .fontSize(13)
                      .fontColor($r('app.color.brand_primary'))
                      .layoutWeight(1);
                  }
                  .width('100%');
                }
                if (this.translator.length > 0) {
                  Row({ space: 12 }) {
                    Text('译者')
                      .fontSize(13)
                      .fontColor($r('app.color.text_secondary'))
                      .width(52);
                    Text(this.translator)
                      .fontSize(13)
                      .fontColor($r('app.color.text_primary'))
                      .layoutWeight(1);
                  }
                  .width('100%');
                }
                if (this.series.length > 0) {
                  Row({ space: 12 }) {
                    Text('丛书')
                      .fontSize(13)
                      .fontColor($r('app.color.text_secondary'))
                      .width(52);
                    Text(this.series)
                      .fontSize(13)
                      .fontColor($r('app.color.brand_primary'))
                      .layoutWeight(1)
                      .onClick(() => this.openMetaBooks('series', this.series));
                  }
                  .width('100%');
                }
                if (this.isbn.length > 0) {
                  Row({ space: 12 }) {
                    Text('ISBN')
                      .fontSize(13)
                      .fontColor($r('app.color.text_secondary'))
                      .width(52);
                    Text(this.isbn)
                      .fontSize(13)
                      .fontColor($r('app.color.text_primary'))
                      .layoutWeight(1);
                  }
                  .width('100%');
                }
                if (this.extLink.length > 0) {
                  Row({ space: 12 }) {
                    Text('外链')
                      .fontSize(13)
                      .fontColor($r('app.color.text_secondary'))
                      .width(52);
                    Text(this.extLink)
                      .fontSize(13)
                      .fontColor($r('app.color.brand_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1);
                  }
                  .width('100%');
                }
                if (this.tags.length > 0) {
                  Column({ space: 6 }) {
                    Text('标签')
                      .fontSize(13)
                      .fontColor($r('app.color.text_secondary'));
                    Flex({ wrap: FlexWrap.Wrap }) {
                      ForEach(this.tags, (tag: string) => {
                        this.metaChip(tag, () => this.openMetaBooks('tag', tag));
                      }, (tag: string) => tag);
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .width('100%');
                }
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding($r('app.float.card_padding'))
              .borderRadius($r('app.float.card_radius'))
              .backgroundColor($r('app.color.card_background'));
            }

            if (!this.localOnly && this.bookId > 0) {
              Column({ space: 10 }) {
                Text('阅读状态')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'));
                Row({ space: 8 }) {
                  ChipButton({
                    label: '未读',
                    selected: this.readState === 0,
                    onTap: () => {
                      void this.setReadState(0);
                    },
                  });
                  ChipButton({
                    label: '在读',
                    selected: this.readState === 1,
                    onTap: () => {
                      void this.setReadState(1);
                    },
                  });
                  ChipButton({
                    label: '已读完',
                    selected: this.readState === 2,
                    onTap: () => {
                      void this.setReadState(2);
                    },
                  });
                }
                .width('100%');
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding($r('app.float.card_padding'))
              .borderRadius($r('app.float.card_radius'))
              .backgroundColor($r('app.color.card_background'));
            }

            if (this.socialStats !== null) {
              Row() {
                this.socialStatItem('在读', this.socialStats.readingCount);
                this.socialStatDivider();
                this.socialStatItem('读完', this.socialStats.finishedCount);
                this.socialStatDivider();
                this.socialStatItem('收藏', this.socialStats.favoriteCount);
                this.socialStatDivider();
                this.socialStatItem('推荐', this.socialStats.recommendCount);
              }
              .width('100%')
              .justifyContent(FlexAlign.SpaceBetween)
              .padding($r('app.float.card_padding'))
              .borderRadius($r('app.float.card_radius'))
              .backgroundColor($r('app.color.card_background'));
            }

            if (!this.localOnly && this.bookId > 0 && ServerRegistry.supports(ServerFeature.BOOK_REVIEWS)) {
              Column({ space: 10 }) {
                Row({ space: 8 }) {
                  Text(`书评 ${this.reviews.length}`)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1);
                  Text('写书评')
                    .fontSize(13)
                    .fontColor($r('app.color.brand_primary'))
                    .onClick(() => {
                      void this.openReviewSheet();
                    });
                }
                .width('100%');
                if (this.reviews.length === 0) {
                  Text('还没有书评，快来写第一条吧')
                    .fontSize(13)
                    .fontColor($r('app.color.text_tertiary'))
                    .width('100%');
                } else {
                  Column({ space: 12 }) {
                    ForEach(this.reviews, (review: BookReviewItem) => {
                      this.reviewRow(review);
                    }, (review: BookReviewItem) => `review-${review.id}-${review.updateTime}`);
                  }
                  .width('100%');
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding($r('app.float.card_padding'))
              .borderRadius($r('app.float.card_radius'))
              .backgroundColor($r('app.color.card_background'));
            }

            if (this.formats.length > 0) {
              Column({ space: 8 }) {
                Text('可用格式')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'));
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.formats, (item: BookFileFormat) => {
                    ChipButton({
                      label: item.format,
                      selected: this.selectedFormat === item.format,
                      onTap: () => this.selectedFormat = item.format,
                    })
                      .margin({ right: 8, bottom: 8 });
                  }, (item: BookFileFormat) => item.format);
                }
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding($r('app.float.card_padding'))
              .borderRadius($r('app.float.card_radius'))
              .backgroundColor($r('app.color.card_background'));
            }

            if (this.plainDescription().length > 0) {
              Column() {
                Text(this.plainDescription())
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .lineHeight(22);
              }
              .borderRadius($r('app.float.card_radius'))
              .backgroundColor($r('app.color.card_background'))
              .padding($r('app.float.card_padding'));
            }

            if (this.formatStats.length > 0) {
              Column({ space: 10 }) {
                Text('阅读进度')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'));
                ForEach(this.formatStats, (stat: FormatReadingStat) => {
                  Column({ space: 6 }) {
                    Row({ space: 10 }) {
                      Text(stat.format.toUpperCase())
                        .fontSize(13)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.brand_primary'));
                      Text(stat.state === 1 ? '已读完' :
                        (stat.progressPercent > 0 ? `${stat.progressPercent.toFixed(0)}%` : '在读'))
                        .fontSize(13)
                        .fontColor($r('app.color.text_primary'));
                      Blank().layoutWeight(1);
                      Text(`累计 ${formatStatDuration(stat.totalSeconds)}`)
                        .fontSize(12)
                        .fontColor($r('app.color.text_secondary'));
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Center);
                    Progress({ value: stat.state === 1 ? 100 : stat.progressPercent, total: 100,
                      type: ProgressType.Linear })
                      .color($r('app.color.brand_primary'))
                      .style({ strokeWidth: 4 })
                      .width('100%');
                  }
                  .width('100%');
                }, (stat: FormatReadingStat) => `fstat-${stat.format}-${stat.updateTime}`);
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding($r('app.float.card_padding'))
              .borderRadius($r('app.float.card_radius'))
              .backgroundColor($r('app.color.card_background'));
            }

            if (this.suggestions.length > 0) {
              Column({ space: 4 }) {
                SectionTitle({ title: '同类推荐' });
                Scroll() {
                  Row({ space: 10 }) {
                    ForEach(this.suggestions, (book: BookDetailSuggestion) => {
                      Column({ space: 4 }) {
                        AuthImage({
                          url: book.cover,
                          imageWidth: 78,
                          imageHeight: 110,
                        });
                        Text(book.title)
                          .fontSize(11)
                          .fontColor($r('app.color.text_primary'))
                          .maxLines(2)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width(78);
                      }
                      .alignItems(HorizontalAlign.Start)
                      .onClick(() => this.getUIContext().getRouter().pushUrl({
                        url: 'pages/BookDetailPage',
                        params: { bookId: book.id },
                      }));
                    }, (book: BookDetailSuggestion) => `sug-${book.id}`);
                  }
                  .padding({ left: 16, right: 16 });
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)
                .width('100%');
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start);
            }

            if (this.sameTitleBooks.length > 0) {
              Column({ space: 4 }) {
                SectionTitle({ title: '同名图书' });
                Scroll() {
                  Row({ space: 10 }) {
                    ForEach(this.sameTitleBooks, (book: BookDetailSuggestion) => {
                      Column({ space: 4 }) {
                        AuthImage({
                          url: book.cover,
                          imageWidth: 78,
                          imageHeight: 110,
                        });
                        Text(book.title)
                          .fontSize(11)
                          .fontColor($r('app.color.text_primary'))
                          .maxLines(2)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width(78);
                      }
                      .alignItems(HorizontalAlign.Start)
                      .onClick(() => this.getUIContext().getRouter().pushUrl({
                        url: 'pages/BookDetailPage',
                        params: { bookId: book.id },
                      }));
                    }, (book: BookDetailSuggestion) => `same-${book.id}`);
                  }
                  .padding({ left: 16, right: 16 });
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)
                .width('100%');
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start);
            }

            if (this.errorMessage.length > 0) {
              Text(this.errorMessage).fontColor($r('app.color.error'));
            }
          }
          .padding($r('app.float.page_padding'))
          .alignItems(HorizontalAlign.Start);
        }
        .layoutWeight(1);

        Column({ space: 10 }) {
          if (this.downloadMessage.length > 0) {
            Text(this.downloadMessage)
              .fontSize(13)
              .width('100%')
              .fontColor(this.downloadMessage === '下载完成' ?
                $r('app.color.success') : $r('app.color.text_secondary'));
          }
          Row({ space: 10 }) {
            PrimaryButton({
              label: this.readEnabled ? '开始阅读' :
                (this.downloading ? '下载中…' : '加入下载队列'),
              fullWidth: false,
              buttonEnabled: !this.downloading &&
                (this.readEnabled || this.selectedFormat.length > 0),
              onTap: () => {
                if (this.readEnabled) {
                  this.openReader();
                } else {
                  this.enqueueDownload();
                }
              },
            })
              .layoutWeight(2);
            SecondaryButton({
              label: this.isFavorite ? '已收藏' : '收藏',
              fullWidth: false,
              onTap: () => this.toggleFavorite(),
            })
              .layoutWeight(1);
          }
          .width('100%');
          Row({ space: 10 }) {
            if (ServerRegistry.supports(ServerFeature.BOOK_WANTS)) {
              this.quickAction($r('sys.symbol.bookmark'), this.isWants ? '已想读' : '想读',
                this.isWants, () => {
                  void this.toggleWants();
                });
            }
            this.quickAction($r('sys.symbol.paperplane'), '推送', false, () => {
              void this.openPushSheet();
            });
            this.quickAction($r('sys.symbol.envelope'), '分享', false, () => {
              void this.openMailSheet();
            });
            this.quickAction($r('sys.symbol.ellipsis_circle'), '更多', false, () => {
              if (this.showSheet && this.activeSheet === 'more') {
                this.closeSheet();
              } else {
                this.openSheet('more');
              }
            });
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween);
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 12 })
        .backgroundColor($r('app.color.card_background'));
      }
      .width('100%')
      .height('100%');
    }
  }
}
