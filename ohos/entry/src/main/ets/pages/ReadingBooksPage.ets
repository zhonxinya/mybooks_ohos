import {
  PageScaffold, FilterChips, FilterChipItem, BookCatalogView, BookViewToggleButton,
  BookListItemData, LoadingState, EmptyState, PrimaryButton,
} from '../components';
import { ApiEnvelope, TalebookService } from '../services/TalebookService';
import { TalebookApi } from '../services/TalebookApi';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { BookItem as ApiBookItem } from '../services/BookModels';
import { PaginationConstants, PaginationHelper } from '../utils/PaginationHelper';
import { BookViewMode } from '../utils/BookViewMode';

interface BookItem {
  id: number;
  title: string;
  author: string;
  cover: string;
}

@Entry
@Component
struct ReadingBooksPage {
  @State activeTab: number = 0;
  @State books: BookItem[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State currentPage: number = 1;
  @State hasMore: boolean = true;
  @State isListMode: boolean = false;
  @State catalogItems: BookListItemData[] = [];
  @State loadError: string = '';
  @State manageMode: boolean = false;
  @State selectedIds: number[] = [];
  @State removing: boolean = false;
  private allFilters: FilterChipItem[] = [
    { label: '在读', value: 0 },
    { label: '收藏', value: 1 },
    { label: '想读', value: 2 },
    { label: '读完', value: 3 },
    { label: '私有书', value: 4 },
  ];
  /** value 保持逻辑索引不变，仅按服务端能力决定是否展示该页签。 */
  private filterItems: FilterChipItem[] = this.allFilters.filter((item: FilterChipItem): boolean => {
    if (item.value === 2) {
      return ServerRegistry.supports(ServerFeature.BOOK_WANTS);
    }
    if (item.value === 4) {
      return ServerRegistry.supports(ServerFeature.SCOPED_BOOKS);
    }
    return true;
  });
  private lastLoadTime: number = 0;

  aboutToAppear(): void {
    this.isListMode = BookViewMode.isListMode();
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object> | null;
    this.activeTab = params?.['tab'] === 'favorites' ? 1 : 0;
    void this.loadBooks(true);
  }

  private async loadBooks(reset: boolean = true): Promise<void> {
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
      let fetched: BookItem[] = [];
      if (this.activeTab === 0) {
        const envelope: ApiEnvelope =
          await TalebookService.getReadingListAsync(page, PaginationConstants.PAGE_SIZE);
        fetched = this.parseEnvelopeBooks(envelope);
      } else if (this.activeTab === 1) {
        const envelope: ApiEnvelope =
          await TalebookService.getFavoritesAsync(page, PaginationConstants.PAGE_SIZE);
        fetched = this.parseEnvelopeBooks(envelope);
      } else if (this.activeTab === 2) {
        fetched = this.mapApiBooks(await TalebookApi.getWantsBooks(page, PaginationConstants.PAGE_SIZE));
      } else if (this.activeTab === 3) {
        fetched = this.mapApiBooks(await TalebookApi.getReadDoneBooks(page, PaginationConstants.PAGE_SIZE));
      } else {
        fetched = this.mapApiBooks(await TalebookApi.getScopedBooks(page, PaginationConstants.PAGE_SIZE));
      }
      if (reset) {
        this.books = fetched;
      } else {
        this.books = this.books.concat(fetched);
      }
      this.catalogItems = this.books.map((book: BookItem): BookListItemData => ({
        id: `${book.id}`,
        title: book.title,
        author: book.author,
        cover: book.cover,
      }));
      this.hasMore = PaginationHelper.computeHasMore(fetched.length);
    } catch (error) {
      if (reset) {
        this.loadError = error instanceof Error ? error.message : `${error}`;
      }
    } finally {
      this.loading = false;
      this.loadingMore = false;
      this.lastLoadTime = Date.now();
    }
  }

  private mapApiBooks(items: ApiBookItem[]): BookItem[] {
    return items.map((item: ApiBookItem): BookItem => ({
      id: item.id,
      title: item.title,
      author: item.authors.join('、'),
      cover: TalebookService.resolveCoverUrl(item.coverUrl),
    }));
  }

  private parseEnvelopeBooks(envelope: ApiEnvelope): BookItem[] {
    if (!TalebookService.isApiSuccess(envelope)) {
      return [];
    }
    const body = envelope.body ?? {};
    const list = (body['books'] as Record<string, Object>[] | undefined) ?? [];
    return list.map((item: Record<string, Object>): BookItem => ({
      id: Number(item['id'] ?? 0),
      title: String(item['title'] ?? ''),
      author: String(item['author'] ?? ''),
      cover: TalebookService.resolveCoverUrl(String(item['cover'] ?? item['cover_url'] ?? item['img'] ?? '')),
    }));
  }

  private loadMore(): void {
    if (!PaginationHelper.canLoadMore(this.lastLoadTime, this.loadingMore, this.hasMore)) {
      return;
    }
    this.currentPage += 1;
    void this.loadBooks(false);
  }

  /**
   * 当前 tab 对应的批量移除 action（私有书不支持）。
   *
   * ⚠️ 批量移除走 mybooks 专有的 `POST /api/books/batch-remove-state`（talebook 上游无此端点，
   * talebook 只能逐本改 `/api/book/{id}/readstate`）。因此无该能力时返回空串，
   * 使顶栏的「管理」入口自动隐藏，而不是让用户点了才 404。
   */
  private batchAction(): string {
    if (!ServerRegistry.supports(ServerFeature.STATE_BATCH_REMOVE)) {
      return '';
    }
    if (this.activeTab === 0) {
      return 'reading';
    }
    if (this.activeTab === 1) {
      return 'favorite';
    }
    if (this.activeTab === 2) {
      return 'wants';
    }
    if (this.activeTab === 3) {
      return 'read-done';
    }
    return '';
  }

  private toggleManageMode(): void {
    this.manageMode = !this.manageMode;
    this.selectedIds = [];
  }

  private toggleSelect(bookId: number): void {
    const index = this.selectedIds.indexOf(bookId);
    if (index >= 0) {
      const next = this.selectedIds.filter((id: number) => id !== bookId);
      this.selectedIds = next;
    } else {
      this.selectedIds = this.selectedIds.concat([bookId]);
    }
  }

  private confirmRemoveSelected(): void {
    const action = this.batchAction();
    if (action.length === 0 || this.selectedIds.length === 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '移除阅读状态',
      message: `确定移除所选 ${this.selectedIds.length} 本书籍的${this.tabStateName()}状态吗？`,
      primaryButton: {
        value: '移除',
        action: () => {
          void this.removeSelected(action);
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private tabStateName(): string {
    if (this.activeTab === 0) {
      return '在读';
    }
    if (this.activeTab === 1) {
      return '收藏';
    }
    if (this.activeTab === 2) {
      return '想读';
    }
    return '读完';
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async removeSelected(action: string): Promise<void> {
    // 批量移除状态（batch-remove-state）为 mybooks 专有端点，入口已按能力隐藏，这里兜底
    if (this.removing || !ServerRegistry.supports(ServerFeature.STATE_BATCH_REMOVE)) {
      return;
    }
    this.removing = true;
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.batchRemoveState(this.selectedIds, action);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.getUIContext().getPromptAction().showToast({
          message: rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err,
        });
        return;
      }
      this.getUIContext().getPromptAction().showToast({
        message: rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已移除',
      });
      this.selectedIds = [];
      this.manageMode = false;
      await this.loadBooks(true);
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: `移除失败：${error}` });
    } finally {
      this.removing = false;
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '我的阅读',
        showBack: true,
        action: () => {
          this.viewModeAction();
        },
        content: () => {
          this.readingContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  viewModeAction() {
    Row({ space: 12 }) {
      if (this.batchAction().length > 0) {
        Text(this.manageMode ? '取消' : '管理')
          .fontSize(14)
          .fontColor($r('app.color.brand_primary'))
          .onClick(() => this.toggleManageMode());
      }
      BookViewToggleButton({ isListMode: $isListMode });
    }
  }

  @Builder
  manageList() {
    List({ space: 2 }) {
      ForEach(this.books, (book: BookItem) => {
        ListItem() {
          Row({ space: 12 }) {
            SymbolGlyph(this.selectedIds.indexOf(book.id) >= 0 ?
              $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
              .fontSize(22)
              .fontColor([this.selectedIds.indexOf(book.id) >= 0 ?
                $r('app.color.brand_primary') : $r('app.color.text_tertiary')]);
            Column({ space: 2 }) {
              Text(book.title)
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis });
              Text(book.author)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis });
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1);
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => this.toggleSelect(book.id));
        }
      }, (book: BookItem) => `mg-${book.id}`);
    }
    .layoutWeight(1)
    .divider({ strokeWidth: 0.5, color: $r('app.color.divider') });
  }

  @Builder
  readingContent() {
    Column() {
      FilterChips({
        items: this.filterItems,
        selected: $activeTab,
        onChange: () => {
          this.manageMode = false;
          this.selectedIds = [];
          void this.loadBooks(true);
        },
      });
      if (this.loading) {
        LoadingState({});
      } else if (this.loadError.length > 0) {
        EmptyState({ message: this.loadError });
      } else if (this.books.length === 0) {
        EmptyState({ message: '暂无书籍' });
      } else if (this.manageMode) {
        this.manageList();
        Row({ space: 12 }) {
          Text(`已选 ${this.selectedIds.length} 本`)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1);
          PrimaryButton({
            label: this.removing ? '移除中…' : '移除状态',
            fullWidth: false,
            buttonEnabled: !this.removing && this.selectedIds.length > 0,
            onTap: () => this.confirmRemoveSelected(),
          });
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 12 })
        .backgroundColor($r('app.color.card_background'));
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
    .width('100%')
    .height('100%');
  }
}
