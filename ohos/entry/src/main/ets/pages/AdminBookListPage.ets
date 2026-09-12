import { router, promptAction } from '@kit.ArkUI';
import {
  PageScaffold, BookCatalogView, BookViewToggleButton, BookListItemData,
  LoadingState, EmptyState, SearchBar, TextButton, IconCircleButton,
  SecondaryButton, LazyDataSource,
} from '../components';
import { TalebookApi, AdminBookListResponse, ApiMessageResult, CropCoverResult } from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { BookUploadService } from '../services/BookUploadService';
import { PaginationConstants, PaginationHelper } from '../utils/PaginationHelper';
import { BookViewMode } from '../utils/BookViewMode';
import { mapTalebookBook } from '../utils/BookMapper';

@Entry
@Component
struct AdminBookListPage {
  @State @Watch('onBooksChanged') books: Record<string, Object>[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State currentPage: number = 1;
  @State hasMore: boolean = true;
  @State isListMode: boolean = false;
  @State catalogItems: BookListItemData[] = [];
  @State totalCount: number = 0;
  @State searching: boolean = false;
  @State keyword: string = '';
  @State activeSearch: string = '';
  @State selecting: boolean = false;
  @State selectedIds: number[] = [];
  private lastLoadTime: number = 0;
  private booksSource: LazyDataSource<Record<string, Object>> =
    new LazyDataSource<Record<string, Object>>();

  /** books 变更后同步 LazyForEach 数据源，避免逐处手写 update。 */
  private onBooksChanged(): void {
    this.booksSource.update(this.books);
  }

  aboutToAppear(): void {
    this.isListMode = BookViewMode.isListMode();
    void this.loadBooks(true);
  }

  onPageShow(): void {
    if (BookUploadService.consumeLibraryDirty()) {
      void this.loadBooks(true);
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
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
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.getAdminBookList(page, PaginationConstants.PAGE_SIZE, this.activeSearch);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        if (reset) {
          this.catalogItems = [];
        } else {
          this.currentPage = Math.max(1, this.currentPage - 1);
        }
        return;
      }
      const fetched = rsp.items ?? [];
      this.books = reset ? fetched : this.books.concat(fetched);
      this.catalogItems = this.books.map((book: Record<string, Object>) => mapTalebookBook(book));
      this.totalCount = rsp.total !== undefined ? rsp.total : this.books.length;
      this.hasMore = PaginationHelper.computeHasMore(fetched.length);
    } catch (e) {
      this.toast(`加载失败：${e}`);
      if (!reset) {
        this.currentPage = Math.max(1, this.currentPage - 1);
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

  private findBook(item: BookListItemData): Record<string, Object> | undefined {
    return this.books.find((book: Record<string, Object>) =>
      String(book['id'] ?? '') === item.id);
  }

  private showBookActions(book: Record<string, Object>): void {
    const bookId = Number(book['id'] ?? 0);
    this.getUIContext().getPromptAction().showActionMenu({
      title: String(book['title'] ?? ''),
      buttons: [
        { text: '编辑', color: '#007DFF' },
        { text: '删除', color: '#E84026' },
        { text: '多选管理', color: '#007DFF' },
      ],
    }).then((result) => {
      if (result.index === 0) {
        router.pushUrl({ url: 'pages/BookEditPage', params: { bookId: bookId } });
      } else if (result.index === 1) {
        this.confirmDelete(book);
      } else if (result.index === 2) {
        this.enterSelection(bookId);
      }
    }).catch(() => {});
  }

  private confirmDelete(book: Record<string, Object>): void {
    const bookId = Number(book['id'] ?? 0);
    this.getUIContext().showAlertDialog({
      title: '删除书籍',
      message: `确定删除「${String(book['title'] ?? '')}」吗？`,
      primaryButton: {
        value: '删除',
        action: () => {
          const envelope = TalebookService.deleteBook(bookId);
          if (envelope.status >= 200 && envelope.status < 300) {
            this.books = this.books.filter((item) => Number(item['id'] ?? 0) !== bookId);
            this.catalogItems = this.catalogItems.filter((item: BookListItemData) => item.id !== String(bookId));
            this.toast('已删除');
          } else {
            this.toast(envelope.error.length > 0 ? envelope.error : '删除失败');
          }
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private enterSelection(bookId: number): void {
    this.selecting = true;
    this.selectedIds = [bookId];
  }

  private exitSelection(): void {
    this.selecting = false;
    this.selectedIds = [];
  }

  private toggleSelect(bookId: number): void {
    const index = this.selectedIds.indexOf(bookId);
    if (index >= 0) {
      this.selectedIds.splice(index, 1);
    } else {
      this.selectedIds.push(bookId);
    }
    // 列表由 LazyForEach 驱动：勾选态不属于数据源，需显式通知才会重绘
    this.booksSource.update(this.books);
  }

  private selectAll(): void {
    this.selectedIds = this.books.map((book: Record<string, Object>) => Number(book['id'] ?? 0));
    this.booksSource.update(this.books);
  }

  private toggleSearching(): void {
    if (this.searching) {
      this.cancelSearch();
      return;
    }
    this.searching = true;
  }

  private submitSearch(): void {
    this.activeSearch = this.keyword.trim();
    this.exitSelection();
    void this.loadBooks(true);
  }

  private cancelSearch(): void {
    this.searching = false;
    if (this.activeSearch.length > 0 || this.keyword.length > 0) {
      this.keyword = '';
      this.activeSearch = '';
      void this.loadBooks(true);
    }
  }

  private handleOpResult(rsp: ApiMessageResult, fallback: string): void {
    if (rsp.err === undefined || rsp.err === 'ok') {
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : fallback);
    } else {
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
    }
  }

  /** 服务端是否支持任意一项书籍批量操作（批量删除 / 刷新元数据 / 整套批处理）。 */
  private supportsAnyBookBatch(): boolean {
    return ServerRegistry.supports(ServerFeature.ADMIN_BOOK_DELETE)
      || ServerRegistry.supports(ServerFeature.ADMIN_BOOK_FILL)
      || ServerRegistry.supports(ServerFeature.ADMIN_BOOK_BATCH);
  }

  private confirmDeleteSelected(): void {
    if (!ServerRegistry.supports(ServerFeature.ADMIN_BOOK_DELETE)) {
      this.toast(`${ServerRegistry.profile().displayName} 服务端不支持批量删除书籍`);
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '删除选中书籍',
      message: `确定删除选中的 ${this.selectedIds.length} 本书籍吗？此操作不可恢复。`,
      primaryButton: {
        value: '删除',
        action: () => {
          TalebookApi.deleteAdminBooks(this.selectedIds)
            .then((rsp: ApiMessageResult) => {
              this.handleOpResult(rsp, '已删除');
              this.exitSelection();
              void this.loadBooks(true);
            })
            .catch((e: Object) => this.toast(`删除失败：${e}`));
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  /** 选中书籍的批量操作菜单 */
  private showSelectionActions(): void {
    if (this.selectedIds.length === 0) {
      this.toast('请先选择书籍');
      return;
    }
    if (!this.supportsAnyBookBatch()) {
      this.toast(`${ServerRegistry.profile().displayName} 服务端不支持批量操作`);
      return;
    }
    // 各服务端支持的批量操作不同：按能力动态组装按钮，并记录同序操作键用于分发（不依赖 index）
    const buttons: promptAction.Button[] = [];
    const actions: string[] = [];
    if (ServerRegistry.supports(ServerFeature.ADMIN_BOOK_DELETE)) {
      buttons.push({ text: '删除选中', color: '#E84026' });
      actions.push('delete');
    }
    if (ServerRegistry.supports(ServerFeature.ADMIN_BOOK_FILL)) {
      buttons.push({ text: '刷新互联网元数据', color: '#007DFF' });
      actions.push('fill');
    }
    if (ServerRegistry.supports(ServerFeature.ADMIN_BOOK_BATCH)) {
      buttons.push({ text: 'AI 更新选中', color: '#007DFF' });
      actions.push('ai');
      buttons.push({ text: 'EPUB 转换', color: '#007DFF' });
      actions.push('epub');
      buttons.push({ text: '类型互转（电子书/实体书）', color: '#007DFF' });
      actions.push('exchange');
      buttons.push({ text: '更多操作…', color: '#007DFF' });
      actions.push('more');
    }
    this.getUIContext().getPromptAction().showActionMenu({
      title: `批量操作（已选 ${this.selectedIds.length} 本）`,
      buttons: buttons,
    } as promptAction.ActionMenuOptions).then((result) => {
      const ids = this.selectedIds;
      const action: string = actions[result.index] ?? '';
      if (action === 'delete') {
        this.confirmDeleteSelected();
      } else if (action === 'fill') {
        TalebookApi.fillAdminBooks(ids)
          .then((rsp: ApiMessageResult) => {
            this.handleOpResult(rsp, '已启动刷新元数据任务');
            this.exitSelection();
          })
          .catch((e: Object) => this.toast(`操作失败：${e}`));
      } else if (action === 'ai') {
        TalebookApi.aiFillAdminBooks(ids)
          .then((rsp: ApiMessageResult) => {
            this.handleOpResult(rsp, '已启动 AI 更新任务');
            this.exitSelection();
          })
          .catch((e: Object) => this.toast(`操作失败：${e}`));
      } else if (action === 'epub') {
        TalebookApi.epubConvertAdminBooks(ids)
          .then((rsp: ApiMessageResult) => {
            this.handleOpResult(rsp, '已启动 EPUB 转换任务');
            this.exitSelection();
          })
          .catch((e: Object) => this.toast(`操作失败：${e}`));
      } else if (action === 'exchange') {
        TalebookApi.exchangeBookType(ids)
          .then((rsp: ApiMessageResult) => {
            this.handleOpResult(rsp, '类型互转完成');
            this.exitSelection();
            void this.loadBooks(true);
          })
          .catch((e: Object) => this.toast(`操作失败：${e}`));
      } else if (action === 'more') {
        this.showMoreSelectionActions(ids);
      }
    }).catch(() => {});
  }

  /** 选中书籍的更多批量操作（第二级菜单） */
  private showMoreSelectionActions(ids: number[]): void {
    this.getUIContext().getPromptAction().showActionMenu({
      title: '更多批量操作',
      buttons: [
        { text: '保存元数据到文件', color: '#007DFF' },
        { text: '更新标题排序', color: '#007DFF' },
        { text: '裁剪封面白边', color: '#007DFF' },
      ],
    }).then((result) => {
      if (result.index === 0) {
        TalebookApi.saveAdminMetaToFiles(ids)
          .then((rsp: ApiMessageResult) => {
            this.handleOpResult(rsp, '元数据已写入书籍文件');
            this.exitSelection();
          })
          .catch((e: Object) => this.toast(`操作失败：${e}`));
      } else if (result.index === 1) {
        TalebookApi.updateAdminTitleSort(ids)
          .then((rsp: ApiMessageResult) => {
            this.handleOpResult(rsp, '标题排序已更新');
            this.exitSelection();
            void this.loadBooks(true);
          })
          .catch((e: Object) => this.toast(`操作失败：${e}`));
      } else if (result.index === 2) {
        if (!ServerRegistry.supports(ServerFeature.BOOK_CROP_COVER)) {
          this.toast(`${ServerRegistry.profile().displayName} 服务端不支持批量裁剪封面`);
          return;
        }
        TalebookApi.cropCovers(ids)
          .then((rsp: CropCoverResult) => {
            const data: Record<string, Object> = rsp.data ?? {};
            this.handleOpResult(rsp, `裁剪完成：成功 ${Number(data['updated'] ?? 0)} 本`);
            this.exitSelection();
            void this.loadBooks(true);
          })
          .catch((e: Object) => this.toast(`操作失败：${e}`));
      }
    }).catch(() => {});
  }

  /** 全局批量工具菜单 */
  private showGlobalTools(): void {
    // 各项工具归属不同能力（刷新元数据为单项，其余属整套批处理），按能力动态组装菜单
    const buttons: promptAction.Button[] = [];
    const actions: string[] = [];
    if (ServerRegistry.supports(ServerFeature.ADMIN_BOOK_FILL)) {
      buttons.push({ text: '刷新全部元数据', color: '#007DFF' });
      actions.push('fill-all');
    }
    if (ServerRegistry.supports(ServerFeature.ADMIN_BOOK_BATCH)) {
      buttons.push({ text: '更新全部元数据', color: '#007DFF' });
      actions.push('update-all-meta');
      buttons.push({ text: '全部更新标题排序', color: '#007DFF' });
      actions.push('update-title-sort');
      buttons.push({ text: '更新全部动态封面', color: '#007DFF' });
      actions.push('update-dynamic-cover');
      buttons.push({ text: '重置全部封面', color: '#007DFF' });
      actions.push('reset-cover');
      buttons.push({ text: '清理无效条目', color: '#E84026' });
      actions.push('clear-invalid');
    }
    if (buttons.length === 0) {
      this.toast(`${ServerRegistry.profile().displayName} 服务端不支持批量工具`);
      return;
    }
    this.getUIContext().getPromptAction().showActionMenu({
      title: '批量工具',
      buttons: buttons,
    } as promptAction.ActionMenuOptions).then((result) => {
      const action: string = actions[result.index] ?? '';
      if (action === 'fill-all') {
        TalebookApi.fillAdminBooks('all')
          .then((rsp: ApiMessageResult) => this.handleOpResult(rsp, '已启动刷新元数据任务'))
          .catch((e: Object) => this.toast(`操作失败：${e}`));
      } else if (action === 'update-all-meta') {
        TalebookApi.updateAllAdminMeta()
          .then((rsp: ApiMessageResult) => this.handleOpResult(rsp, '已启动更新全部元数据任务'))
          .catch((e: Object) => this.toast(`操作失败：${e}`));
      } else if (action === 'update-title-sort') {
        TalebookApi.updateAdminTitleSort()
          .then((rsp: ApiMessageResult) => {
            this.handleOpResult(rsp, '标题排序已更新');
            void this.loadBooks(true);
          })
          .catch((e: Object) => this.toast(`操作失败：${e}`));
      } else if (action === 'update-dynamic-cover') {
        TalebookApi.updateAdminDynamicCover('all')
          .then((rsp: ApiMessageResult) => this.handleOpResult(rsp, '已启动动态封面更新任务'))
          .catch((e: Object) => this.toast(`操作失败：${e}`));
      } else if (action === 'reset-cover') {
        TalebookApi.resetAdminCover('all')
          .then((rsp: ApiMessageResult) => {
            this.handleOpResult(rsp, '封面已重置');
            void this.loadBooks(true);
          })
          .catch((e: Object) => this.toast(`操作失败：${e}`));
      } else if (action === 'clear-invalid') {
        TalebookApi.clearAdminInvalidItems()
          .then((rsp: ApiMessageResult) => {
            this.handleOpResult(rsp, '已清理无效条目');
            void this.loadBooks(true);
          })
          .catch((e: Object) => this.toast(`操作失败：${e}`));
      }
    }).catch(() => {});
  }

  @Builder
  viewModeAction() {
    Row({ space: 8 }) {
      IconCircleButton({
        icon: $r('sys.symbol.magnifyingglass'),
        variant: 'ghost',
        onTap: () => this.toggleSearching(),
      });
      BookViewToggleButton({ isListMode: $isListMode });
    }
  }

  @Builder
  toolsRow() {
    Row() {
      Text(this.selecting ? `已选 ${this.selectedIds.length} 本` :
        (this.activeSearch.length > 0 ? `搜索「${this.activeSearch}」· 共 ${this.totalCount} 本` : `共 ${this.totalCount} 本`))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1);
      if (this.selecting) {
        TextButton({
          label: '全选',
          onTap: () => this.selectAll(),
        });
        TextButton({
          label: '退出多选',
          onTap: () => this.exitSelection(),
        });
      } else {
        TextButton({
          label: '上传图书',
          onTap: () => router.pushUrl({ url: 'pages/BookUploadPage' }),
        });
        if (ServerRegistry.supports(ServerFeature.ADMIN_BOOK_FILL)
          || ServerRegistry.supports(ServerFeature.ADMIN_BOOK_BATCH)) {
          TextButton({
            label: '批量工具',
            onTap: () => this.showGlobalTools(),
          });
        }
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 4 });
  }

  @Builder
  selectionList() {
    List({ space: 4 }) {
      LazyForEach(this.booksSource, (book: Record<string, Object>) => {
        ListItem() {
          Row({ space: 12 }) {
            Text(this.selectedIds.indexOf(Number(book['id'] ?? 0)) >= 0 ? '✓' : '')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .textAlign(TextAlign.Center)
              .width(22)
              .height(22)
              .borderRadius(11)
              .backgroundColor(this.selectedIds.indexOf(Number(book['id'] ?? 0)) >= 0 ?
                $r('app.color.brand_primary') : $r('app.color.page_background'))
              // 圆角必须写进 border：否则 22×22 的圆形选择框会被 border 重置成方块
              .border({
                width: 1,
                color: $r('app.color.divider'),
                radius: 11,
              });
            Column({ space: 2 }) {
              Text(String(book['title'] ?? ''))
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis });
              Text(String(book['authors'] ?? book['author'] ?? ''))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis });
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1);
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .onClick(() => this.toggleSelect(Number(book['id'] ?? 0)));
        }
      }, (book: Record<string, Object>) => `select-${Number(book['id'] ?? 0)}`);
    }
    .layoutWeight(1)
    .width('100%');
  }

  @Builder
  selectionBar() {
    Row({ space: 12 }) {
      if (this.supportsAnyBookBatch()) {
        SecondaryButton({
          label: '批量操作',
          buttonEnabled: this.selectedIds.length > 0,
          fullWidth: false,
          onTap: () => this.showSelectionActions(),
        }).layoutWeight(1);
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 12 });
  }

  build() {
    Column() {
      PageScaffold({
        title: '图书管理',
        showBack: true,
        action: () => {
          this.viewModeAction();
        },
        content: () => {
          this.listContent();
        },
      })
        .layoutWeight(1);
      if (this.selecting) {
        this.selectionBar();
      }
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  listContent() {
    Column() {
      if (this.searching) {
        Row({ space: 8 }) {
          SearchBar({
            placeholder: '搜索书名、作者等',
            keyword: $keyword,
            onSearch: () => this.submitSearch(),
          }).layoutWeight(1);
          TextButton({
            label: '取消',
            onTap: () => this.cancelSearch(),
          });
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);
      }
      this.toolsRow();
      if (this.loading) {
        LoadingState({});
      } else if (this.books.length === 0) {
        EmptyState({ message: this.activeSearch.length > 0 ? '未找到匹配书籍' : '暂无书籍' });
      } else if (this.selecting) {
        this.selectionList();
      } else {
        BookCatalogView({
          items: this.catalogItems,
          isListMode: this.isListMode,
          loadingMore: this.loadingMore,
          onItemTap: (item: BookListItemData) => router.pushUrl({
            url: 'pages/BookDetailPage', params: { bookId: Number(item.id) }
          }),
          onItemLongPress: (item: BookListItemData) => {
            const book = this.findBook(item);
            if (book !== undefined) {
              this.showBookActions(book);
            }
          },
          onLoadMore: () => this.loadMore(),
        });
      }
    }
    .width('100%')
    .height('100%');
  }
}
