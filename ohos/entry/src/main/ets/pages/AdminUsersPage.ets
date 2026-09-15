import {
  PageScaffold, LoadingState, EmptyState, PrimaryButton, IconCircleButton,
} from '../components';
import { TalebookApi } from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { PaginationConstants, PaginationHelper } from '../utils/PaginationHelper';

interface SelectOptionDef {
  text: string;
  value: Object;
}

const READ_LIMIT_OPTIONS: SelectOptionDef[] = [
  { text: '允许阅读所有书籍', value: 0 },
  { text: '只允许阅读指定分类/标签的书籍', value: 1 },
  { text: '禁止阅读指定分类/标签的书籍', value: 2 },
];

const PROVIDER_LABELS: Record<string, string> = {
  'register': '注册',
  'qq': 'QQ',
  'github': 'GitHub',
  'weibo': '微博',
  'weixin': '微信',
};

@Entry
@Component
struct AdminUsersPage {
  @State users: Record<string, Object>[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State currentPage: number = 1;
  @State hasMore: boolean = true;
  @State totalCount: number = 0;
  @State quotaEnabled: boolean = false;
  @State saving: boolean = false;
  @State showEditSheet: boolean = false;
  @State showAddSheet: boolean = false;
  @State editId: number = -1;
  @State editName: string = '';
  @State editActive: boolean = true;
  @State editAdmin: boolean = false;
  @State editReview: boolean = true;
  @State editPassword: string = '';
  @State editReadLimit: number = 0;
  @State editCategories: string = '';
  @State editTags: string = '';
  @State editQuota: string = '-1';
  @State newUsername: string = '';
  @State newNickname: string = '';
  @State newEmail: string = '';
  @State newPassword: string = '';
  private lastLoadTime: number = 0;

  aboutToAppear(): void {
    void this.loadUsers(true);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private async loadUsers(reset: boolean = true): Promise<void> {
    if (reset) {
      this.currentPage = 1;
      this.hasMore = true;
      this.users = [];
      this.loading = true;
    } else {
      this.loadingMore = true;
    }
    const page = this.currentPage;
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.getAdminUserList(page, PaginationConstants.PAGE_SIZE);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        if (!reset) {
          this.currentPage = Math.max(1, this.currentPage - 1);
        }
        return;
      }
      const userPage = rsp.users ?? {};
      const fetched = userPage.items ?? [];
      this.users = reset ? fetched : this.users.concat(fetched);
      this.totalCount = userPage.total !== undefined ? userPage.total : this.users.length;
      this.hasMore = PaginationHelper.computeHasMore(fetched.length);
      const settings = rsp.settings ?? {};
      this.quotaEnabled = Boolean(settings['enable_download_quota']);
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
    void this.loadUsers(false);
  }

  private userName(user: Record<string, Object>): string {
    const name = String(user['name'] ?? '');
    return name.length > 0 ? name : String(user['username'] ?? '用户');
  }

  private providerLabel(user: Record<string, Object>): string {
    const provider = String(user['provider'] ?? 'register');
    const label = PROVIDER_LABELS[provider];
    return label !== undefined ? label : provider;
  }

  private readingHours(user: Record<string, Object>): number {
    return Math.round(Number(user['total_reading_seconds'] ?? 0) / 3600);
  }

  private showUserActions(user: Record<string, Object>): void {
    const userId = Number(user['id'] ?? 0);
    const active = Boolean(user['is_active']);
    const admin = Boolean(user['is_admin']);
    const review = user['allow_review'] !== false;
    this.getUIContext().getPromptAction().showActionMenu({
      title: this.userName(user),
      buttons: [
        { text: active ? '禁用账号' : '启用账号', color: '#007DFF' },
        { text: admin ? '取消管理员' : '设为管理员', color: '#007DFF' },
        { text: review ? '禁止评论' : '允许评论', color: '#007DFF' },
        { text: '编辑资料与权限', color: '#007DFF' },
        { text: '删除用户', color: '#E84026' },
      ],
    }).then((result) => {
      if (result.index === 0) {
        this.patchUser({ 'id': userId, 'active': !active }, active ? '账号已禁用' : '账号已启用');
      } else if (result.index === 1) {
        this.patchUser({ 'id': userId, 'admin': !admin }, admin ? '已取消管理员' : '已设为管理员');
      } else if (result.index === 2) {
        this.patchUser({ 'id': userId, 'allow_review': !review }, review ? '已禁止评论' : '已允许评论');
      } else if (result.index === 3) {
        this.openEditSheet(user);
      } else if (result.index === 4) {
        this.confirmDeleteUser(user);
      }
    }).catch(() => {});
  }

  private patchUser(payload: Record<string, Object>, successMsg: string): void {
    TalebookApi.updateAdminUser(payload)
      .then((rsp) => {
        if (rsp.err === undefined || rsp.err === 'ok') {
          this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : successMsg);
          void this.loadUsers(true);
        } else {
          this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        }
      })
      .catch((e: Object) => this.toast(`操作失败：${e}`));
  }

  private confirmDeleteUser(user: Record<string, Object>): void {
    const username = String(user['username'] ?? '');
    this.getUIContext().showAlertDialog({
      title: '删除用户',
      message: `确定删除用户「${this.userName(user)}」吗？该用户的书架与阅读记录将被清除。`,
      primaryButton: {
        value: '删除',
        action: () => {
          this.patchUser({ 'id': Number(user['id'] ?? 0), 'delete': username }, '已删除');
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private openEditSheet(user: Record<string, Object>): void {
    this.editId = Number(user['id'] ?? 0);
    this.editName = this.userName(user);
    this.editActive = Boolean(user['is_active']);
    this.editAdmin = Boolean(user['is_admin']);
    this.editReview = user['allow_review'] !== false;
    this.editPassword = '';
    this.editReadLimit = Number(user['read_limit'] ?? 0);
    this.editCategories = String(user['limit_categories'] ?? '');
    this.editTags = String(user['limit_tags'] ?? '');
    this.editQuota = String(user['download_daily_quota'] ?? -1);
    this.showEditSheet = true;
  }

  private saveEdit(): void {
    if (this.saving) {
      return;
    }
    if (this.editPassword.length > 0 && (this.editPassword.length < 6 || this.editPassword.length > 20)) {
      this.toast('密码长度须在6~20位之间');
      return;
    }
    const payload: Record<string, Object> = {
      'id': this.editId,
      'active': this.editActive,
      'admin': this.editAdmin,
      'allow_review': this.editReview,
      'read_limit': this.editReadLimit,
      'limit_categories': this.editCategories,
      'limit_tags': this.editTags,
    };
    if (this.quotaEnabled) {
      const quota = parseInt(this.editQuota, 10);
      payload['download_daily_quota'] = isNaN(quota) ? -1 : quota;
    }
    if (this.editPassword.length > 0) {
      payload['password'] = this.editPassword;
    }
    this.saving = true;
    TalebookApi.updateAdminUser(payload)
      .then((rsp) => {
        this.saving = false;
        if (rsp.err === undefined || rsp.err === 'ok') {
          this.toast('已保存');
          this.showEditSheet = false;
          void this.loadUsers(true);
        } else {
          this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        }
      })
      .catch((e: Object) => {
        this.saving = false;
        this.toast(`保存失败：${e}`);
      });
  }

  private submitAddUser(): void {
    if (this.saving) {
      return;
    }
    const username = this.newUsername.trim();
    const password = this.newPassword.trim();
    const nickname = this.newNickname.trim();
    const email = this.newEmail.trim();
    if (username.length < 3 || username.length > 20) {
      this.toast('用户名长度须在3~20位之间');
      return;
    }
    if (password.length < 6 || password.length > 20) {
      this.toast('密码长度须在6~20位之间');
      return;
    }
    if (nickname.length === 0) {
      this.toast('请填写昵称');
      return;
    }
    if (email.indexOf('@') < 0) {
      this.toast('Email无效');
      return;
    }
    if (!ServerRegistry.supports(ServerFeature.ADMIN_USER_CREATE)) {
      this.saving = false;
      this.toast(`${ServerRegistry.profile().displayName} 服务端不支持在客户端新增用户`);
      return;
    }
    this.saving = true;
    TalebookApi.createAdminUser(username, password, nickname, email)
      .then((rsp) => {
        this.saving = false;
        if (rsp.err === undefined || rsp.err === 'ok') {
          this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '用户添加成功');
          this.showAddSheet = false;
          this.newUsername = '';
          this.newNickname = '';
          this.newEmail = '';
          this.newPassword = '';
          void this.loadUsers(true);
        } else {
          this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        }
      })
      .catch((e: Object) => {
        this.saving = false;
        this.toast(`添加失败：${e}`);
      });
  }

  private readLimitLabel(): string {
    const index = this.editReadLimit;
    if (index >= 0 && index < READ_LIMIT_OPTIONS.length) {
      return READ_LIMIT_OPTIONS[index].text;
    }
    return READ_LIMIT_OPTIONS[0].text;
  }

  build() {
    Column() {
      PageScaffold({
        title: '用户管理',
        showBack: true,
        action: () => {
          this.addUserAction();
        },
        content: () => {
          this.listContent();
        },
      })
        .layoutWeight(1);
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showEditSheet, this.editSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      title: { title: `编辑用户 · ${this.editName}` },
    });
  }

  @Builder
  addUserAction() {
    // 新增用户端点只有 MyBooks 提供：talebook 上整个入口不显示（不再靠提交时报错兜底）
    if (ServerRegistry.supports(ServerFeature.ADMIN_USER_CREATE)) {
      IconCircleButton({
        icon: $r('sys.symbol.plus'),
        variant: 'ghost',
        onTap: () => {
          this.showAddSheet = true;
        },
      });
    }
  }

  @Builder
  listContent() {
    Column() {
      Row() {
        Text(`共 ${this.totalCount} 位用户 · 点按用户进行管理`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1);
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 4 });

      if (this.loading) {
        LoadingState({});
      } else if (this.users.length === 0) {
        EmptyState({ message: '暂无用户' });
      } else {
        List({ space: 8 }) {
          ForEach(this.users, (user: Record<string, Object>) => {
            ListItem() {
              this.userRow(user);
            }
          }, (user: Record<string, Object>) => `user-${Number(user['id'] ?? 0)}`);
          if (this.loadingMore) {
            ListItem() {
              LoadingState({ hint: '加载更多...' });
            }
          }
        }
        .layoutWeight(1)
        .width('100%')
        .onReachEnd(() => this.loadMore());
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showAddSheet, this.addSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      title: { title: '添加用户' },
    });
  }

  @Builder
  userRow(user: Record<string, Object>) {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text(this.userName(user))
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        if (Boolean(user['is_admin'])) {
          Text('管理员')
            .fontSize(11)
            .fontColor($r('app.color.on_brand'))
            .backgroundColor($r('app.color.brand_primary_light'))
            .borderRadius(4)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 });
        }
        if (!Boolean(user['is_active'])) {
          Text('已禁用')
            .fontSize(11)
            .fontColor($r('app.color.error'))
            .backgroundColor($r('app.color.error_light'))
            .borderRadius(4)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 });
        }
        if (user['allow_review'] === false) {
          Text('禁止评论')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor($r('app.color.page_background'))
            .borderRadius(4)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 });
        }
      }
      .width('100%');

      Text(`${String(user['email'] ?? '')} · ${this.providerLabel(user)} · 最近访问 ${String(user['access_time'] ?? 'N/A')}`)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });

      Text(`阅读 ${Number(user['read_count'] ?? 0)} 次 · 下载 ${Number(user['download_count'] ?? 0)} 次 · 推送 ${Number(user['push_count'] ?? 0)} 次 · 时长 ${this.readingHours(user)} 小时`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'));
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(() => this.showUserActions(user));
  }

  @Builder
  sheetInput(label: string, text: string, onChange: (value: string) => void) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'));
      TextInput({ text: text })
        .height(44)
        .fontSize(14)
        .borderRadius(8)
        .backgroundColor($r('app.color.page_background'))
        .onChange((value: string) => onChange(value));
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  sheetToggle(label: string, on: boolean, onChange: (value: boolean) => void) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1);
      Toggle({ type: ToggleType.Switch, isOn: on })
        .onChange((value: boolean) => onChange(value));
    }
    .width('100%');
  }

  @Builder
  editSheet() {
    Scroll() {
      Column({ space: 12 }) {
        this.sheetToggle('启用账号', this.editActive, (value: boolean) => {
          this.editActive = value;
        });
        this.sheetToggle('管理员权限', this.editAdmin, (value: boolean) => {
          this.editAdmin = value;
        });
        this.sheetToggle('允许评论', this.editReview, (value: boolean) => {
          this.editReview = value;
        });

        Column({ space: 6 }) {
          Text('重置密码（留空表示不修改）')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'));
          TextInput({ text: this.editPassword, placeholder: '6~20位新密码' })
            .height(44)
            .fontSize(14)
            .borderRadius(8)
            .backgroundColor($r('app.color.page_background'))
            .type(InputType.Password)
            .onChange((value: string) => {
              this.editPassword = value;
            });
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start);

        Column({ space: 6 }) {
          Text('阅读范围')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'));
          Select([
            { value: READ_LIMIT_OPTIONS[0].text },
            { value: READ_LIMIT_OPTIONS[1].text },
            { value: READ_LIMIT_OPTIONS[2].text },
          ] as SelectOption[])
            .selected(this.editReadLimit)
            .value(this.readLimitLabel())
            .fontColor($r('app.color.text_primary'))
            .font({ size: 14 })
            .backgroundColor($r('app.color.page_background'))
            .onSelect((index: number) => {
              this.editReadLimit = index;
            });
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start);

        if (this.editReadLimit > 0) {
          this.sheetInput('分类（多个用英文逗号分隔）', this.editCategories, (value: string) => {
            this.editCategories = value;
          });
          this.sheetInput('标签（多个用英文逗号分隔）', this.editTags, (value: string) => {
            this.editTags = value;
          });
        }

        if (this.quotaEnabled) {
          this.sheetInput('每日下载配额（-1 表示跟随全局）', this.editQuota, (value: string) => {
            this.editQuota = value;
          });
        }

        PrimaryButton({
          label: this.saving ? '保存中…' : '保存',
          buttonEnabled: !this.saving,
          onTap: () => this.saveEdit(),
        });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 16 });
    }
    .constraintSize({ minHeight: 200, maxHeight: 480 });
  }

  @Builder
  addSheet() {
    Scroll() {
      Column({ space: 12 }) {
        this.sheetInput('用户名（3~20位）', this.newUsername, (value: string) => {
          this.newUsername = value;
        });
        this.sheetInput('昵称', this.newNickname, (value: string) => {
          this.newNickname = value;
        });
        this.sheetInput('Email', this.newEmail, (value: string) => {
          this.newEmail = value;
        });
        this.sheetInput('密码（6~20位）', this.newPassword, (value: string) => {
          this.newPassword = value;
        });
        PrimaryButton({
          label: this.saving ? '添加中…' : '添加用户',
          buttonEnabled: !this.saving,
          onTap: () => this.submitAddUser(),
        });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 16 });
    }
    .constraintSize({ minHeight: 200, maxHeight: 480 });
  }
}
