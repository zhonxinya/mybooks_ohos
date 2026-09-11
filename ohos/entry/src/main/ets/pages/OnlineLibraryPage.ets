/**
 * 在线书库（Talebook `GET /api/library/online`）。
 *
 * 上游 `NetworkLibraryOnline.get` 通过 `render_book_list` 返回**标准书籍列表**
 * （`{err, title, total, books:[...]}`），支持 `start`（偏移）+ `size`（每页），
 * 每本书额外带 `serialize_status`（serial / finished / unknown），可按其筛选。
 */
import { router } from '@kit.ArkUI';
import {
  PageScaffold, BookCatalogView, BookViewToggleButton, BookListItemData,
  LoadingState, EmptyState, FilterChips, FilterChipItem,
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { apiErrorMessage } from '../services/TalebookApi';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import {
  BookListResponse, OnlineBookStatus, ShelfApi, isShelfApiOk,
} from '../services/ShelfApi';
import { PaginationConstants, PaginationHelper } from '../utils/PaginationHelper';
import { BookViewMode } from '../utils/BookViewMode';
import { mapTalebookBook } from '../utils/BookMapper';

@Entry
@Component
struct OnlineLibraryPage {
  @State selectedStatus: number = 0;
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State isRefreshing: boolean = false;
  @State isListMode: boolean = false;
  @State catalogItems: BookListItemData[] = [];
  @State currentPage: number = 1;
  @State hasMore: boolean = false;
  @State total: number = 0;
  @State loadError: string = '';
  private statusItems: FilterChipItem[] = [
    { label: '全部', value: 0 },
    { label: '连载中', value: 1 },
    { label: '已完结', value: 2 },
    { label: '未知', value: 3 },
  ];
  private statusValues: string[] = [
    OnlineBookStatus.ALL, OnlineBookStatus.SERIAL,
    OnlineBookStatus.FINISHED, OnlineBookStatus.UNKNOWN,
  ];
  private lastLoadTime: number = 0;
  private featureSupported: boolean = ServerRegistry.supports(ServerFeature.LIBRARY_ONLINE);

  aboutToAppear(): void {
    this.isListMode = BookViewMode.isListMode();
    if (!this.featureSupported) {
      this.loading = false;
      return;
    }
    void this.loadBooks(true);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private currentStatus(): string {
    return this.statusValues[this.selectedStatus] ?? OnlineBookStatus.ALL;
  }

  private async loadBooks(reset: boolean): Promise<void> {
    if (reset) {
      // 下拉刷新时保留现有列表，避免闪白
      if (!this.isRefreshing) {
        this.loading = true;
      }
      this.loadError = '';
      this.currentPage = 1;
      this.catalogItems = [];
      this.hasMore = false;
    } else {
      this.loadingMore = true;
    }
    const page = this.currentPage;
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.loadError = '请先配置服务器';
        return;
      }
      if (TalebookService.hasAuthCredentials()) {
        await TalebookService.ensureAuthenticated();
      }
      const rsp: BookListResponse = await ShelfApi.getOnlineLibrary(
        (page - 1) * PaginationConstants.PAGE_SIZE, PaginationConstants.PAGE_SIZE, this.currentStatus());
      if (!isShelfApiOk(rsp)) {
        this.handleLoadFailure(reset, apiErrorMessage(rsp));
        return;
      }
      const fetched = rsp.books ?? [];
      const mapped = fetched.map((book: Record<string, Object>) => this.mapBook(book));
      if (reset) {
        this.catalogItems = mapped;
      } else {
        this.catalogItems = this.catalogItems.concat(mapped);
      }
      this.total = rsp.total ?? this.catalogItems.length;
      this.hasMore = PaginationHelper.computeHasMore(fetched.length);
    } catch (error) {
      this.handleLoadFailure(reset, error instanceof Error ? error.message : `${error}`);
    } finally {
      this.loading = false;
      this.loadingMore = false;
      this.lastLoadTime = Date.now();
    }
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
    void this.loadBooks(false);
  }

  private async pullRefresh(): Promise<void> {
    if (this.isRefreshing || this.loading) {
      return;
    }
    this.isRefreshing = true;
    try {
      await this.loadBooks(true);
    } finally {
      this.isRefreshing = false;
    }
  }

  private statusLabel(value: string): string {
    if (value === OnlineBookStatus.SERIAL) {
      return '连载中';
    }
    if (value === OnlineBookStatus.FINISHED) {
      return '已完结';
    }
    if (value === OnlineBookStatus.UNKNOWN) {
      return '状态未知';
    }
    return '';
  }

  /** 在公共书籍映射之上补充连载状态副标题。 */
  private mapBook(book: Record<string, Object>): BookListItemData {
    const item = mapTalebookBook(book);
    const status = this.statusLabel(String(book['serialize_status'] ?? ''));
    if (status.length > 0) {
      item.subtitle = item.subtitle !== undefined && item.subtitle.length > 0 ?
        `${status} · ${item.subtitle}` : status;
    }
    return item;
  }

  @Builder
  viewModeAction() {
    BookViewToggleButton({ isListMode: $isListMode });
  }

  build() {
    Column() {
      PageScaffold({
        title: '在线书库',
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
        message: `${ServerRegistry.profile().displayName} 服务端不支持在线书库`,
        detail: '当前服务端未提供网络书库列表接口。',
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
      EmptyState({ message: '在线书库暂无书籍', detail: '可先通过网络书源搜索并保存书籍。' });
    } else {
      Column() {
        FilterChips({
          items: this.statusItems,
          selected: $selectedStatus,
          onChange: () => {
            void this.loadBooks(true);
          },
        });
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
      .width('100%')
      .height('100%');
    }
  }

  @Builder
  listHeader() {
    Text(this.total > 0 ? `共 ${this.total} 本` : '在线书库')
      .fontSize(12)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 });
  }
}
