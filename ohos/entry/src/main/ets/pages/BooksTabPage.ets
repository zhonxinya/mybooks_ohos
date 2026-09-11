import { router } from '@kit.ArkUI';
import {
  BookCatalogView, BookViewToggleButton, BookListItemData, LoadingState,
  SectionTitle, AuthImage,
} from '../components';
import { ApiEnvelope, TalebookService } from '../services/TalebookService';
import { TalebookApi, IndexHomeData, LibraryStatsResponse, LibraryStatsData } from '../services/TalebookApi';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { HomeBook, ReadingDashboard, formatDuration } from '../models/HomeModels';
import { PaginationConstants, PaginationHelper } from '../utils/PaginationHelper';
import { BookViewMode } from '../utils/BookViewMode';

interface BookSummary {
  id: number;
  title: string;
  author: string;
  cover: string;
  format: string;
  subtitle: string;
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
  @State isRefreshing: boolean = false;
  private lastLoadTime: number = 0;

  aboutToAppear(): void {
    this.isListMode = BookViewMode.isListMode();
    void this.loadBooks(true);
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
    const format = this.collectFormatText(item);
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
      if (this.isNovelBook(raw, summary.format)) {
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
        this.emptyActionLabel = TalebookService.hasAuthCredentials() ? '' : '去登录';
      }
    } finally {
      this.finishLoad(reset);
    }
  }

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

  private async fetchBookListAsync(reset: boolean, page: number): Promise<void> {
    await this.applyBookListEnvelope(reset, await this.requestBookList(page));
  }

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
        this.emptyActionLabel = TalebookService.hasAuthCredentials() ? '' : '去登录';
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

  /** 下拉刷新：不清空现有列表，避免闪白 */
  private async pullRefresh(): Promise<void> {
    if (this.isRefreshing || this.loading) {
      return;
    }
    this.isRefreshing = true;
    this.currentPage = 1;
    this.hasMore = true;
    this.errorMessage = '';
    this.emptyActionLabel = '';
    TalebookService.invalidateNavCache();
    try {
      await this.fetchBooksAsync(true, 1);
    } finally {
      this.isRefreshing = false;
      this.loading = false;
      this.loadingMore = false;
      this.lastLoadTime = Date.now();
    }
  }

  private handleEmptyAction(): void {
    if (this.emptyActionLabel === '去配置') {
      router.pushUrl({ url: 'pages/TalebookConfigPage' });
      return;
    }
    if (this.emptyActionLabel === '去搜索') {
      router.pushUrl({ url: 'pages/TalebookBookSearchPage' });
      return;
    }
    router.pushUrl({ url: 'pages/LoginPage' });
  }


  private openBookDetail(bookId: number): void {
    router.pushUrl({ url: 'pages/BookDetailPage', params: { bookId: bookId } });
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

  @Builder
  pageHeader() {
    Column({ space: 4 }) {
      Row() {
        Column({ space: 2 }) {
          Text('小说')
            .fontSize(34)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'));
          Text(this.bookCount > 0 ? `共 ${this.bookCount} 本` :
            '推荐与全部')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'));
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
        BookViewToggleButton({ isListMode: $isListMode });
      }
      .width('100%')
      .padding({ top: 4 });
      if (this.libraryStats !== null) {
        Row({ space: 10 }) {
          this.statGroup('总藏书', this.libraryStats.total_books ?? 0);
          this.statSeparator();
          this.statGroup('电子书', this.libraryStats.ebook_count ?? 0);
          this.statSeparator();
          this.statGroup('实体书', this.libraryStats.physical_count ?? 0);
          this.statSeparator();
          this.statGroup('本月新增', (this.libraryStats.month_ebook_count ?? 0) + (this.libraryStats.month_physical_count ?? 0));
        }
        .width('100%')
        .margin({ top: 6 });
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 2 });
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
      this.coverScroll(this.newBooks, false);
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
      this.coverScroll(this.randomBooks, false);
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  socialSection() {
    Column({ space: 4 }) {
      SectionTitle({ title: '读者推荐' });
      this.coverScroll(this.socialBooks, true);
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  coverScroll(books: HomeBook[], showRecommender: boolean) {
    Scroll() {
      Row({ space: 14 }) {
        ForEach(books, (book: HomeBook) => {
          this.coverTile(book, showRecommender);
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
          .borderRadius(9)
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
      this.pageHeader();
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
