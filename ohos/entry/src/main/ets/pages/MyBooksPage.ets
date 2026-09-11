import { router } from '@kit.ArkUI';
import {
  PageScaffold, BookCatalogView, BookViewToggleButton, BookListItemData,
  LoadingState, EmptyState,
} from '../components';
import { ApiEnvelope, TalebookService } from '../services/TalebookService';
import { TalebookApi } from '../services/TalebookApi';
import { PaginationConstants, PaginationHelper } from '../utils/PaginationHelper';
import { BookViewMode } from '../utils/BookViewMode';
import { mapTalebookBook } from '../utils/BookMapper';

@Entry
@Component
struct MyBooksPage {
  @State books: Record<string, Object>[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State currentPage: number = 1;
  @State hasMore: boolean = true;
  @State isAdmin: boolean = false;
  @State isListMode: boolean = false;
  @State catalogItems: BookListItemData[] = [];
  private lastLoadTime: number = 0;
  private username: string = '';

  aboutToAppear(): void {
    this.isListMode = BookViewMode.isListMode();
    void this.loadProfileAndBooks(true);
  }

  private async loadProfileAndBooks(reset: boolean = true): Promise<void> {
    if (reset) {
      this.currentPage = 1;
      this.hasMore = true;
      this.books = [];
      this.loading = true;
    } else {
      this.loadingMore = true;
    }
    const page = this.currentPage;
    try {
      if (TalebookService.hasAuthCredentials()) {
        await TalebookService.ensureAuthenticated();
      }
      if (this.username.length === 0) {
        const userEnvelope = await TalebookService.getUserInfoAsync();
        const userBody = userEnvelope.body ?? {};
        const user = (userBody['user'] as Record<string, Object> | undefined) ?? userBody;
        this.username = String(user['username'] ?? '');
        const role = String(user['role'] ?? user['is_admin'] ?? '');
        this.isAdmin = role === 'admin' || role === '1' || Boolean(user['is_admin']);
      }

      let fetched: Record<string, Object>[] = [];
      if (this.isAdmin) {
        const rsp = await TalebookApi.getAdminBookList(page, PaginationConstants.PAGE_SIZE);
        if (rsp.err === undefined || rsp.err === 'ok') {
          fetched = rsp.items ?? [];
        }
      } else {
        const envelope: ApiEnvelope =
          await TalebookService.getReadingListAsync(page, PaginationConstants.PAGE_SIZE);
        const body = envelope.body ?? {};
        fetched = (body['books'] as Record<string, Object>[] | undefined) ?? [];
      }
      if (!this.isAdmin && this.username.length > 0) {
        fetched = fetched.filter((book: Record<string, Object>) =>
          String(book['collector'] ?? '') === this.username);
      }
      if (reset) {
        this.books = fetched;
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

  private loadMore(): void {
    if (!PaginationHelper.canLoadMore(this.lastLoadTime, this.loadingMore, this.hasMore)) {
      return;
    }
    this.currentPage += 1;
    void this.loadProfileAndBooks(false);
  }

  @Builder
  viewModeAction() {
    BookViewToggleButton({ isListMode: $isListMode });
  }

  build() {
    Column() {
      PageScaffold({
        title: '我的书籍',
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
    } else if (this.books.length === 0) {
      EmptyState({ message: '暂无书籍' });
    } else {
      BookCatalogView({
        items: this.catalogItems,
        isListMode: this.isListMode,
        loadingMore: this.loadingMore,
        onItemTap: (item: BookListItemData) => router.pushUrl({
          url: 'pages/BookDetailPage', params: { bookId: Number(item.id) }
        }),
        onLoadMore: () => this.loadMore(),
      });
    }
  }
}
