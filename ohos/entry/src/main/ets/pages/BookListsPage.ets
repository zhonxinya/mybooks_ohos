import { promptAction } from '@kit.ArkUI';
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

/** 对齐服务端约束：BookList.name 为 String(100)、description 服务端截断到 500。 */
const BOOKLIST_NAME_MAX: number = 100;
const BOOKLIST_DESC_MAX: number = 500;

/**
 * 书单卡片的 ForEach key。
 *
 * **必须覆盖卡片真正渲染的所有可变字段**：ArkUI 的 ForEach 对 key 不变的项会复用旧组件，
 * 而 `BookListCardItem.item` 是普通成员（非 @Prop），复用后不会更新。
 * 早先只拼了 id/likeCount/isPublic，导致「置顶」后卡片不出现「推荐」角标、
 * 「编辑」改名或改简介后卡片也不刷新。
 */
function bookListCardKey(item: BookListSummary): string {
  return `booklist-${item.id}-${item.name}-${item.description}-${item.isPublic}-${item.isSticky}` +
    `-${item.bookCount}-${item.viewCount}-${item.likeCount}-${item.likedByMe}`;
}

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
  /** 当前账号是否管理员：服务端书单置顶为 `@is_admin`，据此决定菜单里是否出现「置顶」。 */
  @State isAdmin: boolean = false;
  private lastLoadTime: number = 0;
  /**
   * 已实际加载过的 Tab。
   *
   * FilterChips 的 `selected` 是 `@Link`：点击时它先把父组件的 activeTab 回写成 value，**之后**才回调 onChange。
   * 因此 onChange 里不能拿 activeTab 做「是否变化」判断（那时恒相等），必须与本字段比较，
   * 否则列表永远不会重新加载——切到「点赞」后仍显示「公开书单」的内容。
   */
  private loadedTab: number = -1;
  /** 请求序号：切换 Tab 时旧请求可能后到，用序号丢弃过期响应，避免覆盖新 Tab 的数据。 */
  private requestSeq: number = 0;

  aboutToAppear(): void {
    void this.prepareAndLoad();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private tabItems(): FilterChipItem[] {
    return [
      { label: '公开书单', value: TAB_PUBLIC },
      { label: '点赞', value: TAB_LIKED },
      { label: '我的书单', value: TAB_MINE },
    ];
  }

  private async prepareAndLoad(): Promise<void> {
    this.loadedTab = this.activeTab;
    this.needLogin = false;
    if (this.activeTab !== TAB_PUBLIC && TalebookService.hasAuthCredentials()) {
      await TalebookService.ensureAuthenticated();
    }
    // 管理员标记只影响管理菜单，不阻塞列表加载
    void this.loadAdminFlag();
    await this.loadLists(true);
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
    const seq = ++this.requestSeq;
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.errorMessage = '请先配置 Talebook 服务器';
        return;
      }
      // 只有「公开书单」服务端支持分页（/api/booklists/public 带 page/page_size）；
      // mine 与 liked 服务端一次性返回全量，因此 hasMore 恒为 false。
      if (this.activeTab === TAB_PUBLIC) {
        const rsp = await BookListApi.getPublicBooklists(page, PaginationConstants.PAGE_SIZE);
        if (seq !== this.requestSeq) {
          return;
        }
        if (!this.applyResult(rsp, reset)) {
          return;
        }
        this.hasMore = this.lists.length < (rsp.total ?? 0);
      } else if (this.activeTab === TAB_LIKED) {
        const rsp = await BookListApi.getLikedBooklists();
        if (seq !== this.requestSeq) {
          return;
        }
        if (!this.applyResult(rsp, reset)) {
          return;
        }
        this.hasMore = false;
      } else {
        const rsp = await BookListApi.getMyBooklists();
        if (seq !== this.requestSeq) {
          return;
        }
        if (!this.applyResult(rsp, reset)) {
          return;
        }
        this.hasMore = false;
      }
    } catch (error) {
      if (seq !== this.requestSeq) {
        return;
      }
      if (reset) {
        this.errorMessage = error instanceof Error ? error.message : `${error}`;
      } else {
        this.toast('加载更多失败');
        this.currentPage = Math.max(1, this.currentPage - 1);
      }
    } finally {
      // 过期请求不得清掉新请求的 loading 标记，否则会闪一下空态
      if (seq === this.requestSeq) {
        this.loading = false;
        this.loadingMore = false;
        this.lastLoadTime = Date.now();
      }
    }
  }

  private applyResult(rsp: BookListsPageResponse | BookListsResponse, reset: boolean): boolean {
    if (rsp.err !== undefined && rsp.err !== 'ok') {
      if (TalebookService.isLoginRequiredResult(rsp.err, rsp.msg)) {
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
    // 公开书单按 update_time 排序分页，翻页期间书单被更新会跨页重复，故统一按 id 去重
    const known = new Set<number>();
    if (!reset) {
      for (let i = 0; i < this.lists.length; i++) {
        known.add(this.lists[i].id);
      }
    }
    const merged: BookListSummary[] = reset ? [] : this.lists.slice();
    for (let i = 0; i < fetched.length; i++) {
      const item: BookListSummary = fetched[i];
      if (known.has(item.id)) {
        continue;
      }
      known.add(item.id);
      merged.push(item);
    }
    this.lists = merged;
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
    // 不能判断 value === this.activeTab：FilterChips 是 @Link，回写已发生，判断恒真。
    if (value === this.loadedTab) {
      return;
    }
    this.activeTab = value;
    this.lists = [];
    this.hasMore = false;
    this.needLogin = false;
    void this.prepareAndLoad();
  }

  private async toggleLike(item: BookListSummary): Promise<void> {
    try {
      const rsp = await BookListApi.toggleLike(item.id);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        if (TalebookService.isLoginRequiredResult(rsp.err, rsp.msg)) {
          this.toast('请先在「账号与服务器」中配置账号，应用会自动登录');
          this.getUIContext().getRouter().pushUrl({ url: 'pages/TalebookConfigPage' });
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
    // 按能力动态组装按钮，并用同序的 action 列表分发（不依赖 index）
    const buttons: promptAction.Button[] = [];
    const actions: string[] = [];
    buttons.push({ text: '编辑', color: '#007DFF' });
    actions.push('edit');
    buttons.push({ text: item.isPublic ? '设为私有' : '设为公开', color: '#007DFF' });
    actions.push('visibility');
    if (this.isAdmin) {
      // 服务端 BookListStickyHandler 为 @is_admin，仅管理员暴露该入口
      buttons.push({ text: item.isSticky ? '取消置顶' : '置顶', color: '#007DFF' });
      actions.push('sticky');
    }
    buttons.push({ text: '删除', color: '#E84026' });
    actions.push('delete');
    this.getUIContext().getPromptAction().showActionMenu({
      title: item.name,
      buttons: buttons,
    } as promptAction.ActionMenuOptions).then((result) => {
      const action: string = actions[result.index] ?? '';
      if (action === 'edit') {
        this.openEditSheet(item);
      } else if (action === 'visibility') {
        void this.toggleVisibility(item);
      } else if (action === 'sticky') {
        void this.toggleSticky(item);
      } else if (action === 'delete') {
        this.confirmDelete(item);
      }
    }).catch(() => {});
  }

  private async toggleSticky(item: BookListSummary): Promise<void> {
    try {
      const rsp = await BookListApi.setSticky(item.id, !item.isSticky);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        return;
      }
      this.toast(item.isSticky ? '已取消置顶' : '已置顶');
      void this.loadLists(true);
    } catch (error) {
      this.toast(`操作失败：${error}`);
    }
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

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private openDetail(item: BookListSummary): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/BookListDetailPage',
      params: { booklistId: item.id },
    });
  }

  @Builder
  editSheet() {
    Column({ space: 12 }) {
      // maxLength 对齐服务端约束（BookList.name 为 String(100)、description 截断 500），
      // 否则超长简介会被服务端静默截断
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
        message: '请先配置账号',
        detail: '配置账号后应用会自动登录，即可查看点赞书单与我的书单',
        actionLabel: '去配置账号',
        onAction: () => this.getUIContext().getRouter().pushUrl({ url: 'pages/TalebookConfigPage' }),
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
              showRecommendBadge: this.activeTab !== TAB_LIKED,
              onItemTap: () => this.openDetail(item),
              onLikeTap: () => {
                void this.toggleLike(item);
              },
              onManageTap: () => this.showManageMenu(item),
            });
          }
        }, (item: BookListSummary) => bookListCardKey(item));
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
