/**
 * 我的书架（Talebook `/api/shelf`）。
 *
 * 上游 `BookShelf.get` 一次性返回全部在架书籍且不支持 `start`/`size`，
 * 因此分页在本地完成：每次「加载更多」先重新拉取一次书架（保证其它端加入/移出的书籍可见），
 * 再按 `PaginationConstants.PAGE_SIZE` 展开展示。
 */
import { router } from '@kit.ArkUI';
import {
  PageScaffold, BookCatalogView, BookViewToggleButton, BookListItemData,
  LoadingState, EmptyState,
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { apiErrorMessage } from '../services/TalebookApi';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { BookListResponse, ShelfApi, isShelfApiOk } from '../services/ShelfApi';
import { PaginationConstants, PaginationHelper } from '../utils/PaginationHelper';
import { BookViewMode } from '../utils/BookViewMode';
import { mapTalebookBook } from '../utils/BookMapper';

@Entry
@Component
struct ShelfPage {
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State isRefreshing: boolean = false;
  @State isListMode: boolean = false;
  @State catalogItems: BookListItemData[] = [];
  @State currentPage: number = 1;
  @State hasMore: boolean = false;
  @State total: number = 0;
  @State loadError: string = '';
  /** 服务端返回的完整书架（本地分页的数据源）。 */
  private shelfBooks: Record<string, Object>[] = [];
  private lastLoadTime: number = 0;
  private featureSupported: boolean = ServerRegistry.supports(ServerFeature.BOOK_SHELF);

  aboutToAppear(): void {
    this.isListMode = BookViewMode.isListMode();
    if (!this.featureSupported) {
      this.loading = false;
      return;
    }
    void this.loadShelf(true);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** 首屏/下拉刷新传 reset=true；加载更多传 false（页码已自增）。 */
  private async loadShelf(reset: boolean): Promise<void> {
    if (reset) {
      // 下拉刷新时保留现有列表，避免闪白（Refresh 自带进度指示）
      if (!this.isRefreshing) {
        this.loading = true;
      }
      this.loadError = '';
      this.currentPage = 1;
      this.shelfBooks = [];
      this.catalogItems = [];
      this.hasMore = false;
    } else {
      this.loadingMore = true;
    }
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.loadError = '请先配置服务器';
        return;
      }
      if (TalebookService.hasAuthCredentials()) {
        await TalebookService.ensureAuthenticated();
      }
      const rsp: BookListResponse = await ShelfApi.getShelf();
      if (!isShelfApiOk(rsp)) {
        this.handleLoadFailure(reset, apiErrorMessage(rsp));
        return;
      }
      this.shelfBooks = rsp.books ?? [];
      this.total = rsp.total ?? this.shelfBooks.length;
      this.applyPage();
    } catch (error) {
      this.handleLoadFailure(reset, error instanceof Error ? error.message : `${error}`);
    } finally {
      this.loading = false;
      this.loadingMore = false;
      this.lastLoadTime = Date.now();
    }
  }

  /** 按当前页码截取展示数据；`hasMore` 基于本地剩余条数判断。 */
  private applyPage(): void {
    const pageBooks = this.shelfBooks.slice(0, this.currentPage * PaginationConstants.PAGE_SIZE);
    this.catalogItems = pageBooks.map((book: Record<string, Object>) => mapTalebookBook(book));
    this.hasMore = pageBooks.length < this.shelfBooks.length;
  }

  /** 失败处理：首屏进错误态，加载更多则 toast 提示并回退页码。 */
  private handleLoadFailure(reset: boolean, message: string): void {
    const text = message.length > 0 ? message : '加载失败';
    if (reset) {
      this.loadError = text;
      return;
    }
    this.toast(text);
    this.currentPage = Math.max(1, this.currentPage - 1);
  }

  private loadMore(): void {
    if (!PaginationHelper.canLoadMore(this.lastLoadTime, this.loadingMore, this.hasMore)) {
      return;
    }
    this.currentPage += 1;
    void this.loadShelf(false);
  }

  private async pullRefresh(): Promise<void> {
    if (this.isRefreshing || this.loading) {
      return;
    }
    this.isRefreshing = true;
    try {
      await this.loadShelf(true);
    } finally {
      this.isRefreshing = false;
    }
  }

  private confirmRemove(item: BookListItemData): void {
    this.getUIContext().showAlertDialog({
      title: '移出书架',
      message: `确定将《${item.title}》移出书架吗？`,
      primaryButton: {
        value: '移出',
        action: () => {
          void this.removeFromShelf(Number(item.id));
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private async removeFromShelf(bookId: number): Promise<void> {
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await ShelfApi.setShelf(bookId, false);
      if (!isShelfApiOk(rsp)) {
        this.toast(apiErrorMessage(rsp));
        return;
      }
      this.toast('已移出书架');
      // 本地同步移除，避免整页重回加载态
      const remain: Record<string, Object>[] = [];
      for (let i = 0; i < this.shelfBooks.length; i++) {
        const book = this.shelfBooks[i];
        if (Number(book['id'] ?? 0) !== bookId) {
          remain.push(book);
        }
      }
      this.shelfBooks = remain;
      this.total = Math.max(0, this.total - 1);
      this.applyPage();
    } catch (error) {
      this.toast(`操作失败：${error}`);
    }
  }

  @Builder
  viewModeAction() {
    BookViewToggleButton({ isListMode: $isListMode });
  }

  @Builder
  listHeader() {
    Text(this.total > 0 ? `共 ${this.total} 本` : '长按书籍可移出书架')
      .fontSize(12)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 });
  }

  build() {
    Column() {
      PageScaffold({
        title: '我的书架',
        showBack: true,
        action: () => {
          this.viewModeAction();
        },
        content: () => {
          this.pageContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  pageContent() {
    if (!this.featureSupported) {
      EmptyState({
        message: `${ServerRegistry.profile().displayName} 服务端不支持书架`,
        detail: '当前服务端未提供书架接口。',
      });
    } else if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      EmptyState({
        message: this.loadError,
        actionLabel: this.loadError.includes('配置') ? '去配置' : '',
        onAction: () => router.pushUrl({ url: 'pages/TalebookConfigPage' }),
      });
    } else if (this.catalogItems.length === 0) {
      EmptyState({
        message: '书架还没有书',
        detail: '在书籍详情页把想读的书加入书架。',
      });
    } else {
      Refresh({ refreshing: $$this.isRefreshing }) {
        BookCatalogView({
          items: this.catalogItems,
          isListMode: this.isListMode,
          loadingMore: this.loadingMore,
          header: () => {
            this.listHeader();
          },
          onItemTap: (item: BookListItemData) => router.pushUrl({
            url: 'pages/BookDetailPage', params: { bookId: Number(item.id) }
          }),
          onItemLongPress: (item: BookListItemData) => this.confirmRemove(item),
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
  }
}
