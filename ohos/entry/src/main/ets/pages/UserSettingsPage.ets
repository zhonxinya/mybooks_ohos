import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  PageScaffold, LoadingState, EmptyState, SettingCell, PrimaryButton, SecondaryButton,
  SectionTitle, AuthImage,
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import {
  TalebookApi, AvatarUploadResponse, UserUpdatePayload, VipInfoResponse,
} from '../services/TalebookApi';
import { BookUploadService } from '../services/BookUploadService';

@Entry
@Component
struct UserSettingsPage {
  @State loading: boolean = true;
  @State loadError: string = '';
  @State nickname: string = '';
  @State kindleEmail: string = '';
  @State oldPassword: string = '';
  @State newPassword: string = '';
  @State confirmPassword: string = '';
  @State showHomeRecommendations: boolean = true;
  @State allowSendingMail: boolean = true;
  @State shareAnnotations: boolean = true;
  @State showOtherAnnotations: boolean = false;
  @State saving: boolean = false;
  @State avatarUrl: string = '';
  @State uploadingAvatar: boolean = false;
  @State podcastToken: string = '';
  @State vipSummary: string = '';

  aboutToAppear(): void {
    void this.loadProfile();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private async loadProfile(): Promise<void> {
    this.loading = true;
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.loadError = '请先配置 Talebook 服务器';
        return;
      }
      if (TalebookService.hasAuthCredentials()) {
        await TalebookService.ensureAuthenticated();
      }
      const saved = TalebookService.getSavedUserProfile();
      if (saved === null) {
        this.loadError = '请先登录';
        return;
      }
      this.nickname = String(saved['nickname'] ?? saved['name'] ?? '');
      this.avatarUrl = TalebookService.resolveCoverUrl(String(saved['avatar'] ?? ''));
      this.podcastToken = String(saved['podcast_token'] ?? '');
      const extra = (saved['extra'] as Record<string, Object> | undefined) ?? {};
      this.kindleEmail = String(extra['kindle_email'] ?? '');
      this.allowSendingMail = extra['allow_sending_mail'] !== undefined ?
        Boolean(extra['allow_sending_mail']) : true;
      this.shareAnnotations = extra['share_annotations'] !== undefined ?
        Boolean(extra['share_annotations']) : true;
      this.showOtherAnnotations = extra['show_other_annotations'] !== undefined ?
        Boolean(extra['show_other_annotations']) : false;
      this.showHomeRecommendations = saved['show_home_recommendations'] !== undefined ?
        Boolean(saved['show_home_recommendations']) : true;
      void this.refreshVip();
    } finally {
      this.loading = false;
    }
  }

  private async refreshVip(): Promise<void> {
    if (!ServerRegistry.supports(ServerFeature.USER_VIP)) {
      this.vipSummary = '';
      return;
    }
    try {
      const rsp: VipInfoResponse = await TalebookApi.getVipInfo();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.vipSummary = '';
        return;
      }
      const quota = rsp.vipquota !== undefined ? String(rsp.vipquota) : '-';
      const expire = rsp.vip_expire !== undefined && rsp.vip_expire.length > 0 ? rsp.vip_expire : '无';
      this.vipSummary = `配额 ${quota} · 到期 ${expire}`;
    } catch (_e) {
      this.vipSummary = '';
    }
  }

  private generatePodcastToken(): void {
    let hex = '';
    for (let i = 0; i < 32; i++) {
      const b = Math.floor(Math.random() * 256);
      const h = b.toString(16);
      hex += h.length < 2 ? `0${h}` : h;
    }
    this.podcastToken = hex;
    this.toast('已生成新 Token，请保存设置后生效');
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private copyPodcastToken(): void {
    if (this.podcastToken.length === 0) {
      this.toast('暂无 Token');
      return;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.podcastToken);
    pasteboard.getSystemPasteboard().setData(data);
    this.toast('已复制');
  }

  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    const payload: UserUpdatePayload = {};
    payload.nickname = this.nickname.trim();
    payload.kindle_email = this.kindleEmail.trim();
    payload.show_home_recommendations = this.showHomeRecommendations;
    payload.allow_sending_mail = this.allowSendingMail;
    payload.share_annotations = this.shareAnnotations;
    payload.show_other_annotations = this.showOtherAnnotations;
    payload.podcast_token = this.podcastToken.trim();
    const p0 = this.oldPassword.trim();
    const p1 = this.newPassword.trim();
    const p2 = this.confirmPassword.trim();
    if (p0.length > 0 || p1.length > 0 || p2.length > 0) {
      if (p0.length === 0 || p1.length === 0 || p1 !== p2) {
        this.toast('请填写旧密码，且两次新密码输入一致');
        return;
      }
      payload.password0 = p0;
      payload.password1 = p1;
      payload.password2 = p2;
    }
    this.saving = true;
    try {
      const rsp = await TalebookApi.updateUserSettings(payload);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '设置已保存');
      this.oldPassword = '';
      this.newPassword = '';
      this.confirmPassword = '';
      TalebookService.refreshUserProfile();
    } catch (error) {
      this.toast(`保存失败：${error}`);
    } finally {
      this.saving = false;
    }
  }

  private async pickAndUploadAvatar(): Promise<void> {
    if (this.uploadingAvatar) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const file = await BookUploadService.pickAvatarImage(context);
      if (file === null) {
        return;
      }
      this.uploadingAvatar = true;
      const authed = await TalebookService.ensureAuthenticated();
      if (!authed) {
        this.toast('登录已失效，请重新登录后再上传');
        return;
      }
      this.toast('正在上传头像…');
      const rsp: AvatarUploadResponse = await TalebookApi.uploadAvatar(file.localPath, file.name);
      BookUploadService.removeStagedFile(file.localPath);
      if (rsp.err === 'ok') {
        this.toast('头像已更新');
        TalebookService.refreshUserProfile();
        await this.loadProfile();
      } else {
        const message = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg :
          (rsp.err !== undefined ? rsp.err : '上传失败');
        this.toast(message);
      }
    } catch (error) {
      this.toast(`头像上传失败：${error}`);
    } finally {
      this.uploadingAvatar = false;
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '个人设置',
        showBack: true,
        content: () => {
          this.settingsContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  settingsContent() {
    if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      EmptyState({ message: this.loadError });
    } else {
      Scroll() {
        Column({ space: 12 }) {
          Column({ space: 10 }) {
            SectionTitle({ title: '基本资料' });
            Row({ space: 14 }) {
              if (this.avatarUrl.length > 0) {
                Column() {
                  AuthImage({
                    url: this.avatarUrl,
                    imageWidth: 56,
                    imageHeight: 56,
                  });
                }
                .borderRadius(28)
                .clip(true);
              } else {
                Column() {
                  SymbolGlyph($r('sys.symbol.person'))
                    .fontSize(28)
                    .fontColor([$r('app.color.on_brand')]);
                }
                .width(56)
                .height(56)
                .borderRadius(28)
                .backgroundColor($r('app.color.brand_primary'))
                .justifyContent(FlexAlign.Center);
              }
              // 更换头像走 mybooks 专有的 `POST /api/user/avatar`（talebook 上游无此端点）
              if (ServerRegistry.supports(ServerFeature.USER_AVATAR)) {
                SecondaryButton({
                  label: this.uploadingAvatar ? '上传中…' : '更换头像',
                  fullWidth: false,
                  compact: true,
                  buttonEnabled: !this.uploadingAvatar,
                  onTap: () => {
                    void this.pickAndUploadAvatar();
                  },
                });
              }
            }
            .width('100%');
            Row({ space: 10 }) {
              Text('昵称')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .width(80);
              TextInput({ text: this.nickname, placeholder: '至少 3 个字符' })
                .layoutWeight(1)
                .height(40)
                .onChange((value: string) => {
                  this.nickname = value;
                });
            }
            .width('100%');
            Row({ space: 10 }) {
              Text('Kindle')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .width(80);
              TextInput({ text: this.kindleEmail, placeholder: 'Kindle 推送邮箱' })
                .layoutWeight(1)
                .height(40)
                .onChange((value: string) => {
                  this.kindleEmail = value;
                });
            }
            .width('100%');
          }
          .width('100%')
          .padding($r('app.float.card_padding'))
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'))
          .alignItems(HorizontalAlign.Start);

          Column({ space: 8 }) {
            SectionTitle({ title: '会员与订阅' });
            if (this.vipSummary.length > 0) {
              Text(this.vipSummary)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'));
            } else {
              Text('VIP 信息暂不可用')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'));
            }
            Text('Podcast Token')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'));
            Text(this.podcastToken.length > 0 ? this.podcastToken : '未设置')
              .fontSize(12)
              .fontColor($r('app.color.text_primary'));
            Row({ space: 8 }) {
              SecondaryButton({
                label: '重新生成',
                compact: true,
                fullWidth: false,
                onTap: () => this.generatePodcastToken(),
              });
              SecondaryButton({
                label: '复制',
                compact: true,
                fullWidth: false,
                onTap: () => this.copyPodcastToken(),
              });
            }
          }
          .width('100%')
          .padding($r('app.float.card_padding'))
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'))
          .alignItems(HorizontalAlign.Start);

          Column({ space: 4 }) {
            SettingCell({
              title: '首页显示推荐',
              subtitle: '关闭后首页不展示其他读者的推荐',
              showToggle: true,
              toggleOn: this.showHomeRecommendations,
              onToggle: (value: boolean) => {
                this.showHomeRecommendations = value;
              },
            });
            Divider().color($r('app.color.divider')).strokeWidth(0.5);
            SettingCell({
              title: '允许推送邮件',
              showToggle: true,
              toggleOn: this.allowSendingMail,
              onToggle: (value: boolean) => {
                this.allowSendingMail = value;
              },
            });
            Divider().color($r('app.color.divider')).strokeWidth(0.5);
            SettingCell({
              title: '分享我的批注',
              subtitle: '允许其他读者在共读中看到我的划线与笔记',
              showToggle: true,
              toggleOn: this.shareAnnotations,
              onToggle: (value: boolean) => {
                this.shareAnnotations = value;
              },
            });
            Divider().color($r('app.color.divider')).strokeWidth(0.5);
            SettingCell({
              title: '查看他人批注',
              showToggle: true,
              toggleOn: this.showOtherAnnotations,
              onToggle: (value: boolean) => {
                this.showOtherAnnotations = value;
              },
            });
          }
          .width('100%')
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          Column({ space: 10 }) {
            SectionTitle({ title: '修改密码' });
            TextInput({ text: this.oldPassword, placeholder: '旧密码' })
              .type(InputType.Password)
              .width('100%')
              .height(40)
              .onChange((value: string) => {
                this.oldPassword = value;
              });
            TextInput({ text: this.newPassword, placeholder: '新密码（6-20 位）' })
              .type(InputType.Password)
              .width('100%')
              .height(40)
              .onChange((value: string) => {
                this.newPassword = value;
              });
            TextInput({ text: this.confirmPassword, placeholder: '确认新密码' })
              .type(InputType.Password)
              .width('100%')
              .height(40)
              .onChange((value: string) => {
                this.confirmPassword = value;
              });
          }
          .width('100%')
          .padding($r('app.float.card_padding'))
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'))
          .alignItems(HorizontalAlign.Start);

          PrimaryButton({
            label: '保存设置',
            buttonEnabled: !this.saving,
            onTap: () => {
              void this.save();
            },
          });
        }
        .padding($r('app.float.page_padding'));
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off);
    }
  }
}
