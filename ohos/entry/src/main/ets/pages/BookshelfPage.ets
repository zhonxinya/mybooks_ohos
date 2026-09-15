import { common } from '@kit.AbilityKit';
import {
  HarmonyTopBar, BookListItemData, FilterChips, FilterChipItem,
  EmptyState, LoadingState, IconCircleButton, BookCatalogView, AuthImage, AccountPicker,
} from '../components';
import { DownloadRecord, ReadingHistoryItem, TalebookService, ApiEnvelope } from '../services/TalebookService';
import { ReaderLauncher, ReaderOpenParams } from '../services/ReaderLauncher';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { AccountManager } from '../services/AccountManager';
import { LocalBookService } from '../services/LocalBookService';
import { BookshelfRefresh } from '../utils/BookshelfRefresh';
import { DateFormat } from '../utils/DateFormat';
import { BookViewMode } from '../utils/BookViewMode';
import { PaginationConstants, PaginationHelper } from '../utils/PaginationHelper';
import { mapTalebookBook } from '../utils/BookMapper';

/** 书架页底部面板类型。 */
const SHEET_NONE: string = 'none';
const SHEET_MANAGE: string = 'manage';
const SHEET_ACCOUNT: string = 'account';

@Component
export struct BookshelfPage {
  @State records: DownloadRecord[] = [];
  @State displayRecords: DownloadRecord[] = [];
  @State catalogItems: BookListItemData[] = [];
  @State loading: boolean = true;
  @State importing: boolean = false;
  @State isListMode: boolean = false;
  @State @Watch('onSelectedTabChanged') selectedTab: number = 0;
  /**
   * 底部面板开关（同一节点只能挂一个 bindSheet，链式挂多个时只有第一个生效）。
   * 长按书籍 → 书籍管理；工具栏账号按钮 → 切换账号。
   */
  @State showSheet: boolean = false;
  @State sheetKind: string = SHEET_NONE;
  @State manageId: string = '';
  @State manageTitle: string = '';
  @State manageSubtitle: string = '';
  @State manageCover: string = '';
  @State manageReadLabel: string = '开始阅读';
  @State audioItems: BookListItemData[] = [];
  @State audioLoading: boolean = false;
  @State audioLoadingMore: boolean = false;
  @State audioHasMore: boolean = true;
  @State audioError: string = '';
  @StorageProp('bookshelfRefreshTick') @Watch('onRefreshTick') refreshTick: number = 0;
  private baseFilters: FilterChipItem[] = [
    { label: '全部', value: 0 },
    { label: '小说', value: 1 },
  ];
  /** 「有声书」页签仅在服务端提供音频接口时显示（音频详情结构两端不同）。 */
  private filterItems: FilterChipItem[] = ServerRegistry.supports(ServerFeature.AUDIOBOOKS)
    ? this.baseFilters.concat([{ label: '有声书', value: 2 }])
    : this.baseFilters;
  private audioPage: number = 1;
  private lastAudioLoadTime: number = 0;
  private audioBooksRaw: Record<string, Object>[] = [];

  aboutToAppear(): void {
    this.isListMode = BookViewMode.isListMode();
    this.loadData(false);
  }
  private onRefreshTick(): void {
    if (this.selectedTab === 2) {
      void this.loadAudiobooks(true);
    } else {
      this.loadData(true);
    }
  }

  private onSelectedTabChanged(): void {
    if (this.selectedTab === 2) {
      void this.loadAudiobooks(true);
      return;
    }
    this.updateDisplayRecords();
  }

  private loadData(silent: boolean = false): void {
    void this.loadDataAsync(silent);
  }

  private async loadDataAsync(silent: boolean = false): Promise<void> {
    if (!silent) {
      this.loading = true;
    }
    try {
      await TalebookService.warmLocalCaches();
      const url = TalebookService.secureGet('talebook_url');
      if (url.length > 0) {
        TalebookService.setBaseUrl('talebook', url);
      }
      this.records = this.mergeReadingProgress(TalebookService.getDownloads());
      this.updateDisplayRecords();
    } finally {
      this.loading = false;
    }
  }

  private mergeReadingProgress(records: DownloadRecord[]): DownloadRecord[] {
    const history = TalebookService.getReadingHistory();
    const historyMap = new Map<string, ReadingHistoryItem>();
    for (const item of history) {
      historyMap.set(item.bookId, item);
    }
    return records.map((record) => this.mergeRecordProgress(record, historyMap));
  }

  private mergeRecordProgress(record: DownloadRecord, historyMap: Map<string, ReadingHistoryItem>): DownloadRecord {
    if (record.progress?.location !== undefined && record.progress.location.length > 0) {
      return record;
    }
    const item = historyMap.get(record.bookId);
    if (item === undefined) {
      return record;
    }
    return {
      bookId: record.bookId,
      title: record.title,
      author: record.author,
      coverUrl: record.coverUrl,
      filePath: record.filePath,
      format: record.format,
      downloadTime: record.downloadTime,
      progress: {
        lastReadTime: item.lastReadTime,
        chapterName: item.chapterName,
        currentPage: item.currentPage,
        progressPercent: item.progressPercent,
        location: item.location,
      },
    };
  }

  private updateDisplayRecords(): void {
    if (this.selectedTab === 0) {
      this.displayRecords = this.records;
    } else if (this.selectedTab === 2) {
      return;
    } else {
      this.displayRecords = this.records.filter((item) => {
        const format = (item.format ?? '').toLowerCase();
        return format.includes('epub') || format.includes('txt') || format.includes('mobi') ||
          format.includes('azw');
      });
    }
    this.catalogItems = this.displayRecords.map((record: DownloadRecord) => this.toListItem(record));
  }

  private async loadAudiobooks(reset: boolean): Promise<void> {
    if (reset) {
      this.audioPage = 1;
      this.audioHasMore = true;
      this.audioBooksRaw = [];
      this.audioItems = [];
      this.audioLoading = true;
      this.audioError = '';
    } else {
      this.audioLoadingMore = true;
    }
    const page = this.audioPage;
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.audioError = '请先配置 Talebook 服务器';
        return;
      }
      if (TalebookService.hasAuthCredentials()) {
        await TalebookService.ensureAuthenticated();
      }
      const envelope: ApiEnvelope = await TalebookService.getServerBookListAsync(
        ServerRegistry.audiobooksPath(), page, PaginationConstants.PAGE_SIZE);
      if (!TalebookService.isApiSuccess(envelope)) {
        if (reset) {
          this.audioError = envelope.error.length > 0 ? envelope.error : '加载失败';
        } else {
          this.getUIContext().getPromptAction().showToast({
            message: envelope.error.length > 0 ? envelope.error : '加载更多失败',
          });
          this.audioPage = Math.max(1, this.audioPage - 1);
        }
        return;
      }
      const body = envelope.body ?? {};
      const fetched = (body['books'] as Record<string, Object>[] | undefined) ?? [];
      if (reset) {
        this.audioBooksRaw = fetched;
      } else {
        this.audioBooksRaw = this.audioBooksRaw.concat(fetched);
      }
      this.audioItems = this.audioBooksRaw.map((book: Record<string, Object>) => mapTalebookBook(book));
      this.audioHasMore = PaginationHelper.computeHasMore(fetched.length);
    } catch (error) {
      if (reset) {
        this.audioError = error instanceof Error ? error.message : `${error}`;
      }
    } finally {
      this.audioLoading = false;
      this.audioLoadingMore = false;
      this.lastAudioLoadTime = Date.now();
    }
  }

  private loadMoreAudiobooks(): void {
    if (!PaginationHelper.canLoadMore(this.lastAudioLoadTime, this.audioLoadingMore, this.audioHasMore)) {
      return;
    }
    this.audioPage += 1;
    void this.loadAudiobooks(false);
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private openAudioBook(item: BookListItemData): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/BookDetailPage',
      params: { bookId: Number(item.id) },
    });
  }

  private progressPercent(record: DownloadRecord): number {
    const percent = record.progress?.progressPercent;
    if (percent === undefined || percent < 0) {
      return -1;
    }
    return percent;
  }

  private progressSubtitle(record: DownloadRecord): string {
    const parts: string[] = [];
    const progressLine = this.progressText(record);
    if (progressLine.length > 0) {
      parts.push(progressLine);
    }
    const lastRead = DateFormat.lastReadLabel(record.progress?.lastReadTime);
    if (lastRead.length > 0) {
      parts.push(lastRead);
    }
    return parts.join(' · ');
  }

  private progressText(record: DownloadRecord): string {
    const progress = record.progress;
    if (progress === undefined) {
      return '';
    }
    if (progress.chapterName !== undefined && progress.chapterName.length > 0) {
      return `读到：${progress.chapterName}`;
    }
    if (progress.progressPercent !== undefined && progress.progressPercent >= 0) {
      return `已读 ${Math.round(progress.progressPercent)}%`;
    }
    if (progress.location !== undefined && progress.location.length > 0) {
      return '继续阅读';
    }
    return '';
  }

  private toListItem(record: DownloadRecord): BookListItemData {
    const cover = record.coverUrl !== undefined && record.coverUrl.length > 0 ?
      TalebookService.resolveCoverUrl(record.coverUrl) : '';
    return {
      id: record.bookId,
      title: record.title,
      author: record.author ?? '',
      cover: cover,
      subtitle: this.progressSubtitle(record),
      format: record.format ?? '',
    };
  }

  private resolveLocation(record: DownloadRecord): string {
    return TalebookService.resolveSavedLocation(record.bookId, record.filePath ?? '');
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private openDetail(record: DownloadRecord): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/BookDetailPage',
      params: {
        localOnly: true,
        localBookId: record.bookId,
        filePath: record.filePath ?? '',
        format: record.format ?? '',
        title: record.title ?? '',
      }
    });
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private openReader(record: DownloadRecord): void {
    if (!record.filePath || record.filePath.length === 0) {
      this.openDetail(record);
      return;
    }
    // 设备缺 ReaderKit 时不能路由（会 cppcrash），改由守卫提示
    const readerParams: ReaderOpenParams = {
      filePath: record.filePath,
      bookId: record.bookId,
      bookTitle: record.title,
      format: record.format ?? '',
      location: this.resolveLocation(record),
    };
    const opened: boolean = ReaderLauncher.open(this.getUIContext(), readerParams);
    if (!opened) {
      this.getUIContext().getPromptAction().showToast({ message: ReaderLauncher.UNAVAILABLE_MESSAGE });
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private deleteRecord(record: DownloadRecord): void {
    TalebookService.removeDownloadRecord(record.bookId);
    this.records = this.records.filter((item) => item.bookId !== record.bookId);
    this.updateDisplayRecords();
    this.getUIContext().getPromptAction().showToast({ message: '已删除' });
  }

  private findRecord(bookId: string): DownloadRecord | undefined {
    return this.displayRecords.find((item: DownloadRecord) => item.bookId === bookId);
  }

  private openManagePanel(item: BookListItemData): void {
    const record = this.findRecord(item.id);
    this.manageId = item.id;
    this.manageTitle = item.title;
    this.manageSubtitle = item.subtitle ?? '';
    this.manageCover = item.cover ?? '';
    this.manageReadLabel = record !== undefined && this.progressText(record).length > 0 ?
      '继续阅读' : '开始阅读';
    this.sheetKind = SHEET_MANAGE;
    this.showSheet = true;
  }

  private closeManagePanel(): void {
    this.sheetKind = SHEET_NONE;
    this.showSheet = false;
  }

  /** 服务端书库图书（数字 bookId）按 bookId 远程取详情；本地导入书 bookId 为 `local_<uuid>`，只能看本地信息。 */
  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private openManageDetail(): void {
    const record = this.findRecord(this.manageId);
    this.closeManagePanel();
    if (record === undefined) {
      return;
    }
    const remoteId = Number(record.bookId);
    if (remoteId > 0) {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/BookDetailPage',
        params: { bookId: remoteId },
      });
      return;
    }
    this.openDetail(record);
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private openManageReader(): void {
    const record = this.findRecord(this.manageId);
    this.closeManagePanel();
    if (record !== undefined) {
      this.openReader(record);
    }
  }

  private deleteFromManagePanel(): void {
    const record = this.findRecord(this.manageId);
    this.closeManagePanel();
    if (record !== undefined) {
      this.confirmDeleteRecord(record);
    }
  }

  private confirmDeleteRecord(record: DownloadRecord): void {
    this.getUIContext().showAlertDialog({
      title: '删除书籍',
      message: `确定删除「${record.title}」？`,
      primaryButton: {
        value: '删除',
        action: () => {
          this.deleteRecord(record);
        },
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        },
      },
    });
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private openByCatalogItem(item: BookListItemData): void {
    const record = this.displayRecords.find((r: DownloadRecord) => r.bookId === item.id);
    if (record !== undefined) {
      this.openReader(record);
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async importLocalBook(): Promise<void> {
    if (this.importing) {
      return;
    }
    this.importing = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const record = await LocalBookService.pickAndImport(context);
      if (record === null) {
        return;
      }
      this.getUIContext().getPromptAction().showToast({ message: '导入成功' });
      this.loadData();
      this.openReader(record);
    } catch (error) {
      const message = error instanceof Error ? error.message : '导入失败';
      this.getUIContext().getPromptAction().showToast({ message: message });
    } finally {
      this.importing = false;
    }
  }

  @Builder
  countBadge() {
    Text(`${this.selectedTab === 2 ? this.audioItems.length : this.displayRecords.length} 本`)
      .fontSize(12)
      .fontColor($r('app.color.brand_primary'))
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .borderRadius($r('app.float.chip_radius'))
      .backgroundColor($r('app.color.brand_primary_light'));
  }

  @Builder
  iconToolButton(icon: Resource, onTap: () => void) {
    IconCircleButton({
      icon: icon,
      variant: 'surface',
      iconSize: 18,
      buttonSize: 36,
      iconColor: $r('app.color.text_secondary'),
      onTap: onTap,
    });
  }

  /**
   * 账号按钮：显示当前账号名，点击打开切换面板；只有一个书库账号时提示而非静默无反应。
   * 放在工具栏最左（远离右侧“搜索/书单/上传”等操作，避免误触）。
   */
  @Builder
  accountButton() {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.person'))
        .fontSize(16)
        .fontColor([$r('app.color.text_secondary')]);
      Text(this.currentAccountLabel())
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 120 });
    }
    .height(36)
    .padding({ left: 12, right: 12 })
    .borderRadius($r('app.float.chip_radius'))
    .backgroundColor($r('app.color.card_background'))
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(() => this.openAccountSwitcher());
  }

  private currentAccountLabel(): string {
    const name: string = AccountManager.activeDisplayName();
    return name.length > 0 ? name : '未配置账号';
  }

  private openAccountSwitcher(): void {
    if (AccountManager.switchableAccounts().length <= 1) {
      this.getUIContext().getPromptAction().showToast({
        message: '只有一个书库账号，可在「设置 → 账号与服务器」新增账号',
      });
      return;
    }
    this.sheetKind = SHEET_ACCOUNT;
    this.showSheet = true;
  }

  @Builder
  toolbarRow() {
    Row({ space: 8 }) {
      this.accountButton();
      Blank().layoutWeight(1);
      this.iconToolButton($r('sys.symbol.magnifyingglass'), () => {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/TalebookBookSearchPage' });
      });
      this.iconToolButton($r('sys.symbol.book'), () => {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/SoNovelSearchPage' });
      });
      this.iconToolButton($r('sys.symbol.folder'), () => {
        if (ServerRegistry.supports(ServerFeature.BOOKLISTS)) {
          this.getUIContext().getRouter().pushUrl({ url: 'pages/BookListsPage' });
          return;
        }
        this.getUIContext().getPromptAction().showToast({
          message: `${ServerRegistry.profile().displayName} 服务端不支持书单`,
        });
      });
      this.iconToolButton($r('sys.symbol.arrowshape_turn_up_right'), () => {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/BookUploadPage' });
      });
      this.iconToolButton($r('sys.symbol.plus'), () => {
        this.importLocalBook();
      });
      this.iconToolButton(
        this.isListMode ? $r('sys.symbol.square_grid_2x2') : $r('sys.symbol.list_bullet'),
        () => {
          this.isListMode = !this.isListMode;
          BookViewMode.setListMode(this.isListMode);
        });
      this.iconToolButton($r('sys.symbol.clock'), () => {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/ReadingHistoryPage' });
      });
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 8 });
  }

  @Builder
  managePanelHeader() {
    Row({ space: 12 }) {
      if (this.manageCover.length > 0) {
        Column() {
          AuthImage({
            url: this.manageCover,
            imageWidth: 48,
            imageHeight: 68,
          });
        }
        .borderRadius(6)
        .clip(true);
      } else {
        Column() {
          SymbolGlyph($r('sys.symbol.book'))
            .fontSize(24)
            .fontColor([$r('app.color.text_tertiary')]);
        }
        .width(48)
        .height(68)
        .borderRadius(6)
        .backgroundColor($r('app.color.page_background'))
        .justifyContent(FlexAlign.Center);
      }
      Column({ space: 4 }) {
        Text(this.manageTitle.length > 0 ? this.manageTitle : '未知书名')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        if (this.manageSubtitle.length > 0) {
          Text(this.manageSubtitle)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
    }
    .width('100%')
    .alignItems(VerticalAlign.Top);
  }

  @Builder
  manageRow(icon: Resource, label: string, color: ResourceColor, onTap: () => void) {
    Row({ space: 12 }) {
      SymbolGlyph(icon)
        .fontSize(20)
        .fontColor([color]);
      Text(label)
        .fontSize(15)
        .fontColor(color)
        .layoutWeight(1);
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([$r('app.color.text_tertiary')]);
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(onTap);
  }

  @Builder
  manageDivider() {
    Divider()
      .color($r('app.color.divider'))
      .strokeWidth(0.5)
      .margin({ left: 48 });
  }

  @Builder
  manageSheet() {
    Column({ space: 16 }) {
      this.managePanelHeader();
      Column() {
        this.manageRow($r('sys.symbol.doc_text'), '书籍详情', $r('app.color.brand_primary'),
          () => this.openManageDetail());
        this.manageDivider();
        this.manageRow($r('sys.symbol.play_circle'), this.manageReadLabel, $r('app.color.brand_primary'),
          () => this.openManageReader());
        this.manageDivider();
        this.manageRow($r('sys.symbol.trash'), '删除本地书籍', $r('app.color.error'),
          () => this.deleteFromManagePanel());
      }
      .width('100%')
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'))
      .clip(true);
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 8 });
  }

  @Builder
  contentArea() {
    if (this.selectedTab === 2) {
      this.audiobookContent();
    } else if (this.loading) {
      LoadingState({});
    } else if (this.displayRecords.length === 0) {
      EmptyState({
        message: '暂无本地书籍',
        detail: '上传图书到服务器书库，或导入本地文件；也可用放大镜搜索书库、书本图标搜索 SoNovel、文件夹图标查看书单',
        actionLabel: '上传图书',
        onAction: () => this.getUIContext().getRouter().pushUrl({ url: 'pages/BookUploadPage' }),
      });
    } else {
      BookCatalogView({
        items: this.catalogItems,
        isListMode: this.isListMode,
        onItemTap: (item: BookListItemData) => this.openByCatalogItem(item),
        onItemLongPress: (item: BookListItemData) => this.openManagePanel(item),
      });
    }
  }

  @Builder
  audiobookContent() {
    if (this.audioLoading) {
      LoadingState({});
    } else if (this.audioError.length > 0) {
      EmptyState({
        message: this.audioError,
        actionLabel: '重试',
        onAction: () => {
          void this.loadAudiobooks(true);
        },
      });
    } else if (this.audioItems.length === 0) {
      EmptyState({ message: '暂无有声书' });
    } else {
      BookCatalogView({
        items: this.audioItems,
        isListMode: this.isListMode,
        loadingMore: this.audioLoadingMore,
        onItemTap: (item: BookListItemData) => this.openAudioBook(item),
        onLoadMore: () => this.loadMoreAudiobooks(),
      });
    }
  }

  build() {
    Column() {
      HarmonyTopBar({
        title: '书架',
        action: () => {
          this.countBadge();
        },
      });
      Column() {
        FilterChips({ items: this.filterItems, selected: $selectedTab });
      }
      .width('100%')
      .margin({ left: 16, right: 16, bottom: 4 })
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));
      this.toolbarRow();
      this.contentArea();
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .bindSheet($$this.showSheet, this.sheetContent(), {
      height: this.sheetIsAccount() ? SheetSize.FIT_CONTENT : SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      title: { title: this.sheetIsAccount() ? '切换账号' : '书籍管理' },
      onDisappear: () => {
        this.sheetKind = SHEET_NONE;
      },
    });
  }

  private sheetIsAccount(): boolean {
    return this.sheetKind === SHEET_ACCOUNT;
  }

  @Builder
  sheetContent() {
    if (this.sheetIsAccount()) {
      AccountPicker({ show: $showSheet });
    } else {
      this.manageSheet();
    }
  }
}
