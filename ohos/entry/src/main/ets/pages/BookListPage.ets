import {
  PageScaffold, BookCatalogView, BookViewToggleButton, BookListItemData,
  LoadingState, EmptyState,
} from '../components';
import { TalebookService, ApiEnvelope } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { PaginationConstants, PaginationHelper } from '../utils/PaginationHelper';
import { BookViewMode } from '../utils/BookViewMode';
import { mapTalebookBook } from '../utils/BookMapper';

@Entry
@Component
struct BookListPage {
  @State listType: string = 'recent';
  @State metaType: string = '';
  @State metaName: string = '';
  @State books: Record<string, Object>[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State currentPage: number = 1;
  @State hasMore: boolean = true;
  @State isListMode: boolean = false;
  @State errorMessage: string = '';
  @State catalogItems: BookListItemData[] = [];
  private lastLoadTime: number = 0;

  aboutToAppear(): void {
    this.isListMode = BookViewMode.isListMode();
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    this.listType = String(params['type'] ?? 'recent');
    this.metaType = String(params['metaType'] ?? '');
    this.metaName = String(params['metaName'] ?? '');
    void this.prepareAndLoad(true);
  }

  private async prepareAndLoad(reset: boolean): Promise<void> {
    if (TalebookService.hasAuthCredentials()) {
      await TalebookService.ensureAuthenticated();
    }
    await this.loadBooks(reset);
  }

  private async loadBooks(reset: boolean = true): Promise<void> {
    if (reset) {
      this.currentPage = 1;
      this.hasMore = true;
      this.books = [];
      this.loading = true;
      this.errorMessage = '';
    } else {
      this.loadingMore = true;
    }
    const page = this.currentPage;
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.errorMessage = '请先配置 Talebook 服务器';
        return;
      }
      let envelope: ApiEnvelope;
      if (this.listType === 'hot') {
        envelope = await TalebookService.getHotAsync(page, PaginationConstants.PAGE_SIZE);
      } else if (this.listType === 'all') {
        envelope = await TalebookService.getAllBooksAsync(page, PaginationConstants.PAGE_SIZE);
      } else if (this.listType === 'audiobooks') {
        envelope = await TalebookService.getServerBookListAsync(ServerRegistry.audiobooksPath(), page,
          PaginationConstants.PAGE_SIZE);
      } else if (this.listType === 'printbooks') {
        if (!ServerRegistry.supports(ServerFeature.PRINT_BOOKS)) {
          this.errorMessage = `${ServerRegistry.profile().displayName} 服务端不支持实体书列表`;
          return;
        }
        envelope = await TalebookService.getServerBookListAsync('/api/printbooks', page,
          PaginationConstants.PAGE_SIZE);
      } else if (this.listType === 'meta' && this.metaType.length > 0) {
        envelope = await TalebookService.getMetaBooksAsync(this.metaType, this.metaName, page,
          PaginationConstants.PAGE_SIZE);
      } else if (this.listType === 'category' && this.metaName.length > 0) {
        envelope = await TalebookService.searchAsync(`#category:=${this.metaName}`, page,
          PaginationConstants.PAGE_SIZE);
      } else {
        envelope = await TalebookService.getRecentAsync(page, PaginationConstants.PAGE_SIZE);
      }
      if (!TalebookService.isApiSuccess(envelope)) {
        if (reset) {
          this.errorMessage = envelope.error.length > 0 ? envelope.error : '加载失败';
        } else {
          this.getUIContext().getPromptAction().showToast({
            message: envelope.error.length > 0 ? envelope.error : '加载更多失败',
          });
          this.currentPage = Math.max(1, this.currentPage - 1);
        }
        return;
      }
      const body = envelope.body ?? {};
      const fetched = (body['books'] as Record<string, Object>[] | undefined) ?? [];
      if (reset) {
        this.books = fetched;
      } else {
        this.books = this.books.concat(fetched);
      }
      this.catalogItems = this.books.map((book: Record<string, Object>) => mapTalebookBook(book));
      this.hasMore = PaginationHelper.computeHasMore(fetched.length);
    } catch (error) {
      if (reset) {
        this.errorMessage = error instanceof Error ? error.message : `${error}`;
      }
    } finally {
      this.loading = false;
      this.loadingMore = false;
      this.lastLoadTime = Date.now();
    }
  }

  private loadMore(): void {
    if (!PaginationHelper.canLoadMore(this.lastLoadTime, this.loadingMore, this.hasMore)) {
      return;
    }
    this.currentPage += 1;
    void this.loadBooks(false);
  }

  private metaTypeLabel(): string {
    switch (this.metaType) {
      case 'author':
        return '作者';
      case 'tag':
        return '标签';
      case 'series':
        return '丛书';
      case 'publisher':
        return '出版社';
      case 'rating':
        return '评分';
      case 'language':
        return '语言';
      default:
        return '相关';
    }
  }

  private pageTitle(): string {
    if (this.listType === 'hot') {
      return '热门';
    }
    if (this.listType === 'all') {
      return '全部书籍';
    }
    if (this.listType === 'audiobooks') {
      return '有声书';
    }
    if (this.listType === 'printbooks') {
      return '实体书';
    }
    if (this.listType === 'meta') {
      if (this.metaName.length > 0) {
        return `${this.metaTypeLabel()}：${this.metaName}`;
      }
      return '相关书籍';
    }
    if (this.listType === 'category' && this.metaName.length > 0) {
      return `分类：${this.metaName}`;
    }
    return '最近更新';
  }

  @Builder
  viewModeAction() {
    BookViewToggleButton({ isListMode: $isListMode });
  }

  build() {
    Column() {
      PageScaffold({
        title: this.pageTitle(),
        showBack: true,
        action: () => {
          this.viewModeAction();
        },
        content: () => {
          this.listContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  listContent() {
    if (this.loading) {
      LoadingState({});
    } else if (this.errorMessage.length > 0) {
      EmptyState({ message: this.errorMessage });
    } else if (this.books.length === 0) {
      EmptyState({
        message: (this.listType === 'meta' || this.listType === 'category') && this.metaName.length > 0 ?
          `「${this.metaName}」暂无更多书籍` : '暂无书籍',
      });
    } else {
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
}
