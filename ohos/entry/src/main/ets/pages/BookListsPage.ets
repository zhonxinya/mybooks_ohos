import { router } from '@kit.ArkUI';
import {
  PageScaffold, FilterChips, FilterChipItem, LoadingState, EmptyState,
  BookListCardItem, IconCircleButton, PrimaryButton,
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { ApiMessageResult } from '../services/TalebookApi';
import {
  BookListApi, BookListsPageResponse, BookListsResponse, BookListLikeResponse,
  BookListMutationResponse,
} from '../services/BookListApi';
import {
  BookListSummary, BOOKLIST_COLORS, BookListColorOption,
  DEFAULT_BOOKLIST_COLOR, booklistColorHex,
} from '../models/BookListModels';
import { PaginationConstants, PaginationHelper } from '../utils/PaginationHelper';

const TAB_PUBLIC: number = 0;
const TAB_LIKED: number = 1;
const TAB_MINE: number = 2;

@Entry
@Component
struct BookListsPage {
  @State activeTab: number = TAB_PUBLIC;
  @State lists: BookListSummary[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State currentPage: number = 1;
  @State hasMore: boolean = false;
  @State errorMessage: string = '';
  @State needLogin: boolean = false;
  @State showEditSheet: boolean = false;
  @State editingId: number = -1;
  @State editName: string = '';
  @State editDescription: string = '';
  @State editColor: string = DEFAULT_BOOKLIST_COLOR;
  @State editIsPublic: boolean = false;
  @State saving: boolean = false;
  private lastLoadTime: number = 0;

  aboutToAppear(): void {
    void this.prepareAndLoad();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private tabItems(): FilterChipItem[] {
    return [
      { label: '公开书单', value: TAB_PUBLIC },
      { label: '点赞', value: TAB_LIKED },
      { label: '我的书单', value: TAB_MINE },
    ];
  }

  private async prepareAndLoad(): Promise<void> {
    this.needLogin = false;
    if (this.activeTab !== TAB_PUBLIC && TalebookService.hasAuthCredentials()) {
      await TalebookService.ensureAuthenticated();
    }
    await this.loadLists(true);
  }

  private async loadLists(reset: boolean): Promise<void> {
    if (reset) {
      this.currentPage = 1;
      this.hasMore = false;
      this.loading = this.lists.length === 0;
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
      if (this.activeTab === TAB_PUBLIC) {
        const rsp = await BookListApi.getPublicBooklists(page, PaginationConstants.PAGE_SIZE);
        if (!this.applyResult(rsp, reset)) {
          return;
        }
        this.hasMore = this.lists.length < (rsp.total ?? 0);
      } else if (this.activeTab === TAB_LIKED) {
        const rsp = await BookListApi.getLikedBooklists();
        if (!this.applyResult(rsp, reset)) {
          return;
        }
        this.hasMore = false;
      } else {
        const rsp = await BookListApi.getMyBooklists();
        if (!this.applyResult(rsp, reset)) {
          return;
        }
        this.hasMore = false;
      }
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

  private applyResult(rsp: BookListsPageResponse | BookListsResponse, reset: boolean): boolean {
    if (rsp.err !== undefined && rsp.err !== 'ok') {
      if (rsp.err === 'user.need_login') {
        this.needLogin = true;
        return true;
      }
      if (reset) {
        this.errorMessage = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err;
      } else {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '加载更多失败');
        this.currentPage = Math.max(1, this.currentPage - 1);
      }
      return false;
    }
    const fetched = BookListApi.parseSummaries(rsp);
    this.lists = reset ? fetched : this.lists.concat(fetched);
    return true;
  }

  private loadMore(): void {
    if (this.activeTab !== TAB_PUBLIC) {
      return;
    }
    if (!PaginationHelper.canLoadMore(this.lastLoadTime, this.loadingMore, this.hasMore)) {
      return;
    }
    this.currentPage += 1;
    void this.loadLists(false);
  }

  private onTabChange(value: number): void {
    if (value === this.activeTab) {
      return;
    }
    this.activeTab = value;
    this.lists = [];
    void this.prepareAndLoad();
  }

  private async toggleLike(item: BookListSummary): Promise<void> {
    try {
      const rsp = await BookListApi.toggleLike(item.id);
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
      const next = this.lists.map((list: BookListSummary): BookListSummary => {
        if (list.id !== item.id) {
          return list;
        }
        return {
          id: list.id, name: list.name, description: list.description, color: list.color,
          isPublic: list.isPublic, isSticky: list.isSticky, viewCount: list.viewCount,
          likeCount: list.likeCount + (liked ? 1 : -1), bookCount: list.bookCount,
          owner: list.owner, isOwner: list.isOwner, likedByMe: liked, coverBooks: list.coverBooks,
        };
      });
      this.lists = next;
      if (this.activeTab === TAB_LIKED && !liked) {
        void this.loadLists(true);
      }
    } catch (error) {
      this.toast(`操作失败：${error}`);
    }
  }

  private openCreateSheet(): void {
    this.editingId = -1;
    this.editName = '';
    this.editDescription = '';
    this.editColor = DEFAULT_BOOKLIST_COLOR;
    this.editIsPublic = false;
    this.showEditSheet = true;
  }

  private openEditSheet(item: BookListSummary): void {
    this.editingId = item.id;
    this.editName = item.name;
    this.editDescription = item.description;
    this.editColor = item.color;
    this.editIsPublic = item.isPublic;
    this.showEditSheet = true;
  }

  private async saveSheet(): Promise<void> {
    const name = this.editName.trim();
    if (name.length === 0) {
      this.toast('书单名称不能为空');
      return;
    }
    if (this.saving) {
      return;
    }
    this.saving = true;
    try {
      let rsp: BookListMutationResponse;
      if (this.editingId > 0) {
        rsp = await BookListApi.updateBooklist(this.editingId, {
          name: name,
          description: this.editDescription.trim(),
          color: this.editColor,
          is_public: this.editIsPublic,
        });
      } else {
        rsp = await BookListApi.createBooklist(name, this.editDescription.trim(), this.editColor,
          this.editIsPublic);
      }
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已保存');
      this.showEditSheet = false;
      void this.loadLists(true);
    } catch (error) {
      this.toast(`保存失败：${error}`);
    } finally {
      this.saving = false;
    }
  }

  private confirmDelete(item: BookListSummary): void {
    this.getUIContext().showAlertDialog({
      title: '删除书单',
      message: `确定删除书单「${item.name}」吗？该操作不可恢复。`,
      primaryButton: {
        value: '删除',
        action: () => {
          BookListApi.deleteBooklist(item.id)
            .then((rsp: ApiMessageResult) => {
              if (rsp.err === undefined || rsp.err === 'ok') {
                this.toast('已删除');
                void this.loadLists(true);
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

  private showManageMenu(item: BookListSummary): void {
    this.getUIContext().getPromptAction().showActionMenu({
      title: item.name,
      buttons: [
        { text: '编辑', color: '#007DFF' },
        { text: item.isPublic ? '设为私有' : '设为公开', color: '#007DFF' },
        { text: '删除', color: '#E84026' },
      ],
    }).then((result) => {
      if (result.index === 0) {
        this.openEditSheet(item);
      } else if (result.index === 1) {
        void this.toggleVisibility(item);
      } else if (result.index === 2) {
        this.confirmDelete(item);
      }
    }).catch(() => {});
  }

  private async toggleVisibility(item: BookListSummary): Promise<void> {
    try {
      const rsp = await BookListApi.updateBooklist(item.id, { is_public: !item.isPublic });
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        return;
      }
      this.toast(item.isPublic ? '已设为私有' : '已设为公开');
      void this.loadLists(true);
    } catch (error) {
      this.toast(`操作失败：${error}`);
    }
  }

  private openDetail(item: BookListSummary): void {
    router.pushUrl({
      url: 'pages/BookListDetailPage',
      params: { booklistId: item.id },
    });
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
        label: this.editingId > 0 ? '保存修改' : '创建书单',
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
  listBody() {
    if (this.loading) {
      LoadingState({});
    } else if (this.needLogin) {
      EmptyState({
        message: '请先登录',
        detail: '登录后可查看点赞书单与我的书单',
        actionLabel: '去登录',
        onAction: () => router.pushUrl({ url: 'pages/LoginPage' }),
      });
    } else if (this.errorMessage.length > 0) {
      EmptyState({ message: this.errorMessage });
    } else if (this.lists.length === 0) {
      EmptyState({
        message: this.activeTab === TAB_PUBLIC ? '暂无公开书单' :
          (this.activeTab === TAB_LIKED ? '还没有点赞书单' : '还没有创建书单'),
        detail: this.activeTab === TAB_MINE ? '点击右上角 + 创建书单' : '',
      });
    } else {
      List({ space: 12 }) {
        ForEach(this.lists, (item: BookListSummary) => {
          ListItem() {
            BookListCardItem({
              item: item,
              showManage: this.activeTab === TAB_MINE && item.isOwner,
              showRecommendBadge: this.activeTab === TAB_PUBLIC,
              onItemTap: () => this.openDetail(item),
              onLikeTap: () => {
                void this.toggleLike(item);
              },
              onManageTap: () => this.showManageMenu(item),
            });
          }
        }, (item: BookListSummary) => `booklist-${item.id}-${item.likeCount}-${item.isPublic}`);
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
      .padding({ left: 16, right: 16, bottom: 16 })
      .onReachEnd(() => this.loadMore());
    }
  }

  @Builder
  createBooklistAction() {
    IconCircleButton({
      icon: $r('sys.symbol.plus'),
      variant: 'soft',
      iconSize: 18,
      buttonSize: 32,
      onTap: () => this.openCreateSheet(),
    });
  }

  @Builder
  tabFilterChips() {
    FilterChips({
      items: this.tabItems(),
      selected: $activeTab,
      onChange: (value: number) => this.onTabChange(value),
    });
  }

  build() {
    Column() {
      PageScaffold({
        title: '书单',
        showBack: true,
        action: () => {
          this.createBooklistAction();
        },
        content: () => {
          this.tabFilterChips();
          this.listBody();
        },
      });
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showEditSheet, this.editSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      title: { title: this.editingId > 0 ? '编辑书单' : '创建书单' },
    });
  }
}
