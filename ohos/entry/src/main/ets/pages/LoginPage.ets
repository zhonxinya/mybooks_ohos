import { router } from '@kit.ArkUI';
import { PageScaffold, PrimaryButton, SecondaryButton, SettingCell, TextButton } from '../components';
import { TalebookService } from '../services/TalebookService';
import {
  TalebookApi, ApiMessageResult, AccessStatusResponse, WhoAmIResponse, apiErrorMessage
} from '../services/TalebookApi';

const MODE_LOGIN: string = 'login';
const MODE_REGISTER: string = 'register';
const MODE_RESET: string = 'reset';
const MODE_ACCESS: string = 'access';

@Entry
@Component
struct LoginPage {
  @State mode: string = MODE_LOGIN;
  @State serverUrl: string = '';
  @State username: string = '';
  @State password: string = '';
  @State nickname: string = '';
  @State email: string = '';
  @State inviteCode: string = '';
  @State allowInsecureSsl: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;
  @State busy: boolean = false;
  @State accessWelcome: string = '';
  @State whoAmIHint: string = '';
  @State needActivate: boolean = false;

  aboutToAppear(): void {
    this.serverUrl = TalebookService.secureGet('talebook_url');
    const creds = TalebookService.getLoginCredentials();
    this.username = creds.username;
    this.password = creds.password;
    this.allowInsecureSsl = TalebookService.prefGet('allow_insecure_ssl', 'false') === 'true';
    if (TalebookService.hasAuthCredentials()) {
      void this.tryAutoLogin();
    } else if (this.serverUrl.trim().length > 0) {
      void this.probeAccessQuiet();
    }
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private setMode(next: string): void {
    if (this.busy || this.mode === next) {
      return;
    }
    this.mode = next;
    this.message = '';
    this.isError = false;
    if (next === MODE_ACCESS) {
      void this.probeAccessQuiet();
    }
  }

  private async tryAutoLogin(): Promise<void> {
    this.busy = true;
    this.message = '';
    try {
      TalebookService.applyLocalConfig();
      const restored = await TalebookService.ensureAuthenticated();
      if (restored) {
        await this.refreshWhoAmI(false);
        router.back();
      }
    } catch (error) {
      this.message = `${error}`;
      this.isError = true;
    } finally {
      this.busy = false;
    }
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

  private applyServerConfig(): boolean {
    const server = this.normalizeServerUrl(this.serverUrl);
    if (server.length === 0) {
      this.message = '请填写服务器地址';
      this.isError = true;
      return false;
    }
    TalebookService.setBaseUrl('talebook', server);
    TalebookService.secureSet('talebook_url', server);
    TalebookService.prefSet('allow_insecure_ssl', this.allowInsecureSsl ? 'true' : 'false');
    TalebookService.applyLocalConfig();
    return true;
  }

  private handlePrimary(): void {
    if (this.busy) {
      return;
    }
    if (this.mode === MODE_LOGIN) {
      this.handleLogin();
      return;
    }
    if (this.mode === MODE_REGISTER) {
      void this.handleRegister();
      return;
    }
    if (this.mode === MODE_RESET) {
      void this.handleReset();
      return;
    }
    void this.handleAccessSubmit();
  }

  private handleLogin(): void {
    if (!this.applyServerConfig()) {
      return;
    }
    const user = this.username.trim();
    const pass = this.password.trim();
    if (user.length === 0 || pass.length === 0) {
      this.message = '请填写用户名和密码';
      this.isError = true;
      return;
    }
    void this.performLogin(user, pass);
  }

  private async performLogin(user: string, pass: string): Promise<void> {
    this.busy = true;
    this.message = '';
    try {
      TalebookService.saveLoginCredentials(user, pass);
      const envelope = await TalebookService.signInAsync(user, pass);
      if (TalebookService.isApiSuccess(envelope)) {
        await this.refreshWhoAmI(true);
        this.toast('登录成功');
        router.back();
      } else {
        this.message = envelope.error.length > 0 ? envelope.error : '登录失败';
        this.isError = true;
      }
    } catch (error) {
      this.message = `${error}`;
      this.isError = true;
    } finally {
      this.busy = false;
    }
  }

  private async handleRegister(): Promise<void> {
    if (!this.applyServerConfig()) {
      return;
    }
    const user = this.username.trim();
    const nick = this.nickname.trim().length > 0 ? this.nickname.trim() : user;
    const mail = this.email.trim();
    const pass = this.password.trim();
    if (user.length === 0 || mail.length === 0 || pass.length === 0) {
      this.message = '请填写用户名、邮箱和密码';
      this.isError = true;
      return;
    }
    this.busy = true;
    this.message = '';
    try {
      const rsp: ApiMessageResult = await TalebookApi.signUp(user, nick, mail, pass);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.message = apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '注册失败';
        this.isError = true;
        return;
      }
      this.isError = false;
      this.message = rsp.msg !== undefined && rsp.msg.length > 0
        ? rsp.msg
        : '注册成功，请查收激活邮件后登录';
      this.mode = MODE_LOGIN;
      TalebookService.saveLoginCredentials(user, pass);
    } catch (e) {
      this.message = `${e}`;
      this.isError = true;
    } finally {
      this.busy = false;
    }
  }

  private async handleReset(): Promise<void> {
    if (!this.applyServerConfig()) {
      return;
    }
    const user = this.username.trim();
    const mail = this.email.trim();
    if (user.length === 0 || mail.length === 0) {
      this.message = '请填写用户名和邮箱';
      this.isError = true;
      return;
    }
    this.busy = true;
    this.message = '';
    try {
      const rsp: ApiMessageResult = await TalebookApi.resetPassword(user, mail);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.message = apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '重置失败';
        this.isError = true;
        return;
      }
      this.isError = false;
      this.message = rsp.msg !== undefined && rsp.msg.length > 0
        ? rsp.msg
        : '已发送重置邮件，请查收邮箱';
    } catch (e) {
      this.message = `${e}`;
      this.isError = true;
    } finally {
      this.busy = false;
    }
  }

  private async probeAccessQuiet(): Promise<void> {
    if (this.normalizeServerUrl(this.serverUrl).length === 0) {
      return;
    }
    if (!this.applyServerConfig()) {
      return;
    }
    try {
      const rsp: AccessStatusResponse = await TalebookApi.getAccessStatus();
      // free = 无需邀请；ok = 需要邀请码
      if (rsp.err === 'free') {
        this.accessWelcome = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '当前无需邀请码';
      } else {
        this.accessWelcome = rsp.welcome !== undefined && rsp.welcome.length > 0
          ? rsp.welcome
          : (rsp.msg !== undefined ? rsp.msg : '请输入邀请码');
      }
      if (rsp.version !== undefined && rsp.version.length > 0) {
        this.accessWelcome = `${this.accessWelcome}\n版本 ${rsp.version}`;
      }
    } catch (e) {
      this.accessWelcome = `无法查询访问状态：${e}`;
    }
  }

  private async handleAccessSubmit(): Promise<void> {
    if (!this.applyServerConfig()) {
      return;
    }
    const code = this.inviteCode.trim();
    if (code.length === 0) {
      this.message = '请填写邀请码';
      this.isError = true;
      return;
    }
    this.busy = true;
    this.message = '';
    try {
      const rsp: ApiMessageResult = await TalebookApi.submitAccessCode(code);
      if (rsp.err !== undefined && rsp.err !== 'ok' && rsp.err !== 'free') {
        this.message = apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '邀请码无效';
        this.isError = true;
        return;
      }
      this.isError = false;
      this.message = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '邀请码已接受';
      await this.probeAccessQuiet();
    } catch (e) {
      this.message = `${e}`;
      this.isError = true;
    } finally {
      this.busy = false;
    }
  }

  private async refreshWhoAmI(showToast: boolean): Promise<void> {
    try {
      const rsp: WhoAmIResponse = await TalebookApi.whoAmI();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.whoAmIHint = apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '未登录';
        this.needActivate = false;
        if (showToast) {
          this.toast(this.whoAmIHint);
        }
        return;
      }
      const name = rsp.username !== undefined && rsp.username.length > 0
        ? rsp.username
        : (rsp.is_guest ? '访客' : `用户 ${rsp.userId ?? ''}`);
      const active = rsp.isActive !== false;
      this.needActivate = !active && !(rsp.is_guest === true);
      const bits: string[] = [name];
      if (rsp.is_guest) {
        bits.push('访客');
      }
      if (rsp.canRead === false) {
        bits.push('不可阅读');
      }
      if (!active) {
        bits.push('未激活');
      }
      this.whoAmIHint = bits.join(' · ');
      if (showToast) {
        this.toast(this.whoAmIHint);
      }
    } catch (e) {
      this.whoAmIHint = `${e}`;
      this.needActivate = false;
    }
  }

  private async handleSendActive(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const rsp: ApiMessageResult = await TalebookApi.sendActiveEmail();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '发送失败');
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已发送激活邮件');
    } catch (e) {
      this.toast(`发送失败：${e}`);
    } finally {
      this.busy = false;
    }
  }

  private primaryLabel(): string {
    if (this.busy) {
      if (this.mode === MODE_LOGIN) {
        return '登录中…';
      }
      if (this.mode === MODE_REGISTER) {
        return '注册中…';
      }
      if (this.mode === MODE_RESET) {
        return '提交中…';
      }
      return '提交中…';
    }
    if (this.mode === MODE_LOGIN) {
      return '登录';
    }
    if (this.mode === MODE_REGISTER) {
      return '注册';
    }
    if (this.mode === MODE_RESET) {
      return '重置密码';
    }
    return '提交邀请码';
  }

  build() {
    Column() {
      PageScaffold({
        title: '登录',
        showBack: true,
        content: () => {
          this.loginContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  loginContent() {
    Column({ space: 20 }) {
      Column({ space: 8 }) {
        Text('Talebook')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.brand_primary'));
        Text('连接你的私人书库')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'));
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .margin({ top: 24, bottom: 8 });

      this.modeSwitcher();

      Column({ space: 16 }) {
        TextInput({ placeholder: '服务器地址', text: this.serverUrl })
          .height(44)
          .borderRadius(8)
          .backgroundColor($r('app.color.page_background'))
          .onChange((value: string) => this.serverUrl = value);

        if (this.mode === MODE_ACCESS) {
          if (this.accessWelcome.length > 0) {
            Text(this.accessWelcome)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%');
          }
          TextInput({ placeholder: '邀请码', text: this.inviteCode })
            .height(44)
            .borderRadius(8)
            .backgroundColor($r('app.color.page_background'))
            .onChange((value: string) => this.inviteCode = value);
        } else {
          TextInput({ placeholder: '用户名', text: this.username })
            .height(44)
            .borderRadius(8)
            .backgroundColor($r('app.color.page_background'))
            .onChange((value: string) => this.username = value);

          if (this.mode === MODE_REGISTER) {
            TextInput({ placeholder: '昵称（可选）', text: this.nickname })
              .height(44)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((value: string) => this.nickname = value);
          }

          if (this.mode === MODE_REGISTER || this.mode === MODE_RESET) {
            TextInput({ placeholder: '邮箱', text: this.email })
              .height(44)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((value: string) => this.email = value);
          }

          if (this.mode === MODE_LOGIN || this.mode === MODE_REGISTER) {
            TextInput({ placeholder: '密码', text: this.password })
              .type(InputType.Password)
              .height(44)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((value: string) => this.password = value);
          }
        }
      }
      .width('100%')
      .padding(16)
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));

      Column() {
        SettingCell({
          title: '忽略 SSL 证书',
          subtitle: '自签名或无效证书时使用，存在安全风险',
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

      if (this.whoAmIHint.length > 0) {
        Text(`当前：${this.whoAmIHint}`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center);
      }

      PrimaryButton({
        label: this.primaryLabel(),
        buttonEnabled: !this.busy,
        onTap: () => this.handlePrimary(),
      });

      if (this.mode === MODE_LOGIN) {
        SecondaryButton({
          label: '查看当前用户 (whoAmI)',
          buttonEnabled: !this.busy,
          onTap: () => {
            if (!this.applyServerConfig()) {
              return;
            }
            void this.refreshWhoAmI(true);
          },
        });
      }

      if (this.needActivate) {
        SecondaryButton({
          label: '重发激活邮件',
          buttonEnabled: !this.busy,
          onTap: () => {
            void this.handleSendActive();
          },
        });
      }
    }
    .padding($r('app.float.page_padding'));
  }

  @Builder
  modeSwitcher() {
    Row({ space: 12 }) {
      TextButton({
        label: '登录',
        onTap: () => this.setMode(MODE_LOGIN),
      });
      TextButton({
        label: '注册',
        onTap: () => this.setMode(MODE_REGISTER),
      });
      TextButton({
        label: '重置密码',
        onTap: () => this.setMode(MODE_RESET),
      });
      TextButton({
        label: '邀请码',
        onTap: () => this.setMode(MODE_ACCESS),
      });
    }
    .width('100%')
    .justifyContent(FlexAlign.Center);
  }
}
