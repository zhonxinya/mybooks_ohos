import { router } from '@kit.ArkUI';
import { componentSnapshot } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  PageScaffold, LoadingState, EmptyState, AuthImage, IconCircleButton,
  ChipButton, PrimaryButton, SearchBar,
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

interface SheetBookItem {
  bookId: number;
  title: string;
  cover: string;
  inList: boolean;
}

const DETAIL_PAGE_SIZE: number = 24;

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
  @State showEditSheet: boolean = false;
  @State editName: string = '';
  @State editDescription: string = '';
  @State editColor: string = DEFAULT_BOOKLIST_COLOR;
  @State editIsPublic: boolean = false;
  @State saving: boolean = false;
  @State showAddSheet: boolean = false;
  @State showShareSheet: boolean = false;
  @State shareUrl: string = '';
  @State shareSaving: boolean = false;
  @State addKeyword: string = '';
  @State addResults: SheetBookItem[] = [];
  @State addSearching: boolean = false;
  @State addSearchingMore: boolean = false;
  @State addPage: number = 1;
  private lastLoadTime: number = 0;
  private lastAddTime: number = 0;

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    this.booklistId = Number(params['booklistId'] ?? 0);
    void this.prepareAndLoad();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private isOwner(): boolean {
    return this.detail !== null && this.detail.isOwner;
  }

  private async prepareAndLoad(): Promise<void> {
    if (TalebookService.hasAuthCredentials()) {
      await TalebookService.ensureAuthenticated();
    }
    if (this.booklistId > 0) {
      BookListApi.bumpView(this.booklistId).catch(() => {});
    }
    await this.loadDetail(true);
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
        if (rsp.err === 'user.need_login') {
          this.toast('请先登录');
          router.pushUrl({ url: 'pages/LoginPage' });
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
    this.showEditSheet = true;
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
      this.showEditSheet = false;
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
                router.back();
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
    this.getUIContext().getPromptAction().showActionMenu({
      title: this.detail.name,
      buttons: [
        { text: '编辑书单', color: '#007DFF' },
        { text: this.detail.isPublic ? '设为私有' : '设为公开', color: '#007DFF' },
        { text: '生成分享卡片', color: '#007DFF' },
        { text: '删除书单', color: '#E84026' },
      ],
    }).then((result) => {
      if (result.index === 0) {
        this.openEditSheet();
      } else if (result.index === 1) {
        void this.toggleVisibility();
      } else if (result.index === 2) {
        this.openShareSheet();
      } else if (result.index === 3) {
        this.confirmDelete();
      }
    }).catch(() => {});
  }

  private openShareSheet(): void {
    if (this.detail === null || !this.detail.isPublic) {
      this.toast('私有书单不支持分享');
      return;
    }
    const base = TalebookService.secureGet('talebook_url');
    const normalized = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    this.shareUrl = `${normalized}/booklist/${this.booklistId}`;
    this.showShareSheet = true;
  }

  private async saveShareCard(): Promise<void> {
    if (this.shareSaving) {
      return;
    }
    this.shareSaving = true;
    try {
      const pm = await componentSnapshot.get('booklistShareCard');
      const packer = image.createImagePacker();
      const data: ArrayBuffer = await packer.packToData(pm, { format: 'image/jpeg', quality: 92 });
      const context = getContext(this) as common.UIAbilityContext;
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
    this.showAddSheet = true;
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
                if (this.detail !== null) {
                  this.detail = {
                    id: this.detail.id, name: this.detail.name, description: this.detail.description,
                    color: this.detail.color, isPublic: this.detail.isPublic,
                    isSticky: this.detail.isSticky, viewCount: this.detail.viewCount,
                    likeCount: this.detail.likeCount,
                    bookCount: Math.max(0, this.detail.bookCount - 1),
                    owner: this.detail.owner, isOwner: this.detail.isOwner,
                    likedByMe: this.detail.likedByMe, coverBooks: this.detail.coverBooks,
                    books: this.detail.books, booksTotal: Math.max(0, this.detail.booksTotal - 1),
                    page: this.detail.page, pageSize: this.detail.pageSize,
                  };
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

  private openBook(bookId: number): void {
    router.pushUrl({ url: 'pages/BookDetailPage', params: { bookId: bookId } });
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

  @Builder
  booksGrid() {
    GridRow({
      columns: 12,
      gutter: { x: 10, y: 12 },
    }) {
      if (this.isOwner()) {
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
          .border({ width: 1, color: $r('app.color.divider'), style: BorderStyle.Dashed })
          .onClick(() => this.openAddSheet());
        }
      }
      ForEach(this.books, (book: BookListCoverBook) => {
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
      }, (book: BookListCoverBook) => `book-${book.bookId}`);
    }
    .width('100%')
    .padding({ left: 16, right: 16 });
  }

  @Builder
  editSheet() {
    Column({ space: 12 }) {
      TextInput({ text: this.editName, placeholder: '书单名称' })
        .width('100%')
        .height(44)
        .onChange((value: string) => {
          this.editName = value;
        });
      TextArea({ text: this.editDescription, placeholder: '简介（可选）' })
        .width('100%')
        .height(90)
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
            .border({
              width: 2,
              color: this.editColor === option.key ? $r('app.color.text_primary') : Color.Transparent,
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
          ForEach(this.addResults, (item: SheetBookItem) => {
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
    .bindSheet($$this.showEditSheet, this.editSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      title: { title: '编辑书单' },
    })
    .bindSheet($$this.showAddSheet, this.addSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: true,
      title: { title: '添加书籍' },
    })
    .bindSheet($$this.showShareSheet, this.shareSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      title: { title: '书单分享卡片' },
    });
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
      .borderRadius(16)
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
      Scroll() {
        Column({ space: 12 }) {
          this.headerCard();
          this.orderChips();
          this.booksGrid();
          if (this.loadingMore) {
            Text('加载中…')
              .fontSize(13)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding(12);
          }
        }
        .width('100%')
        .padding({ top: 12, bottom: 16 });
      }
      .layoutWeight(1)
      .width('100%')
      .onReachEnd(() => this.loadMore());
    }
  }
}
