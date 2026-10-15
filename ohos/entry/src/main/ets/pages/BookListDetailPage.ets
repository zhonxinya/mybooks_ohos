import { promptAction } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  PageScaffold, LoadingState, EmptyState, AuthImage, IconCircleButton,
  ChipButton, PrimaryButton, SearchBar, LazyDataSource,
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { ApiMessageResult } from '../services/TalebookApi';
import {
  BookListApi,
} from '../services/BookListApi';
import {
  BookListDetailData, BookListCoverBook, BOOKLIST_COLORS, BookListColorOption,
  DEFAULT_BOOKLIST_COLOR, booklistColorHex,
} from '../models/BookListModels';
import { PaginationConstants, PaginationHelper } from '../utils/PaginationHelper';
import { AppRouter } from '../utils/AppRouter';

interface SheetBookItem {
  bookId: number;
  title: string;
  cover: string;
  inList: boolean;
}

const DETAIL_PAGE_SIZE: number = 24;
/** 封面网格列数：与原 `GridCol({span:4})`（12 栅格）一致。 */
const COVER_COLUMNS: number = 3;
/** 封面网格的虚拟化缓存行数（约 2 屏），过大反而白建节点。 */
const COVER_CACHE_ROWS: number = 8;
/** 距末尾还有这么多行时就预取下一页。 */
const LOAD_MORE_THRESHOLD_ROWS: number = 2;
/** 网格前的固定项数：头部卡片 + 排序条（onScrollIndex 的下标口径含它们）。 */
const COVER_HEADER_ITEMS: number = 2;

/** 网格单元格：`book` 为 null 表示「添加书籍」虚线格（仅 owner 的首格）。 */
interface CoverCell {
  book: BookListCoverBook | null;
}

/** 行键：只依赖行首与格数，追加翻页时已有行的键保持不变（只重建新增行）。 */
function coverRowKey(row: CoverCell[]): string {
  const first: CoverCell = row[0];
  const head: string = first.book === null ? 'add' : `b${first.book.bookId}`;
  return `${head}-${row.length}`;
}

/** 对齐服务端约束：BookList.name 为 String(100)、description 服务端截断到 500。 */
const BOOKLIST_NAME_MAX: number = 100;
const BOOKLIST_DESC_MAX: number = 500;

/** 底部面板类型：同一节点只挂一个 bindSheet，靠它切换内容（见 build() 注释）。 */
const SHEET_NONE: string = 'none';
const SHEET_EDIT: string = 'edit';
const SHEET_ADD: string = 'add';
const SHEET_SHARE: string = 'share';

@Entry
@Component
struct BookListDetailPage {
  @State booklistId: number = 0;
  @State detail: BookListDetailData | null = null;
  @State books: BookListCoverBook[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State currentPage: number = 1;
  @State hasMore: boolean = false;
  @State errorMessage: string = '';
  @State order: string = 'desc';
  @State showSheet: boolean = false;
  @State sheetKind: string = SHEET_NONE;
  @State editName: string = '';
  @State editDescription: string = '';
  @State editColor: string = DEFAULT_BOOKLIST_COLOR;
  @State editIsPublic: boolean = false;
  @State saving: boolean = false;
  @State shareUrl: string = '';
  @State shareSaving: boolean = false;
  @State addKeyword: string = '';
  @State @Watch('onAddResultsChanged') addResults: SheetBookItem[] = [];
  @State addSearching: boolean = false;
  @State addSearchingMore: boolean = false;
  @State addPage: number = 1;
  /** 当前账号是否管理员：服务端书单置顶为 `@is_admin`，据此决定菜单里是否出现「置顶」。 */
  @State isAdmin: boolean = false;
  private addResultsSource: LazyDataSource<SheetBookItem> = new LazyDataSource<SheetBookItem>();
  /**
   * 封面网格的 LazyForEach 数据源，每项是「一行」（≤3 格）。
   *
   * 为什么按行分块：头部卡片是全宽出血（无左右内边距），封面区却要左右各 16，
   * 二者没法共用一个带 padding 的 Grid；按行虚拟化后由行容器自己带内边距，版式与改造前一致。
   */
  private coverRows: LazyDataSource<CoverCell[]> = new LazyDataSource<CoverCell[]>();
  private lastLoadTime: number = 0;
  private lastAddTime: number = 0;

  /** books / 归属人变化后重算封面行（owner 首格为「添加书籍」虚线格）。 */
  private syncCoverRows(): void {
    const cells: CoverCell[] = [];
    if (this.isOwner()) {
      cells.push({ book: null });
    }
    for (let i = 0; i < this.books.length; i++) {
      cells.push({ book: this.books[i] });
    }
    const rows: CoverCell[][] = [];
    for (let i = 0; i < cells.length; i += COVER_COLUMNS) {
      rows.push(cells.slice(i, i + COVER_COLUMNS));
    }
    this.coverRows.update(rows);
  }

  /** addResults 变更后同步 LazyForEach 数据源。 */
  private onAddResultsChanged(): void {
    this.addResultsSource.update(this.addResults);
  }

  aboutToAppear(): void {
    const params = AppRouter.getParams(this.getUIContext()) as Record<string, Object>;
    this.booklistId = Number(params['booklistId'] ?? 0);
    void this.prepareAndLoad();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private isOwner(): boolean {
    return this.detail !== null && this.detail.isOwner;
  }

  private async prepareAndLoad(): Promise<void> {
    if (TalebookService.hasAuthCredentials()) {
      await TalebookService.ensureAuthenticated();
    }
    // 管理员标记只影响 owner 菜单，不阻塞详情加载
    void this.loadAdminFlag();
    if (this.booklistId > 0) {
      BookListApi.bumpView(this.booklistId).catch(() => {});
    }
    await this.loadDetail(true);
  }

  private async loadAdminFlag(): Promise<void> {
    if (!TalebookService.hasAuthCredentials()) {
      this.isAdmin = false;
      return;
    }
    try {
      this.isAdmin = await TalebookService.isCurrentUserAdminAsync();
    } catch (_error) {
      this.isAdmin = false;
    }
  }

  private async loadDetail(reset: boolean): Promise<void> {
    if (reset) {
      this.currentPage = 1;
      this.hasMore = false;
      this.loading = this.detail === null;
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
      const rsp = await BookListApi.getBooklistDetail(this.booklistId, page, DETAIL_PAGE_SIZE,
        this.order);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        if (reset) {
          this.errorMessage = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err;
        } else {
          this.toast('加载更多失败');
          this.currentPage = Math.max(1, this.currentPage - 1);
        }
        return;
      }
      const data = BookListApi.parseDetail(rsp);
      if (data === null) {
        if (reset) {
          this.errorMessage = '书单不存在';
        }
        return;
      }
      this.detail = data;
      const fetched = data.books;
      this.books = reset ? fetched : this.books.concat(fetched);
      this.hasMore = this.books.length < data.booksTotal;
      this.syncCoverRows();
    } catch (error) {
      if (reset) {
        this.errorMessage = error instanceof Error ? error.message : `${error}`;
      } else {
        this.toast('加载更多失败');
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
    void this.loadDetail(false);
  }

  private changeOrder(value: string): void {
    if (this.order === value) {
      return;
    }
    this.order = value;
    void this.loadDetail(true);
  }

  private async toggleLike(): Promise<void> {
    if (this.detail === null) {
      return;
    }
    try {
      const rsp = await BookListApi.toggleLike(this.detail.id);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        if (TalebookService.isLoginRequiredResult(rsp.err, rsp.msg)) {
          this.toast('请先在「账号与服务器」中配置账号，应用会自动登录');
          AppRouter.pushUrl(this.getUIContext(), { url: 'pages/TalebookConfigPage' });
          return;
        }
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '操作失败');
        return;
      }
      const liked = rsp.liked === true;
      this.detail = {
        id: this.detail.id, name: this.detail.name, description: this.detail.description,
        color: this.detail.color, isPublic: this.detail.isPublic, isSticky: this.detail.isSticky,
        viewCount: this.detail.viewCount, likeCount: this.detail.likeCount + (liked ? 1 : -1),
        bookCount: this.detail.bookCount, owner: this.detail.owner, isOwner: this.detail.isOwner,
        likedByMe: liked, coverBooks: this.detail.coverBooks, books: this.detail.books,
        booksTotal: this.detail.booksTotal, page: this.detail.page, pageSize: this.detail.pageSize,
      };
    } catch (error) {
      this.toast(`操作失败：${error}`);
    }
  }

  private openEditSheet(): void {
    if (this.detail === null) {
      return;
    }
    this.editName = this.detail.name;
    this.editDescription = this.detail.description;
    this.editColor = this.detail.color;
    this.editIsPublic = this.detail.isPublic;
    this.sheetKind = SHEET_EDIT;
    this.showSheet = true;
  }

  private async saveSheet(): Promise<void> {
    const name = this.editName.trim();
    if (name.length === 0) {
      this.toast('书单名称不能为空');
      return;
    }
    if (this.saving || this.detail === null) {
      return;
    }
    this.saving = true;
    try {
      const rsp = await BookListApi.updateBooklist(this.detail.id, {
        name: name,
        description: this.editDescription.trim(),
        color: this.editColor,
        is_public: this.editIsPublic,
      });
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        return;
      }
      this.toast('已保存');
      this.sheetKind = SHEET_NONE;
      this.showSheet = false;
      await this.loadDetail(true);
    } catch (error) {
      this.toast(`保存失败：${error}`);
    } finally {
      this.saving = false;
    }
  }

  private confirmDelete(): void {
    if (this.detail === null) {
      return;
    }
    const name = this.detail.name;
    this.getUIContext().showAlertDialog({
      title: '删除书单',
      message: `确定删除书单「${name}」吗？该操作不可恢复。`,
      primaryButton: {
        value: '删除',
        action: () => {
          BookListApi.deleteBooklist(this.booklistId)
            .then((rsp: ApiMessageResult) => {
              if (rsp.err === undefined || rsp.err === 'ok') {
                this.toast('已删除');
                AppRouter.back(this.getUIContext());
              } else {
                this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
              }
            })
            .catch((e: Object) => this.toast(`删除失败：${e}`));
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private showOwnerMenu(): void {
    if (this.detail === null) {
      return;
    }
    // 按能力动态组装按钮，并用同序的 action 列表分发（不依赖 index）
    const buttons: promptAction.Button[] = [];
    const actions: string[] = [];
    buttons.push({ text: '编辑书单', color: '#007DFF' });
    actions.push('edit');
    buttons.push({ text: this.detail.isPublic ? '设为私有' : '设为公开', color: '#007DFF' });
    actions.push('visibility');
    if (this.isAdmin) {
      // 服务端 BookListStickyHandler 为 @is_admin，仅管理员暴露该入口
      buttons.push({ text: this.detail.isSticky ? '取消置顶' : '置顶', color: '#007DFF' });
      actions.push('sticky');
    }
    if (this.detail.isPublic) {
      // 私有书单没有可分享的落地页，直接不出现该菜单项（原来点了才弹「不支持分享」）
      buttons.push({ text: '生成分享卡片', color: '#007DFF' });
      actions.push('share');
    }
    buttons.push({ text: '删除书单', color: '#E84026' });
    actions.push('delete');
    this.getUIContext().getPromptAction().showActionMenu({
      title: this.detail.name,
      buttons: buttons,
    } as promptAction.ActionMenuOptions).then((result) => {
      const action: string = actions[result.index] ?? '';
      if (action === 'edit') {
        this.openEditSheet();
      } else if (action === 'visibility') {
        void this.toggleVisibility();
      } else if (action === 'sticky') {
        void this.toggleSticky();
      } else if (action === 'share') {
        this.openShareSheet();
      } else if (action === 'delete') {
        this.confirmDelete();
      }
    }).catch(() => {});
  }

  private async toggleSticky(): Promise<void> {
    if (this.detail === null) {
      return;
    }
    const next: boolean = !this.detail.isSticky;
    try {
      const rsp = await BookListApi.setSticky(this.detail.id, next);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        return;
      }
      this.toast(next ? '已置顶' : '已取消置顶');
      await this.loadDetail(true);
    } catch (error) {
      this.toast(`操作失败：${error}`);
    }
  }

  private openShareSheet(): void {
    if (this.detail === null || !this.detail.isPublic) {
      this.toast('私有书单不支持分享');
      return;
    }
    const base = TalebookService.secureGet('talebook_url');
    const normalized = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    this.shareUrl = `${normalized}/booklist/${this.booklistId}`;
    this.sheetKind = SHEET_SHARE;
    this.showSheet = true;
  }

  private async saveShareCard(): Promise<void> {
    if (this.shareSaving) {
      return;
    }
    this.shareSaving = true;
    try {
      const pm = await this.getUIContext().getComponentSnapshot().get('booklistShareCard');
      const packer = image.createImagePacker();
      const data: ArrayBuffer = await packer.packToData(pm, { format: 'image/jpeg', quality: 92 });
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const dir = `${context.filesDir}/share`;
      try {
        if (!fs.accessSync(dir)) {
          fs.mkdirSync(dir, true);
        }
      } catch (_error) {
        fs.mkdirSync(dir, true);
      }
      const dest = `${dir}/booklist-${this.booklistId}.jpg`;
      const file = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      fs.writeSync(file.fd, data);
      fs.closeSync(file.fd);
      this.toast(`已保存：${dest}`);
    } catch (error) {
      this.toast(`生成失败：${error}`);
    } finally {
      this.shareSaving = false;
    }
  }

  private async toggleVisibility(): Promise<void> {
    if (this.detail === null) {
      return;
    }
    try {
      const rsp = await BookListApi.updateBooklist(this.detail.id,
        { is_public: !this.detail.isPublic });
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        return;
      }
      this.toast(this.detail.isPublic ? '已设为私有' : '已设为公开');
      await this.loadDetail(true);
    } catch (error) {
      this.toast(`操作失败：${error}`);
    }
  }

  private openAddSheet(): void {
    this.addKeyword = '';
    this.addResults = [];
    this.addPage = 1;
    this.sheetKind = SHEET_ADD;
    this.showSheet = true;
  }

  private async searchBooksForAdd(page: number): Promise<void> {
    const keyword = this.addKeyword.trim();
    if (keyword.length === 0) {
      this.toast('请输入书名关键词');
      return;
    }
    if (page === 1) {
      this.addSearching = true;
      this.addResults = [];
    } else {
      this.addSearchingMore = true;
    }
    try {
      const envelope = await TalebookService.searchAsync(keyword, page, PaginationConstants.PAGE_SIZE);
      if (!TalebookService.isApiSuccess(envelope)) {
        this.toast(envelope.error.length > 0 ? envelope.error : '搜索失败');
        if (page > 1) {
          this.addPage = Math.max(1, this.addPage - 1);
        }
        return;
      }
      const body = envelope.body ?? {};
      const fetched = (body['books'] as Record<string, Object>[] | undefined) ?? [];
      const existing = new Set<number>(this.books.map((book: BookListCoverBook) => book.bookId));
      const mapped: SheetBookItem[] = [];
      for (let i = 0; i < fetched.length; i++) {
        const raw = fetched[i];
        const bookId = Number(raw['id'] ?? 0);
        if (bookId <= 0) {
          continue;
        }
        mapped.push({
          bookId: bookId,
          title: String(raw['title'] ?? '未知'),
          cover: TalebookService.resolveCoverUrl(String(raw['cover'] ?? raw['cover_url'] ?? raw['img'] ?? '')),
          inList: existing.has(bookId),
        });
      }
      this.addResults = page === 1 ? mapped : this.addResults.concat(mapped);
    } catch (error) {
      this.toast(`搜索失败：${error}`);
    } finally {
      this.addSearching = false;
      this.addSearchingMore = false;
      this.lastAddTime = Date.now();
    }
  }

  private loadMoreAddResults(): void {
    if (this.addSearchingMore || this.addSearching ||
      Date.now() - this.lastAddTime < PaginationConstants.DEBOUNCE_MS) {
      return;
    }
    if (this.addResults.length < PaginationConstants.PAGE_SIZE) {
      return;
    }
    this.addPage += 1;
    void this.searchBooksForAdd(this.addPage);
  }

  private async toggleBookInList(item: SheetBookItem): Promise<void> {
    if (this.detail === null) {
      return;
    }
    try {
      if (item.inList) {
        const rsp = await BookListApi.removeBook(this.detail.id, item.bookId);
        if (rsp.err !== undefined && rsp.err !== 'ok') {
          this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
          return;
        }
        this.toast('已从书单移出');
      } else {
        const rsp = await BookListApi.addBooks(this.detail.id, [item.bookId]);
        if (rsp.err !== undefined && rsp.err !== 'ok') {
          this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
          return;
        }
        this.toast('已加入书单');
      }
      const nextInList = !item.inList;
      this.addResults = this.addResults.map((result: SheetBookItem): SheetBookItem => {
        if (result.bookId !== item.bookId) {
          return result;
        }
        return { bookId: result.bookId, title: result.title, cover: result.cover, inList: nextInList };
      });
      await this.loadDetail(true);
    } catch (error) {
      this.toast(`操作失败：${error}`);
    }
  }

  private removeBook(book: BookListCoverBook): void {
    if (this.detail === null) {
      return;
    }
    const listId = this.detail.id;
    this.getUIContext().showAlertDialog({
      title: '移出书籍',
      message: `确定将「${book.title}」移出书单吗？`,
      primaryButton: {
        value: '移出',
        action: () => {
          BookListApi.removeBook(listId, book.bookId)
            .then((rsp: ApiMessageResult) => {
              if (rsp.err === undefined || rsp.err === 'ok') {
                this.toast('已从书单移出');
                this.books = this.books.filter((item: BookListCoverBook) => item.bookId !== book.bookId);
                this.syncCoverRows();
                if (this.detail !== null) {
                  const nextTotal: number = Math.max(0, this.detail.booksTotal - 1);
                  this.detail = {
                    id: this.detail.id, name: this.detail.name, description: this.detail.description,
                    color: this.detail.color, isPublic: this.detail.isPublic,
                    isSticky: this.detail.isSticky, viewCount: this.detail.viewCount,
                    likeCount: this.detail.likeCount,
                    bookCount: Math.max(0, this.detail.bookCount - 1),
                    owner: this.detail.owner, isOwner: this.detail.isOwner,
                    likedByMe: this.detail.likedByMe, coverBooks: this.detail.coverBooks,
                    books: this.detail.books, booksTotal: nextTotal,
                    page: this.detail.page, pageSize: this.detail.pageSize,
                  };
                  // 已加载数与总数同时变化，必须重算「还有下一页」，否则会少拉一页或多发一次空请求
                  this.hasMore = this.books.length < nextTotal;
                }
              } else {
                this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
              }
            })
            .catch((e: Object) => this.toast(`移出失败：${e}`));
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private openBook(bookId: number): void {
    AppRouter.pushUrl(this.getUIContext(), { url: 'pages/BookDetailPage', params: { bookId: bookId } });
  }

  @Builder
  headerCard() {
    if (this.detail !== null) {
      Column({ space: 8 }) {
        Row({ space: 6 }) {
          Text(this.detail.name)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1);
          if (!this.detail.isPublic) {
            SymbolGlyph($r('sys.symbol.lock'))
              .fontSize(14)
              .fontColor([$r('app.color.text_tertiary')]);
          }
          if (this.isOwner()) {
            IconCircleButton({
              icon: $r('sys.symbol.ellipsis_circle'),
              variant: 'soft',
              iconSize: 16,
              buttonSize: 28,
              onTap: () => this.showOwnerMenu(),
            });
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);
        if (this.detail.description.length > 0) {
          Text(this.detail.description)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .lineHeight(19)
            .width('100%');
        }
        Row({ space: 14 }) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.person'))
              .fontSize(13)
              .fontColor([$r('app.color.text_tertiary')]);
            Text(this.detail.owner !== null ? this.detail.owner.username : '')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'));
          }
          .alignItems(VerticalAlign.Center);
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.book'))
              .fontSize(12)
              .fontColor([$r('app.color.text_tertiary')]);
            Text(`${this.detail.bookCount}`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'));
          }
          .alignItems(VerticalAlign.Center);
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.eye'))
              .fontSize(12)
              .fontColor([$r('app.color.text_tertiary')]);
            Text(`${this.detail.viewCount}`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'));
          }
          .alignItems(VerticalAlign.Center);
          Row({ space: 4 }) {
            SymbolGlyph(this.detail.likedByMe ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
              .fontSize(12)
              .fontColor([this.detail.likedByMe ? $r('app.color.error') : $r('app.color.text_tertiary')]);
            Text(`${this.detail.likeCount}`)
              .fontSize(12)
              .fontColor(this.detail.likedByMe ? $r('app.color.error') : $r('app.color.text_secondary'));
          }
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            void this.toggleLike();
          });
        }
        .width('100%');
      }
      .width('100%')
      .padding($r('app.float.card_padding'))
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'))
      .border({
        width: { left: 4 },
        color: { left: booklistColorHex(this.detail.color) },
        // 圆角必须写进 border：先 borderRadius 再 border 会重置圆角
        radius: $r('app.float.card_radius'),
      })
      .alignItems(HorizontalAlign.Start);
    }
  }

  @Builder
  orderChips() {
    Row({ space: 8 }) {
      ChipButton({
        label: '最新加入',
        selected: this.order === 'desc',
        onTap: () => this.changeOrder('desc'),
      });
      ChipButton({
        label: '最早加入',
        selected: this.order === 'asc',
        onTap: () => this.changeOrder('asc'),
      });
      Blank().layoutWeight(1);
    }
    .width('100%')
    .padding({ left: 16, right: 16 });
  }

  /** 「添加书籍」虚线格（仅 owner 的首格）。 */
  @Builder
  addBookCell() {
    GridCol({ span: 4 }) {
      Column({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(28)
          .fontColor([$r('app.color.text_tertiary')]);
        Text('添加书籍')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'));
      }
      .width('100%')
      .height(158)
      .justifyContent(FlexAlign.Center)
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'))
      .border({
        width: 1,
        color: $r('app.color.divider'),
        style: BorderStyle.Dashed,
        // 圆角必须写进 border：否则虚线框会盖成直角
        radius: $r('app.float.card_radius'),
      })
      .onClick(() => this.openAddSheet());
    }
  }

  /** 一格的封面。 */
  @Builder
  coverCell(book: BookListCoverBook) {
    GridCol({ span: 4 }) {
      Column({ space: 4 }) {
        Stack({ alignContent: Alignment.TopEnd }) {
          AuthImage({
            url: book.thumb.length > 0 ? book.thumb : book.img,
            imageWidth: '100%',
            imageHeight: 140,
          });
          if (this.isOwner()) {
            Column() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(12)
                .fontColor([Color.White]);
            }
            .width(22)
            .height(22)
            .justifyContent(FlexAlign.Center)
            .borderRadius(11)
            .backgroundColor('#99000000')
            .margin(4)
            .onClick(() => {
              this.removeBook(book);
            });
          }
        }
        .width('100%');
        Text(book.title)
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
      }
      .alignItems(HorizontalAlign.Start)
      .onClick(() => this.openBook(book.bookId));
    }
  }

  /** 一行封面（≤3 格），左右内边距与原 GridRow 一致。 */
  @Builder
  coverRow(row: CoverCell[]) {
    GridRow({
      columns: 12,
      gutter: { x: 10, y: 12 },
    }) {
      ForEach(row, (cell: CoverCell) => {
        if (cell.book === null) {
          this.addBookCell();
        } else {
          this.coverCell(cell.book);
        }
      }, (cell: CoverCell) => cell.book === null ? 'add-book' : `book-${cell.book.bookId}`);
    }
    .width('100%')
    .padding({ left: 16, right: 16 });
  }

  @Builder
  editSheet() {
    Column({ space: 12 }) {
      // maxLength 对齐服务端约束，否则超长简介会被服务端静默截断
      TextInput({ text: this.editName, placeholder: '书单名称' })
        .width('100%')
        .height(44)
        .maxLength(BOOKLIST_NAME_MAX)
        .onChange((value: string) => {
          this.editName = value;
        });
      TextArea({ text: this.editDescription, placeholder: '简介（可选）' })
        .width('100%')
        .height(90)
        .maxLength(BOOKLIST_DESC_MAX)
        .onChange((value: string) => {
          this.editDescription = value;
        });
      Row() {
        Text('公开可见')
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        Toggle({ type: ToggleType.Switch, isOn: $$this.editIsPublic })
          .selectedColor($r('app.color.brand_primary'));
      }
      .width('100%');
      Column({ space: 8 }) {
        Text('颜色')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'));
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(BOOKLIST_COLORS, (option: BookListColorOption) => {
            Column() {
              if (this.editColor === option.key) {
                SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                  .fontSize(18)
                  .fontColor([$r('app.color.on_brand')]);
              }
            }
            .width(32)
            .height(32)
            .justifyContent(FlexAlign.Center)
            .borderRadius(16)
            .backgroundColor(option.hex)
            // 圆角必须写进 border：否则选中环会把 32×32 的色板盖成方块
            .border({
              width: 2,
              color: this.editColor === option.key ? $r('app.color.text_primary') : Color.Transparent,
              radius: 16,
            })
            .margin({ right: 10, bottom: 8 })
            .onClick(() => {
              this.editColor = option.key;
            });
          }, (option: BookListColorOption) => option.key);
        }
        .width('100%');
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
      PrimaryButton({
        label: '保存修改',
        buttonEnabled: !this.saving,
        onTap: () => {
          void this.saveSheet();
        },
      });
    }
    .width('100%')
    .padding($r('app.float.page_padding'));
  }

  @Builder
  addSheet() {
    Column({ space: 8 }) {
      SearchBar({
        placeholder: '搜索书名加入书单',
        keyword: $addKeyword,
        onSearch: () => {
          void this.searchBooksForAdd(1);
        },
      });
      if (this.addSearching) {
        LoadingState({});
      } else if (this.addResults.length === 0) {
        Text(this.addKeyword.trim().length === 0 ? '输入关键词搜索书籍' : '未找到相关书籍')
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(24);
      } else {
        List({ space: 8 }) {
          LazyForEach(this.addResultsSource, (item: SheetBookItem) => {
            ListItem() {
              Row({ space: 10 }) {
                AuthImage({
                  url: item.cover,
                  imageWidth: 42,
                  imageHeight: 58,
                });
                Text(item.title)
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1);
                ChipButton({
                  label: item.inList ? '移出' : '加入',
                  selected: item.inList,
                  onTap: () => {
                    void this.toggleBookInList(item);
                  },
                });
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 4, bottom: 4 })
              .alignItems(VerticalAlign.Center);
            }
          }, (item: SheetBookItem) => `add-${item.bookId}-${item.inList}`);
          if (this.addSearchingMore) {
            ListItem() {
              Text('加载中…')
                .fontSize(13)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding(12);
            }
          }
        }
        .height(360)
        .width('100%')
        .cachedCount(6)
        .onReachEnd(() => this.loadMoreAddResults());
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 16 });
  }

  @Builder
  addBookAction() {
    if (this.isOwner()) {
      IconCircleButton({
        icon: $r('sys.symbol.plus'),
        variant: 'soft',
        iconSize: 18,
        buttonSize: 32,
        onTap: () => this.openAddSheet(),
      });
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '书单详情',
        showBack: true,
        action: () => {
          this.addBookAction();
        },
        content: () => {
          this.detailContent();
        },
      });
    }
    .width('100%')
    .height('100%')
    // 三个面板合并为**一个** bindSheet：同一节点上链式挂多个 bindSheet 时只有第一个生效，
    // 表现为「编辑书单弹得出、添加书籍/分享卡片点了没反应」。用面板枚举做单一开关。
    .bindSheet($$this.showSheet, this.sheetContent(), {
      height: this.sheetSize(),
      dragBar: true,
      showClose: true,
      title: { title: this.sheetTitle() },
      onDisappear: () => {
        // 关闭后回到「无面板」，避免下次打开时沿用上一个面板
        this.sheetKind = SHEET_NONE;
      },
    });
  }

  private sheetTitle(): string {
    if (this.sheetKind === SHEET_ADD) {
      return '添加书籍';
    }
    if (this.sheetKind === SHEET_SHARE) {
      return '书单分享卡片';
    }
    return '编辑书单';
  }

  private sheetSize(): SheetSize {
    // 添加书籍需要搜索框 + 结果列表，给中等高度；其余按内容自适应
    return this.sheetKind === SHEET_ADD ? SheetSize.MEDIUM : SheetSize.FIT_CONTENT;
  }

  @Builder
  sheetContent() {
    if (this.sheetKind === SHEET_ADD) {
      this.addSheet();
    } else if (this.sheetKind === SHEET_SHARE) {
      this.shareSheet();
    } else {
      this.editSheet();
    }
  }

  @Builder
  shareSheet() {
    Column({ space: 12 }) {
      Column({ space: 10 }) {
        Text(this.detail !== null ? this.detail.name : '')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#182431')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
        if (this.detail !== null && this.detail.description.length > 0) {
          Text(this.detail.description)
            .fontSize(12)
            .fontColor('#66182431')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
        }
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.books.slice(0, 9), (book: BookListCoverBook) => {
            AuthImage({
              url: book.thumb.length > 0 ? book.thumb : book.img,
              imageWidth: 62,
              imageHeight: 85,
            })
              .margin({ right: 6, bottom: 6 });
          }, (book: BookListCoverBook) => `share-${book.bookId}`);
        }
        .width('100%');
        Row({ space: 12 }) {
          QRCode(this.shareUrl)
            .width(96)
            .height(96);
          Column({ space: 4 }) {
            Text('扫码在浏览器打开')
              .fontSize(12)
              .fontColor('#66182431');
            Text('Talebook 书单')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#182431');
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1);
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);
      }
      .width('100%')
      .padding(16)
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor('#FFFFFF')
      .id('booklistShareCard');
      PrimaryButton({
        label: this.shareSaving ? '生成中…' : '保存图片',
        buttonEnabled: !this.shareSaving,
        onTap: () => {
          void this.saveShareCard();
        },
      });
    }
    .width('100%')
    .padding($r('app.float.page_padding'));
  }

  @Builder
  detailContent() {
    if (this.loading) {
      LoadingState({});
    } else if (this.errorMessage.length > 0) {
      EmptyState({ message: this.errorMessage });
    } else if (this.detail === null) {
      EmptyState({ message: '书单不存在' });
    } else {
      // 按行虚拟化：封面再多也只建可见行（原实现是 Scroll 里全量 ForEach，越滑越多节点）
      List({ space: 12 }) {
        ListItem() {
          this.headerCard();
        }
        ListItem() {
          this.orderChips();
        }
        LazyForEach(this.coverRows, (row: CoverCell[]) => {
          ListItem() {
            this.coverRow(row);
          }
        }, (row: CoverCell[]) => coverRowKey(row));
        if (this.books.length === 0 && !this.isOwner()) {
          // owner 空书单有虚线「添加书籍」格已是引导；非 owner 之前完全空白
          ListItem() {
            Column({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.book'))
                .fontSize(28)
                .fontColor([$r('app.color.text_tertiary')]);
              Text('这个书单还没有书籍')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'));
            }
            .width('100%')
            .padding({ top: 24, bottom: 24, left: 16, right: 16 })
            .alignItems(HorizontalAlign.Center);
          }
        }
        if (this.loadingMore) {
          ListItem() {
            Text('加载中…')
              .fontSize(13)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding(12);
          }
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ bottom: 16 })
      .cachedCount(COVER_CACHE_ROWS)
      .onScrollIndex((_first: number, last: number) => {
        const rowCount: number = this.coverRows.totalCount();
        if (last + LOAD_MORE_THRESHOLD_ROWS >= COVER_HEADER_ITEMS + rowCount) {
          this.loadMore();
        }
      });
    }
  }
}
