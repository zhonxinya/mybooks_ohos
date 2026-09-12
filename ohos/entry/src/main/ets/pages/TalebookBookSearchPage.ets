import {
  PageScaffold, SearchBar, BookCatalogView, BookViewToggleButton, BookListItemData,
  LoadingState, EmptyState, FilterChips, FilterChipItem,
} from '../components';
import { TalebookService, ApiEnvelope } from '../services/TalebookService';
import { PaginationConstants, PaginationHelper } from '../utils/PaginationHelper';
import { BookViewMode } from '../utils/BookViewMode';
import { mapTalebookBook } from '../utils/BookMapper';

@Entry
@Component
struct TalebookBookSearchPage {
  @State keyword: string = '';
  @State books: Record<string, Object>[] = [];
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State searched: boolean = false;
  @State currentPage: number = 1;
  @State hasMore: boolean = true;
  @State resultTitle: string = '';
  @State resultTotal: number = -1;
  @State isListMode: boolean = false;
  @State catalogItems: BookListItemData[] = [];
  @State searchScope: number = 0;
  private lastLoadTime: number = 0;
  private searchTimer: number = -1;
  private scopeItems: FilterChipItem[] = [
    { label: '全部', value: 0 },
    { label: '书名', value: 1 },
    { label: '作者', value: 2 },
  ];

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  aboutToAppear(): void {
    this.isListMode = BookViewMode.isListMode();
    this.ensureTalebookUrl();
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object> | undefined;
    const initial = String(params?.['keyword'] ?? '').trim();
    if (initial.length > 0) {
      this.keyword = initial;
      this.search(true);
    }
  }

  private ensureTalebookUrl(): void {
    const url = TalebookService.secureGet('talebook_url');
    if (url.length > 0) {
      TalebookService.setBaseUrl('talebook', url);
    }
  }

  private scheduleSearch(): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
    }
    this.searchTimer = setTimeout(() => {
      this.search(true);
    }, PaginationConstants.DEBOUNCE_MS);
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private search(reset: boolean = true): void {
    const trimmed = this.keyword.trim();
    if (trimmed.length === 0) {
      return;
    }
    // 对齐 Web 端 AppHeader 分类范围：书名/作者用 calibre 前缀查询
    let query = trimmed;
    if (this.searchScope === 1) {
      query = `title:${trimmed}`;
    } else if (this.searchScope === 2) {
      query = `author:${trimmed}`;
    }
    void this.searchAsync(reset, query);
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async searchAsync(reset: boolean, trimmed: string): Promise<void> {
    this.ensureTalebookUrl();
    if (reset) {
      this.currentPage = 1;
      this.hasMore = true;
      this.books = [];
      this.catalogItems = [];
      this.resultTitle = '';
      this.resultTotal = -1;
      this.loading = true;
    } else {
      this.loadingMore = true;
    }
    this.searched = true;
    const page = this.currentPage;
    try {
      if (TalebookService.hasAuthCredentials()) {
        await TalebookService.ensureAuthenticated();
      }
      const envelope: ApiEnvelope = await TalebookService.searchAsync(trimmed, page, PaginationConstants.PAGE_SIZE);
      if (!TalebookService.isApiSuccess(envelope)) {
        this.getUIContext().getPromptAction().showToast({
          message: envelope.error.length > 0 ? envelope.error : '搜索失败',
        });
        if (!reset) {
          this.currentPage = Math.max(1, this.currentPage - 1);
        }
        return;
      }
      const body = envelope.body ?? {};
      const fetched = (body['books'] as Record<string, Object>[] | undefined) ?? [];
      if (reset) {
        this.books = fetched;
        this.resultTitle = String(body['title'] ?? '');
        this.resultTotal = Number(body['total'] ?? -1);
      } else {
        this.books = this.books.concat(fetched);
      }
      this.catalogItems = this.books.map((book: Record<string, Object>) => mapTalebookBook(book));
      this.hasMore = PaginationHelper.computeHasMore(fetched.length);
    } finally {
      this.loading = false;
      this.loadingMore = false;
      this.lastLoadTime = Date.now();
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private loadMore(): void {
    if (!PaginationHelper.canLoadMore(this.lastLoadTime, this.loadingMore, this.hasMore)) {
      return;
    }
    this.currentPage += 1;
    this.search(false);
  }

  private resultSubtitle(): string {
    if (this.resultTotal >= 0) {
      return `共 ${this.resultTotal} 本`;
    }
    if (this.books.length > 0) {
      return `已显示 ${this.books.length} 本`;
    }
    return '';
  }

  @Builder
  viewModeAction() {
    BookViewToggleButton({ isListMode: $isListMode });
  }

  build() {
    Column() {
      PageScaffold({
        title: '搜索',
        showBack: true,
        action: () => {
          this.viewModeAction();
        },
        content: () => {
          this.searchContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  searchContent() {
    Column() {
      SearchBar({
        placeholder: '搜索书名或作者',
        keyword: $keyword,
        onSearch: () => this.scheduleSearch(),
      });
      FilterChips({
        items: this.scopeItems,
        selected: $searchScope,
        onChange: () => this.scheduleSearch(),
      });
      if (this.loading) {
        LoadingState({});
      } else if (!this.searched) {
        EmptyState({ message: '输入关键词后搜索书籍' });
      } else if (this.books.length === 0) {
        EmptyState({ message: '未找到相关书籍' });
      } else {
        if (this.resultTitle.length > 0 || this.resultSubtitle().length > 0) {
          Row() {
            Text(this.resultTitle.length > 0 ? this.resultTitle : '搜索结果')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1);
            if (this.resultSubtitle().length > 0) {
              Text(this.resultSubtitle())
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'));
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 4 });
        }
        BookCatalogView({
          items: this.catalogItems,
          isListMode: this.isListMode,
          loadingMore: this.loadingMore,
          onItemTap: (item: BookListItemData) => this.getUIContext().getRouter().pushUrl({
            url: 'pages/BookDetailPage', params: { bookId: Number(item.id) }
          }),
          onLoadMore: () => this.loadMore(),
        });
      }
    }
    .width('100%')
    .height('100%');
  }
}
