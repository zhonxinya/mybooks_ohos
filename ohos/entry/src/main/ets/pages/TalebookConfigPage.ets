import { PageScaffold, PrimaryButton, SettingCell } from '../components';
import { TalebookService } from '../services/TalebookService';
import { TalebookCoreService } from '../services/TalebookCoreService';

@Entry
@Component
struct TalebookConfigPage {
  @State url: string = '';
  @State username: string = '';
  @State password: string = '';
  @State allowInsecureSsl: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;
  @State busy: boolean = false;

  aboutToAppear(): void {
    this.url = TalebookService.secureGet('talebook_url');
    const creds = TalebookService.getLoginCredentials();
    this.username = creds.username;
    this.password = creds.password;
    this.allowInsecureSsl = TalebookService.prefGet('allow_insecure_ssl', 'false') === 'true';
  }

  private setAllowInsecureSsl(value: boolean): void {
    this.allowInsecureSsl = value;
    TalebookService.prefSet('allow_insecure_ssl', value ? 'true' : 'false');
  }

  private normalizeServerUrl(url: string): string {
    let normalized = url.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  private handleSave(): void {
    if (this.busy) {
      return;
    }
    const server = this.normalizeServerUrl(this.url);
    const user = this.username.trim();
    const pass = this.password.trim();
    if (server.length === 0) {
      this.message = '请填写服务器地址';
      this.isError = true;
      return;
    }
    this.busy = true;
    this.message = '';
    try {
      TalebookService.prefSet('allow_insecure_ssl', this.allowInsecureSsl ? 'true' : 'false');
      TalebookService.setBaseUrl('talebook', server);
      TalebookService.secureSet('talebook_url', server);
      TalebookCoreService.syncBaseUrl('talebook', server);
      TalebookService.saveLoginCredentials(user, pass);
      this.message = '已保存';
      this.isError = false;
      this.getUIContext().getPromptAction().showToast({ message: '已保存' });
      TalebookService.invalidateSession();
      void TalebookService.ensureAuthenticated();
    } catch (error) {
      this.message = `${error}`;
      this.isError = true;
      this.getUIContext().getPromptAction().showToast({ message: '保存失败' });
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: 'Talebook 配置',
        showBack: true,
        content: () => {
          this.configContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  configContent() {
    Column({ space: 16 }) {
      Column({ space: 12 }) {
        TextInput({ placeholder: 'https://your-talebook-server', text: this.url })
          .height(44)
          .borderRadius(8)
          .backgroundColor($r('app.color.page_background'))
          .onChange((value: string) => this.url = value);
        TextInput({ placeholder: '用户名', text: this.username })
          .height(44)
          .borderRadius(8)
          .backgroundColor($r('app.color.page_background'))
          .onChange((value: string) => this.username = value);
        TextInput({ placeholder: '密码', text: this.password })
          .type(InputType.Password)
          .height(44)
          .borderRadius(8)
          .backgroundColor($r('app.color.page_background'))
          .onChange((value: string) => this.password = value);
      }
      .width('100%')
      .padding($r('app.float.page_padding'))
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));

      Column() {
        SettingCell({
          title: '跳过 SSL 验证',
          subtitle: '自签名或内网证书时使用，存在安全风险',
          showToggle: true,
          toggleOn: this.allowInsecureSsl,
          onToggle: (value: boolean) => this.setAllowInsecureSsl(value),
        });
      }
      .width('100%')
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));

      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(14)
          .fontColor(this.isError ? $r('app.color.error') : $r('app.color.success'))
          .width('100%')
          .textAlign(TextAlign.Center);
      }

      PrimaryButton({
        label: this.busy ? '保存中...' : '保存',
        buttonEnabled: !this.busy,
        onTap: () => this.handleSave(),
      });
    }
    .padding($r('app.float.page_padding'));
  }
}
