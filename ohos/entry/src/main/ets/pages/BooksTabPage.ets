import {
  BookCatalogView, BookViewToggleButton, BookListItemData, LoadingState,
  SectionTitle, AuthImage, HarmonyTopBar,
} from '../components';
import { ApiEnvelope, TalebookService } from '../services/TalebookService';
import { TalebookApi, IndexHomeData, LibraryStatsResponse, LibraryStatsData } from '../services/TalebookApi';
import { BookListApi, BookListsResponse } from '../services/BookListApi';
import { BookListSummary, BookListCoverBook, booklistColorHex } from '../models/BookListModels';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { HomeBook, ReadingDashboard, formatDuration } from '../models/HomeModels';
import { PaginationConstants, PaginationHelper } from '../utils/PaginationHelper';
import { BookViewMode } from '../utils/BookViewMode';
import { hilog } from '@kit.PerformanceAnalysisKit';

interface BookSummary {
  id: number;
  title: string;
  author: string;
  cover: string;
  format: string;
  subtitle: string;
}

/**
 * 封面横滑行的入参。
 *
 * **必须是单一对象**：ArkUI 的 `@Builder` 按值传参时，状态变量的改变不会刷新 Builder 内部 UI
 * （早期写法 `coverScroll(books, showRecommender)` 传两个参数按值，导致「换一批」拿到新数据后
 * 封面行仍显示旧书）。按引用传参（对象字面量）才会随状态变化重建。
 */
interface CoverRowSpec {
  books: HomeBook[];
  showRecommender: boolean;
}


@Component
export struct BooksTabPage {
  @State allBooks: BookSummary[] = [];
  @State pageTitle: string = '小说';
  @State bookCount: number = 0;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State currentPage: number = 1;
  @State hasMore: boolean = true;
  @State errorMessage: string = '';
  @State emptyActionLabel: string = '';
  @State isListMode: boolean = false;
  @State catalogItems: BookListItemData[] = [];
  @State randomBooks: HomeBook[] = [];
  @State socialBooks: HomeBook[] = [];
  @State newBooks: HomeBook[] = [];
  @State libraryStats: LibraryStatsData | null = null;
  @State readingStats: ReadingDashboard | null = null;
  /** 首页书单推荐（/api/booklists/homepage，服务端挑置顶 > 我点赞的 > 其余公开，最多 2 个）。 */
  @State homeBooklists: BookListSummary[] = [];
  @State isRefreshing: boolean = false;
  /** 书库内容变更广播（删除/上传/元数据修改）：本页签常驻 Tabs，必须主动重取才不会停在旧数据上。 */
  @StorageProp('booksTabRefreshTick') @Watch('onLibraryChanged') libraryTick: number = 0;
  /** 下拉刷新的重入保护：isRefreshing 由 Refresh 组件先置 true，不能拿它判断重入。 */
  private refreshInFlight: boolean = false;
  private lastLoadTime: number = 0;

  aboutToAppear(): void {
    this.isListMode = BookViewMode.isListMode();
    void this.loadBooks(true);
  }

  /**
   * 书库内容变更后重取（删除图书、上传入库、应用引用信息等）。
   *
   * 与下拉刷新同样**不清空**现有列表：本页签是首页式页面，清空会整页闪一次骨架屏；
   * 首屏还没加载完时直接跳过，交给正在进行的加载。
   */
  private onLibraryChanged(): void {
    if (this.loading || this.refreshInFlight) {
      return;
    }
    this.currentPage = 1;
    this.hasMore = true;
    this.errorMessage = '';
    this.emptyActionLabel = '';
    TalebookService.invalidateNavCache();
    void this.fetchBooksAsync(true, this.currentPage);
  }

  private collectFormatText(item: Record<string, Object>): string {
    const direct = String(item['format'] ?? item['type'] ?? '');
    const parts: string[] = [];
    if (direct.length > 0) {
      parts.push(direct);
    }
    const files = item['files'] as Array<Record<string, Object>> | undefined;
    if (files !== undefined) {
      for (let i = 0; i < files.length; i++) {
        const fmt = String(files[i]['format'] ?? '');
        if (fmt.length > 0) {
          parts.push(fmt);
        }
      }
    }
    const bookType = String(item['book_type'] ?? '');
    if (bookType.length > 0) {
      parts.push(bookType);
    }
    return parts.join(' ').toLowerCase();
  }

  private mapBook(item: Record<string, Object>): BookSummary {
    const format = this.displayFormat(item);
    const pubdate = String(item['pubdate'] ?? item['timestamp'] ?? '');
    let subtitle = '';
    if (pubdate.length > 0 && pubdate !== '0') {
      const parsed = Number(pubdate);
      if (!Number.isNaN(parsed) && parsed > 0) {
        subtitle = new Date(parsed * (parsed < 1e12 ? 1000 : 1)).toLocaleDateString();
      }
    }
    return {
      id: Number(item['id'] ?? 0),
      title: String(item['title'] ?? '未知'),
      author: String(item['author'] ?? ''),
      cover: TalebookService.resolveCoverUrl(String(item['cover'] ?? item['cover_url'] ?? item['img'] ?? '')),
      format: format,
      subtitle: subtitle,
    };
  }

  /**
   * 卡片角标用的格式：只取真实格式名，取不到就空着（空字符串时角标不渲染）。
   *
   * 与 `collectFormatText` 分开的原因：后者会把 `book_type`（服务端实际下发的是 0/1 数值）
   * 也拼进去，而它同时用于 `isNovelBook` 过滤，不能直接删；直接拿来展示就会得到 `EPUB 0` 这种角标。
   * 数值字段一律跳过，避免把 `book_type` 之类的数字当成格式名显示出来。
   */
  private displayFormat(item: Record<string, Object>): string {
    const candidates: string[] = [];
    candidates.push(String(item['format'] ?? ''));
    const files = item['files'] as Array<Record<string, Object>> | undefined;
    if (files !== undefined) {
      for (let i = 0; i < files.length; i++) {
        candidates.push(String(files[i]['format'] ?? ''));
      }
    }
    candidates.push(String(item['type'] ?? ''));
    for (let i = 0; i < candidates.length; i++) {
      const value = candidates[i].trim();
      if (value.length > 0 && Number.isNaN(Number(value))) {
        return value;
      }
    }
    return '';
  }

  /** 小说：有 epub/txt/mobi/azw；排除有声书与实体书。无格式信息时默认当作电子书收录。 */
  private isNovelBook(item: Record<string, Object>, formatText: string): boolean {
    const hasAudio = Number(item['has_audio'] ?? 0) > 0;
    if (hasAudio) {
      return false;
    }
    const bookType = String(item['book_type'] ?? '').toLowerCase();
    if (bookType.includes('physical') || bookType.includes('print') || bookType === '实体书') {
      return false;
    }
    if (formatText.includes('epub') || formatText.includes('txt') || formatText.includes('mobi') ||
      formatText.includes('azw')) {
      return true;
    }
    // 列表常不带 files；不要误杀整页
    if (formatText.length === 0 || bookType.includes('ebook') || bookType.length === 0) {
      return true;
    }
    return false;
  }

  private filterNovelItems(items: Record<string, Object>[]): BookSummary[] {
    const result: BookSummary[] = [];
    for (let i = 0; i < items.length; i++) {
      const raw = items[i];
      const summary = this.mapBook(raw);
      // 过滤必须用完整的 `collectFormatText`（含 book_type），不能改用 summary.format：
      // 后者已剔除数值字段，会改变「无 files 且 book_type 非 ebook」这类条目的取舍。
      if (this.isNovelBook(raw, this.collectFormatText(raw))) {
        result.push(summary);
      }
    }
    return result;
  }

  private loadSiteInfoFromEnvelope(envelope: ApiEnvelope): void {
    if (!TalebookService.isApiSuccess(envelope)) {
      return;
    }
    const body = envelope.body ?? {};
    const sys = (body['sys'] as Record<string, Object> | undefined) ?? {};
    const title = String(sys['title'] ?? '');
    this.bookCount = Number(sys['books'] ?? 0);
    if (title.length > 0) {
      this.pageTitle = title;
    }
  }


  private loadBooks(reset: boolean = true): void {
    if (reset) {
      this.currentPage = 1;
      this.hasMore = true;
      this.allBooks = [];
      this.loading = true;
      this.errorMessage = '';
      this.emptyActionLabel = '';
    } else {
      this.loadingMore = true;
    }
    const page = this.currentPage;
    void this.fetchBooksAsync(reset, page);
  }

  private static readonly LOAD_TIMEOUT_MS: number = 45000;

  private async fetchBooksAsync(reset: boolean, page: number): Promise<void> {
    try {
      const url = TalebookService.secureGet('talebook_url');
      if (url.length === 0) {
        this.errorMessage = '请先配置 Talebook 服务器';
        this.emptyActionLabel = '去配置';
        return;
      }
      TalebookService.applyLocalConfig();
      if (reset) {
        await Promise.race([
          this.loadInitialData(page),
          new Promise<void>((_resolve, reject) => {
            setTimeout(() => reject(new Error('加载超时，请检查服务器地址或网络')), BooksTabPage.LOAD_TIMEOUT_MS);
          }),
        ]);
      } else {
        await this.fetchBookListAsync(reset, page);
      }
    } catch (error) {
      if (reset) {
        this.errorMessage = error instanceof Error ? error.message : `${error}`;
        this.emptyActionLabel = TalebookService.hasAuthCredentials() ? '' : '去配置账号';
      }
    } finally {
      this.finishLoad(reset);
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async loadInitialData(page: number): Promise<void> {
    const authPromise = TalebookService.hasAuthCredentials()
      ? TalebookService.ensureAuthenticated()
      : Promise.resolve(false);
    const results = await Promise.all([
      TalebookService.getUserInfoCachedAsync(),
      this.requestBookList(page),
      authPromise,
    ]);
    this.loadSiteInfoFromEnvelope(results[0]);
    TalebookService.saveUserProfileFromEnvelope(results[0]);
    await this.applyBookListEnvelope(true, results[1]);
    this.loadHomeSections();
  }

  /** 小说页推荐：/api/index 的 random_books + social_recommend_books + new_books，以及书库统计、阅读统计。失败静默。 */
  private loadHomeSections(): void {
    TalebookApi.getIndexHome()
      .then((data: IndexHomeData) => {
        this.randomBooks = this.resolveHomeBooks(data.randomBooks);
        this.socialBooks = this.resolveHomeBooks(data.socialBooks);
        this.newBooks = this.resolveHomeBooks(data.newBooks);
      })
      .catch(() => {
        this.randomBooks = [];
        this.socialBooks = [];
        this.newBooks = [];
      });
    if (ServerRegistry.supports(ServerFeature.ADMIN_LIBRARY_STATS)) {
      TalebookApi.getLibraryStats()
        .then((rsp: LibraryStatsResponse) => {
          this.libraryStats = rsp.err === undefined || rsp.err === 'ok' ? (rsp.stats ?? null) : null;
        })
        .catch(() => {
          this.libraryStats = null;
        });
    }
    if (TalebookService.hasAuthCredentials() && ServerRegistry.supports(ServerFeature.READING_DASHBOARD)) {
      TalebookApi.getReadingDashboard()
        .then((stats: ReadingDashboard | null) => {
          this.readingStats = stats;
        })
        .catch(() => {
          this.readingStats = null;
        });
    }
    if (ServerRegistry.supports(ServerFeature.BOOKLISTS)) {
      // 游客也可访问；服务端未开启 ENABLE_HOMEPAGE_BOOKLISTS 时返回空数组，此处直接不渲染该区块
      BookListApi.getHomepageBooklists()
        .then((rsp: BookListsResponse) => {
          this.homeBooklists = rsp.err === undefined || rsp.err === 'ok'
            ? BookListApi.parseSummaries(rsp) : [];
        })
        .catch(() => {
          this.homeBooklists = [];
        });
    }
  }

  /** 服务端封面常为相对路径（cdn_url 未配置时），统一解析为绝对 URL。 */
  private resolveHomeBooks(books: HomeBook[]): HomeBook[] {
    return books.map((book: HomeBook): HomeBook => ({
      id: book.id,
      title: book.title,
      author: book.author,
      cover: TalebookService.resolveCoverUrl(book.cover),
      recommender: book.recommender,
    }));
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async fetchBookListAsync(reset: boolean, page: number): Promise<void> {
    await this.applyBookListEnvelope(reset, await this.requestBookList(page));
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async applyBookListEnvelope(reset: boolean, envelope: ApiEnvelope): Promise<void> {
    let result = envelope;
    if (!TalebookService.isApiSuccess(result) && reset && TalebookService.hasAuthCredentials()) {
      const restored = await TalebookService.ensureAuthenticated();
      if (restored) {
        result = await this.requestBookList(this.currentPage);
      }
    }
    if (!TalebookService.isApiSuccess(result)) {
      if (reset) {
        this.errorMessage = result.error.length > 0 ? result.error : '加载失败';
        this.emptyActionLabel = TalebookService.hasAuthCredentials() ? '' : '去配置账号';
      } else {
        this.getUIContext().getPromptAction().showToast({
          message: result.error.length > 0 ? result.error : '加载更多失败',
        });
        this.currentPage = Math.max(1, this.currentPage - 1);
      }
      return;
    }
    const body = result.body ?? {};
    const items = (body['books'] as Record<string, Object>[] | undefined) ?? [];
    const fetchedRaw = items;
    const fetched = this.filterNovelItems(items);
    if (reset) {
      this.allBooks = fetched;
    } else {
      this.allBooks = this.allBooks.concat(fetched);
    }
    this.rebuildCatalogItems();
    // 服务端按全库分页；客户端再筛小说，用原始页长判断是否还有下一页
    this.hasMore = PaginationHelper.computeHasMore(fetchedRaw.length);
    if (reset && this.allBooks.length === 0) {
      this.errorMessage = '暂无小说';
      this.emptyActionLabel = '去搜索';
    }
  }

  private requestBookList(page: number): Promise<ApiEnvelope> {
    return TalebookService.getAllBooksAsync(page, PaginationConstants.PAGE_SIZE);
  }

  private finishLoad(reset: boolean): void {
    if (reset) {
      this.loading = false;
    } else {
      this.loadingMore = false;
    }
    this.lastLoadTime = Date.now();
  }

  private loadMore(): void {
    if (!PaginationHelper.canLoadMore(this.lastLoadTime, this.loadingMore, this.hasMore)) {
      return;
    }
    this.currentPage += 1;
    this.loadBooks(false);
  }

  /**
   * 下拉刷新：不清空现有列表，避免闪白。
   *
   * 注意：ArkUI 的 Refresh 在进入刷新态时会**先**把双向绑定的 refreshing 置为 true，再回调
   * onRefreshing；所以这里不能用 `this.isRefreshing` 判断重入（那会导致每次下拉都直接返回，
   * 且 isRefreshing 永远回不到 false，Refresh 认为一直在刷新、后续下拉全部被忽略）。
   * 重入保护改用独立的 refreshInFlight 标记。
   */
  private async pullRefresh(): Promise<void> {
    if (this.refreshInFlight) {
      return;
    }
    this.refreshInFlight = true;
    // 组件已置 true，这里显式写一次：保证「提前 return」的路径也处于一致的刷新态
    this.isRefreshing = true;
    try {
      if (this.loading) {
        // 首屏加载还没结束：本次下拉不重复发请求，但仍要收起指示器
        hilog.info(0x0000, 'PULLREFRESH', 'novels: skipped, initial load in flight');
        return;
      }
      this.currentPage = 1;
      this.hasMore = true;
      this.errorMessage = '';
      this.emptyActionLabel = '';
      TalebookService.invalidateNavCache();
      await this.fetchBooksAsync(true, 1);
      hilog.info(0x0000, 'PULLREFRESH', 'novels: done books=%{public}d random=%{public}d err=%{public}s',
        this.allBooks.length, this.randomBooks.length, this.errorMessage);
    } finally {
      this.refreshInFlight = false;
      this.isRefreshing = false;
      this.loading = false;
      this.loadingMore = false;
      this.lastLoadTime = Date.now();
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private handleEmptyAction(): void {
    if (this.emptyActionLabel === '去搜索') {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/TalebookBookSearchPage' });
      return;
    }
    // 「去配置」与「去配置账号」都指向账号与服务器：登录页已移除，配置好账号后由应用自动登录
    this.getUIContext().getRouter().pushUrl({ url: 'pages/TalebookConfigPage' });
  }


  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private openBookDetail(bookId: number): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/BookDetailPage', params: { bookId: bookId } });
  }

  private rebuildCatalogItems(): void {
    this.catalogItems = this.allBooks.map((book: BookSummary): BookListItemData => ({
      id: `${book.id}`,
      title: book.title,
      author: book.author,
      cover: book.cover,
      format: book.format,
      subtitle: book.subtitle,
    }));
  }

  /**
   * 顶部栏：与书架/设置页统一使用 HarmonyTopBar（白底 56vp + 底部 Divider + 20px 标题）。
   * 历史实现是自绘的 34px 粗体大字（无白底、无分隔线），与另两个导航页视觉不一致。
   */
  @Builder
  headerTopBar() {
    HarmonyTopBar({
      title: '小说',
      action: () => {
        this.headerAction();
      },
    });
  }

  @Builder
  headerAction() {
    BookViewToggleButton({ isListMode: $isListMode });
  }

  /**
   * 顶部信息卡：图书总数与书库统计。
   * 规格对齐书架页的胶囊卡片（左右 16 / 圆角 12 / 白底），使三个导航页的顶部层次一致。
   */
  @Builder
  headerSummary() {
    Column({ space: 6 }) {
      Text(this.bookCount > 0 ? `共 ${this.bookCount} 本` : '推荐与全部')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      if (this.libraryStats !== null) {
        Row({ space: 10 }) {
          this.statGroup('总藏书', this.libraryStats.total_books ?? 0);
          this.statSeparator();
          this.statGroup('电子书', this.libraryStats.ebook_count ?? 0);
          this.statSeparator();
          this.statGroup('实体书', this.libraryStats.physical_count ?? 0);
          this.statSeparator();
          this.statGroup('本月新增',
            (this.libraryStats.month_ebook_count ?? 0) + (this.libraryStats.month_physical_count ?? 0));
        }
        .width('100%');
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .margin({ left: 16, right: 16, bottom: 4 })
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  statGroup(label: string, value: number) {
    Row({ space: 4 }) {
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'));
      Text(`${value}`)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'));
    }
  }

  @Builder
  statSeparator() {
    Text('|')
      .fontSize(12)
      .fontColor($r('app.color.text_tertiary'));
  }


  @Builder
  bookContent() {
    Refresh({ refreshing: $$this.isRefreshing }) {
      BookCatalogView({
        items: this.catalogItems,
        isListMode: this.isListMode,
        loadingMore: this.loadingMore,
        header: () => {
          this.homeSections();
        },
        onItemTap: (item: BookListItemData) => this.openBookDetail(Number(item.id)),
        onLoadMore: () => this.loadMore(),
      });
    }
    .layoutWeight(1)
    .width('100%')
    .backgroundColor($r('app.color.page_background'))
    .pullToRefresh(true)
    .refreshOffset(64)
    .onRefreshing(() => {
      void this.pullRefresh();
    });
  }

  @Builder
  homeSections() {
    Column({ space: 16 }) {
      if (this.readingStats !== null) {
        this.readingStatsBanner();
      }
      if (this.homeBooklists.length > 0) {
        this.booklistSection();
      }
      if (this.randomBooks.length > 0) {
        this.randomSection();
      }
      if (this.socialBooks.length > 0) {
        this.socialSection();
      }
      if (this.newBooks.length > 0) {
        this.newSection();
      }
      SectionTitle({ title: '全部小说' });
      if (this.catalogItems.length === 0) {
        this.emptyCatalogHint();
      }
    }
    .width('100%')
    .padding({ top: 4, bottom: 8 });
  }

  @Builder
  readingStatsBanner() {
    Column({ space: 10 }) {
      Text('阅读统计')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'));
      Row() {
        this.readingStatItem(formatDuration(this.readingStats!.totalReadingSeconds), '总阅读时长');
        this.readingStatDivider();
        this.readingStatItem(`${this.readingStats!.downloadCount + this.readingStats!.pushCount}`, '下载/推送');
        this.readingStatDivider();
        this.readingStatItem(`${this.readingStats!.statusReading}`, '在读');
        this.readingStatDivider();
        this.readingStatItem(`${this.readingStats!.statusFinished}`, '读完');
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween);
    }
    .width('100%')
    .padding(16)
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  readingStatItem(value: string, label: string) {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.brand_primary'));
      Text(label)
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'));
    }
    .alignItems(HorizontalAlign.Center);
  }

  @Builder
  readingStatDivider() {
    Divider()
      .vertical(true)
      .height(28)
      .color($r('app.color.divider'))
      .strokeWidth(0.5);
  }

  @Builder
  newSection() {
    Column({ space: 4 }) {
      SectionTitle({ title: '新书推荐' });
      this.coverScroll({ books: this.newBooks, showRecommender: false });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  emptyCatalogHint() {
    Column() {
      Text(this.errorMessage.length > 0 ? this.errorMessage : '暂无小说')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 24, bottom: 8 });
      if (this.emptyActionLabel.length > 0) {
        Text(this.emptyActionLabel)
          .fontSize(14)
          .fontColor($r('app.color.brand_primary'))
          .onClick(() => this.handleEmptyAction());
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 24 })
    .alignItems(HorizontalAlign.Start);
  }



  @Builder
  randomSection() {
    Column({ space: 4 }) {
      SectionTitle({
        title: '为你推荐',
        actionLabel: '换一批',
        onAction: () => this.refreshRandomBooks(),
      });
      this.coverScroll({ books: this.randomBooks, showRecommender: false });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  socialSection() {
    Column({ space: 4 }) {
      SectionTitle({ title: '读者推荐' });
      this.coverScroll({ books: this.socialBooks, showRecommender: true });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  booklistSection() {
    Column({ space: 4 }) {
      SectionTitle({
        title: '推荐书单',
        actionLabel: '全部书单',
        onAction: () => {
          this.getUIContext().getRouter().pushUrl({ url: 'pages/BookListsPage' });
        },
      });
      Scroll() {
        Row({ space: 12 }) {
          ForEach(this.homeBooklists, (item: BookListSummary) => {
            this.booklistCard(item);
          }, (item: BookListSummary) => `home-booklist-${item.id}-${item.bookCount}-${item.likeCount}-${item.isSticky}`);
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

  /**
   * 首页书单卡片：比书单页的 BookListCardItem 更紧凑（固定 3 张封面 + 固定封面区高度），
   * 避免两张卡片高度不一导致横滑行上下跳动。
   */
  @Builder
  booklistCard(item: BookListSummary) {
    Column({ space: 6 }) {
      Row({ space: 4 }) {
        Text(item.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        if (!item.isPublic) {
          SymbolGlyph($r('sys.symbol.lock'))
            .fontSize(13)
            .fontColor([$r('app.color.text_tertiary')]);
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);
      Text(item.description.length > 0 ? item.description : '暂无简介')
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');
      Column() {
        if (item.coverBooks.length === 0) {
          Text('书单暂无书籍')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'));
        } else {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(item.coverBooks.slice(0, 3), (cover: BookListCoverBook) => {
              AuthImage({
                url: cover.thumb.length > 0 ? cover.thumb : cover.img,
                imageWidth: 46,
                imageHeight: 63,
              })
                .margin({ right: 6 });
            }, (cover: BookListCoverBook) => `home-bl-${item.id}-${cover.bookId}`);
          }
          .width('100%');
        }
      }
      .width('100%')
      .height(63)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Start);
      Row({ space: 12 }) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.book'))
            .fontSize(11)
            .fontColor([$r('app.color.text_tertiary')]);
          Text(`${item.bookCount}`)
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'));
        }
        .alignItems(VerticalAlign.Center);
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.heart'))
            .fontSize(11)
            .fontColor([$r('app.color.text_tertiary')]);
          Text(`${item.likeCount}`)
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'));
        }
        .alignItems(VerticalAlign.Center);
        Blank().layoutWeight(1);
        if (item.owner !== null) {
          Text(item.owner.username)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .constraintSize({ maxWidth: 80 });
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);
    }
    .width(224)
    .padding(12)
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .border({
      width: { left: 3 },
      color: { left: booklistColorHex(item.color) },
      // 圆角必须写进 border：先 borderRadius 再 border 会重置圆角
      radius: $r('app.float.card_radius'),
    })
    .alignItems(HorizontalAlign.Start)
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(() => {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/BookListDetailPage',
        params: { booklistId: item.id },
      });
    });
  }

  @Builder
  coverScroll(spec: CoverRowSpec) {
    Scroll() {
      Row({ space: 14 }) {
        ForEach(spec.books, (book: HomeBook) => {
          this.coverTile(book, spec.showRecommender);
        }, (book: HomeBook) => `home-${book.id}`);
      }
      .padding({ left: 16, right: 16 });
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%');
  }

  @Builder
  coverTile(book: HomeBook, showRecommender: boolean) {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        AuthImage({
          url: book.cover,
          imageWidth: 110,
          imageHeight: 154,
        });
        if (showRecommender && book.recommender !== null) {
          Row({ space: 4 }) {
            if (book.recommender.avatar.length > 0) {
              Column() {
                AuthImage({
                  url: book.recommender.avatar,
                  imageWidth: 16,
                  imageHeight: 16,
                });
              }
              .borderRadius(8)
              .clip(true);
            }
            Text(book.recommender.nickname)
              .fontSize(9)
              .fontColor(Color.White)
              .maxLines(1);
          }
          .padding({ left: 4, right: 4, top: 2, bottom: 2 })
          .borderRadius($r('app.float.badge_radius'))
          .backgroundColor('#B3000000')
          .margin(4);
        }
      }
      Text(book.title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(110);
    }
    .alignItems(HorizontalAlign.Start)
    .onClick(() => this.openBookDetail(book.id));
  }

  private refreshRandomBooks(): void {
    TalebookApi.getIndexHome()
      .then((data: IndexHomeData) => {
        this.randomBooks = this.resolveHomeBooks(data.randomBooks);
      })
      .catch(() => {});
  }


  build() {
    Column() {
      this.headerTopBar();
      this.headerSummary();
      if (this.loading && this.allBooks.length === 0 &&
        this.randomBooks.length === 0 && this.socialBooks.length === 0) {
        LoadingState({})
          .layoutWeight(1);
      } else {
        this.bookContent();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .linearGradient({
      angle: 180,
      colors: [[$r('app.color.page_background'), 0.0], [$r('app.color.page_background'), 1.0]],
    });
  }
}
