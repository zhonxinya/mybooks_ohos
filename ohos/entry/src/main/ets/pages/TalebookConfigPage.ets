import { router } from '@kit.ArkUI';
import { PageScaffold, PrimaryButton, SecondaryButton } from '../components';
import { AccountManager } from '../services/AccountManager';
import { AccountStore } from '../services/AccountStore';
import { ServerKind } from '../services/ServerProfile';
import { TalebookService } from '../services/TalebookService';
import { TalebookCoreService } from '../services/TalebookCoreService';
import { AccountInput, AccountRecord, accountHost } from '../models/AccountModels';

/**
 * 账号管理：多账号列表 + 新增账号（可指向新服务器）+ 编辑 + 删除 + 切换。
 *
 * 切换账号后必须整栈重渲染：各页面在 aboutToAppear 里读取配置与拉取数据，
 * 只靠局部刷新会残留上一个账号的书架/历史，因此这里 clear + replaceUrl 回首页重建。
 */
@Entry
@Component
struct TalebookConfigPage {
  @State accounts: AccountRecord[] = [];
  @State activeId: string = '';
  @State message: string = '';
  @State isError: boolean = false;
  @State busy: boolean = false;

  // 表单（新增与编辑共用）
  @State formOpen: boolean = false;
  @State editingId: string = '';
  @State formName: string = '';
  @State formUrl: string = '';
  @State formUsername: string = '';
  @State formPassword: string = '';
  @State formServerKind: string = ServerKind.MYBOOKS;
  @State formAllowInsecureSsl: boolean = false;
  /** SoNovel 是独立的全局服务（不随账号切换），地址直接在本页维护。 */
  @State sonovelUrl: string = '';
  /** 可选服务端；顺序与服务端枚举的解析保持一致。 */
  private serverOptions: SelectOption[] = [
    { value: 'MyBooks' },
    { value: 'Talebook' },
  ];

  aboutToAppear(): void {
    // 兼容直接从本页进入（未经过 EntryAbility 的迁移路径）
    AccountManager.ensureMigrated();
    this.reload();
  }

  private reload(): void {
    this.accounts = AccountManager.list();
    this.activeId = AccountManager.activeId();
    this.sonovelUrl = TalebookService.secureGet('sonovel_url');
  }

  /**
   * 保存 SoNovel 地址：同时写入偏好、密钥库与 native 两套 HttpClient，
   * 与旧版 SoNovelConfigPage 的行为保持一致（缺一处会导致搜索仍走旧地址）。
   */
  private saveSoNovel(): void {
    const url = this.normalizeUrl(this.sonovelUrl);
    this.sonovelUrl = url;
    TalebookService.setBaseUrl('sonovel', url);
    TalebookService.secureSet('sonovel_url', url);
    TalebookCoreService.syncBaseUrl('sonovel', url);
    this.toast(url.length > 0 ? 'SoNovel 地址已保存' : '已清除 SoNovel 地址');
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private serverKindLabel(kind: string): string {
    return kind === ServerKind.TALEBOOK ? 'Talebook' : 'MyBooks';
  }

  private formServerIndex(): number {
    return this.formServerKind === ServerKind.TALEBOOK ? 1 : 0;
  }

  private normalizeUrl(url: string): string {
    let normalized = url.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    // 允许只填 host:port（用户习惯不写协议头），统一补 http://
    if (normalized.length > 0 && normalized.indexOf('://') < 0) {
      normalized = `http://${normalized}`;
    }
    return normalized;
  }

  private activeSummary(): string {
    const active = AccountManager.active();
    if (active === null) {
      return '点击右上角「新增账号」添加服务器与账号';
    }
    return `${this.serverKindLabel(active.serverKind)} · ${accountHost(active.url)} · ${active.username}`;
  }

  /** 打开新增表单（默认继承当前账号的服务端类型与 TLS 设置，便于「同服务器加个账号」）。 */
  private openCreateForm(): void {
    const active = AccountManager.active();
    this.editingId = '';
    this.formName = '';
    this.formUrl = '';
    this.formUsername = '';
    this.formPassword = '';
    this.formServerKind = active === null ? ServerKind.MYBOOKS : active.serverKind;
    this.formAllowInsecureSsl = active === null ? false : active.allowInsecureSsl;
    this.message = '';
    this.formOpen = true;
  }

  private openEditForm(record: AccountRecord): void {
    this.editingId = record.id;
    this.formName = record.name;
    this.formUrl = record.url;
    this.formUsername = record.username;
    // 密码不回显：留空表示保持原密码（避免把密钥读回 UI 层）
    this.formPassword = '';
    this.formServerKind = record.serverKind;
    this.formAllowInsecureSsl = record.allowInsecureSsl;
    this.message = '';
    this.formOpen = true;
  }

  private closeForm(): void {
    this.formOpen = false;
    this.editingId = '';
    this.message = '';
  }

  /** 保存表单：新增后直接切换过去；编辑当前账号后重新应用身份。 */
  private async saveForm(): Promise<void> {
    if (this.busy) {
      return;
    }
    const url = this.normalizeUrl(this.formUrl);
    const username = this.formUsername.trim();
    if (url.length === 0) {
      this.message = '请填写服务器地址';
      this.isError = true;
      return;
    }
    if (username.length === 0) {
      this.message = '请填写用户名';
      this.isError = true;
      return;
    }
    // 新增账号必须填密码：自动登录依赖它；不填会导致新增后只能手动登录
    if (this.editingId.length === 0 && this.formPassword.length === 0) {
      this.message = '请填写密码（新增后用于自动登录）';
      this.isError = true;
      return;
    }
    const input: AccountInput = {
      name: this.formName.trim(),
      serverKind: this.formServerKind,
      url: url,
      username: username,
      password: this.formPassword,
      allowInsecureSsl: this.formAllowInsecureSsl,
    };

    if (this.editingId.length > 0) {
      const editedId = this.editingId;
      if (!AccountManager.update(editedId, input)) {
        this.message = '账号不存在，可能已被删除';
        this.isError = true;
        return;
      }
      this.formOpen = false;
      this.editingId = '';
      this.message = '';
      this.reload();
      if (AccountStore.isActive(editedId)) {
        // 地址/用户名/TLS 变化必须重新应用身份（并重启 UI 使各页面重新拉数据）
        await this.switchTo(editedId, '已保存并重新登录');
      } else {
        this.toast('已保存');
      }
      return;
    }

    const created = AccountManager.add(input);
    this.formOpen = false;
    this.reload();
    await this.switchTo(created.id, '已新增账号并切换');
  }

  /** 切换账号并重启导航栈，使全部页面按新账号重新渲染与拉取数据。 */
  private async switchTo(id: string, successHint: string): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const record = AccountStore.find(id);
      const name = record === null ? '' : AccountManager.displayNameOf(record);
      const attempt = await AccountManager.activate(id);
      // 整栈重建：各页面 aboutToAppear 会读取新账号配置并重新请求
      router.clear();
      router.replaceUrl({ url: 'pages/MainTabs' });
      if (attempt.ok) {
        this.toast(`${successHint}：${name}`);
        return;
      }
      // 自动登录失败：直达登录页（可返回首页），并把服务端原因告诉用户
      this.toast(`已切换到 ${name}：${attempt.reason}`);
      router.pushUrl({ url: 'pages/LoginPage', params: { skipAutoLogin: true } });
    } finally {
      this.busy = false;
    }
  }

  private confirmDelete(record: AccountRecord): void {
    if (this.accounts.length <= 1) {
      this.toast('至少保留一个账号，无法删除');
      return;
    }
    const name = AccountManager.displayNameOf(record);
    this.getUIContext().showAlertDialog({
      title: '删除账号',
      message: `确定删除「${name}」吗？删除后本机不再显示该账号的登录状态与书架数据。`,
      primaryButton: {
        value: '删除',
        action: () => {
          void this.deleteAccount(record);
        },
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        },
      },
    });
  }

  private async deleteAccount(record: AccountRecord): Promise<void> {
    const wasActive = AccountStore.isActive(record.id);
    if (!AccountManager.remove(record.id)) {
      this.toast('至少保留一个账号，无法删除');
      return;
    }
    this.reload();
    if (wasActive) {
      // 删除的是当前账号：AccountManager 已切到剩余首个账号，这里重启 UI 使数据同步
      this.toast('已删除当前账号并切换到其他账号');
      router.clear();
      router.replaceUrl({ url: 'pages/MainTabs' });
      return;
    }
    this.toast('已删除');
  }

  build() {
    Column() {
      PageScaffold({
        title: '账号与服务器',
        showBack: true,
        action: () => {
          this.addAction();
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
  addAction() {
    Text('新增账号')
      .fontSize(14)
      .fontColor($r('app.color.brand_primary'))
      .padding({ left: 8, right: 16 })
      .onClick(() => this.openCreateForm());
  }

  @Builder
  pageContent() {
    Scroll() {
      Column({ space: 12 }) {
        this.currentAccountCard();
        this.accountListCard();
        this.sonovelCard();
        if (this.formOpen) {
          this.formCard();
        }
        if (this.message.length > 0) {
          Text(this.message)
            .fontSize(14)
            .fontColor(this.isError ? $r('app.color.error') : $r('app.color.success'))
            .width('100%')
            .textAlign(TextAlign.Center);
        }
        this.helpText();
      }
      .width('100%')
      .padding($r('app.float.page_padding'));
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off);
  }

  @Builder
  currentAccountCard() {
    Column({ space: 6 }) {
      Text('当前账号')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      Text(AccountManager.activeDisplayName().length > 0 ? AccountManager.activeDisplayName() : '未配置')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%');
      Text(this.activeSummary())
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  /** SoNovel 全局服务地址（不随账号切换，与账号列表分开呈现以区分作用域）。 */
  @Builder
  sonovelCard() {
    Column({ space: 8 }) {
      Text('SoNovel 服务')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      Text('独立第三方聚合书源服务，地址为全局设置，不随账号切换。留空表示不使用。')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
      TextInput({ placeholder: 'SoNovel 服务地址，如 http://192.168.1.10:8080', text: this.sonovelUrl })
        .height(44)
        .borderRadius(8)
        .backgroundColor($r('app.color.page_background'))
        .onChange((value: string) => this.sonovelUrl = value);
      PrimaryButton({
        label: '保存 SoNovel 地址',
        fullWidth: false,
        onTap: () => this.saveSoNovel(),
      });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  accountListCard() {
    Column() {
      if (this.accounts.length === 0) {
        Text('暂无账号')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding($r('app.float.page_padding'));
      } else {
        ForEach(this.accounts, (record: AccountRecord) => {
          this.accountRow(record);
        }, (record: AccountRecord) => `${record.id}-${record.url}-${record.username}-${AccountStore.isActive(record.id)}`);
      }
    }
    .width('100%')
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  accountRow(record: AccountRecord) {
    Column({ space: 8 }) {
      Row() {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text(AccountManager.displayNameOf(record))
              .fontSize(16)
              .fontColor($r('app.color.text_primary'));
            if (AccountStore.isActive(record.id)) {
              Text('当前')
                .fontSize(11)
                .fontColor($r('app.color.on_brand'))
                .backgroundColor($r('app.color.brand_primary'))
                .borderRadius(9)
                .padding({ left: 6, right: 6, top: 1, bottom: 1 });
            }
          }
          Text(`${this.serverKindLabel(record.serverKind)} · ${accountHost(record.url)}`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'));
          if (record.username.length > 0) {
            Text(record.username)
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'));
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
      }
      .width('100%');

      Row({ space: 16 }) {
        if (!AccountStore.isActive(record.id)) {
          Text('切换')
            .fontSize(14)
            .fontColor($r('app.color.brand_primary'))
            .onClick(() => {
              void this.switchTo(record.id, '已切换账号');
            });
        }
        Text('编辑')
          .fontSize(14)
          .fontColor($r('app.color.brand_primary'))
          .onClick(() => this.openEditForm(record));
        if (this.accounts.length > 1) {
          Text('删除')
            .fontSize(14)
            .fontColor($r('app.color.error'))
            .onClick(() => this.confirmDelete(record));
        }
        Blank();
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'));
  }

  @Builder
  formCard() {
    Column({ space: 12 }) {
      Text(this.editingId.length > 0 ? '编辑账号' : '新增账号')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%');

      Select(this.serverOptions)
        .selected(this.formServerIndex())
        .value(this.serverKindLabel(this.formServerKind))
        .width('100%')
        .onSelect((index: number) => {
          this.formServerKind = index === 1 ? ServerKind.TALEBOOK : ServerKind.MYBOOKS;
        });

      TextInput({ placeholder: '服务器地址，如 https://books.example.com', text: this.formUrl })
        .height(44)
        .borderRadius(8)
        .backgroundColor($r('app.color.page_background'))
        .onChange((value: string) => this.formUrl = value);

      TextInput({ placeholder: '用户名', text: this.formUsername })
        .height(44)
        .borderRadius(8)
        .backgroundColor($r('app.color.page_background'))
        .onChange((value: string) => this.formUsername = value);

      TextInput({
        placeholder: this.editingId.length > 0 ? '密码（留空表示不修改）' : '密码（用于自动登录）',
        text: this.formPassword,
      })
        .type(InputType.Password)
        .height(44)
        .borderRadius(8)
        .backgroundColor($r('app.color.page_background'))
        .onChange((value: string) => this.formPassword = value);

      TextInput({ placeholder: '账号备注名（可选）', text: this.formName })
        .height(44)
        .borderRadius(8)
        .backgroundColor($r('app.color.page_background'))
        .onChange((value: string) => this.formName = value);

      Row() {
        Column({ space: 4 }) {
          Text('跳过 SSL 验证')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'));
          Text('自签名或内网证书时使用，存在安全风险')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'));
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);

        Toggle({ type: ToggleType.Switch, isOn: this.formAllowInsecureSsl })
          .onChange((value: boolean) => this.formAllowInsecureSsl = value);
      }
      .width('100%');

      Row({ space: 10 }) {
        SecondaryButton({
          label: '取消',
          fullWidth: false,
          onTap: () => this.closeForm(),
        })
          .layoutWeight(1);
        PrimaryButton({
          label: this.busy ? '保存中…' : (this.editingId.length > 0 ? '保存并应用' : '保存并切换'),
          buttonEnabled: !this.busy,
          onTap: () => {
            void this.saveForm();
          },
        })
          .layoutWeight(2);
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  helpText() {
    Column({ space: 4 }) {
      Text('每个账号可指向不同服务器，也可指向同一服务器的不同用户。')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
      Text('切换账号后：登录状态、下载书籍、阅读历史与书签都会切到该账号自己的数据，界面会重新加载。')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }
}
