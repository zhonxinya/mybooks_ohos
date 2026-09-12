import { common, Want } from '@kit.AbilityKit';
import { PageScaffold, LoadingState, PrimaryButton, SecondaryButton, TextButton } from '../components';
import { ReleaseInfo, UpdateCheckResult, UpdateService } from '../services/UpdateService';
import { ErrorFormat } from '../utils/ErrorFormat';

/**
 * 客户端更新检查页：展示当前版本、GitHub 最新 release 版本与升级内容，并提供下载 / 发布页入口。
 *
 * 数据源：UpdateService（GitHub `releases/latest`）。进入页面即强制刷新一次，忽略缓存。
 */
@Entry
@Component
struct UpdatePage {
  @State loading: boolean = true;
  @State error: string = '';
  @State currentVersion: string = '';
  @State release: ReleaseInfo | null = null;
  @State hasUpdate: boolean = false;
  /** 用户是否已忽略本次版本（影响「忽略此版本」按钮的显隐，必须用状态而非直读偏好） */
  @State ignored: boolean = false;

  aboutToAppear(): void {
    void this.check();
  }

  private async check(): Promise<void> {
    this.loading = true;
    this.error = '';
    try {
      const result: UpdateCheckResult = await UpdateService.check(true);
      this.currentVersion = result.currentVersion;
      if (!result.ok) {
        this.release = null;
        this.hasUpdate = false;
        this.ignored = false;
        this.error = result.error.length > 0 ? result.error : '检查更新失败';
        return;
      }
      const release: ReleaseInfo | null = result.release;
      this.release = release;
      this.hasUpdate = result.hasUpdate;
      this.ignored = release !== null && UpdateService.isSkipped(release.tag);
    } catch (error) {
      this.error = ErrorFormat.message(error as Object);
    } finally {
      this.loading = false;
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  /** 打开外部链接；链接可能来自 GitHub 响应，仅允许 http/https。 */
  private openUrl(url: string): void {
    if (url.length === 0) {
      this.toast('链接不可用');
      return;
    }
    if (!(url.startsWith('http://') || url.startsWith('https://'))) {
      this.toast('链接协议不受支持');
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: url,
    };
    context.startAbility(want).catch(() => {
      this.toast('无法打开链接');
    });
  }

  private ignoreCurrent(): void {
    const release: ReleaseInfo | null = this.release;
    if (release === null || release.tag.length === 0) {
      return;
    }
    UpdateService.skipVersion(release.tag);
    this.ignored = true;
    this.toast(`已忽略 ${release.tag} 的升级提示`);
  }

  // ---- 展示辅助（统一在此处做 null 收敛，@Builder 内不再直接判空） ----

  private currentVersionLabel(): string {
    return this.currentVersion.length > 0 ? `v${this.currentVersion}` : '未知';
  }

  private latestVersionLabel(): string {
    const release: ReleaseInfo | null = this.release;
    return release !== null ? `v${release.version}` : '';
  }

  private releaseTagLabel(): string {
    const release: ReleaseInfo | null = this.release;
    return release !== null ? release.tag : '';
  }

  /** 「发布于 … · 安装包 …（… MB）」一行元信息。 */
  private releaseMetaLabel(): string {
    const release: ReleaseInfo | null = this.release;
    if (release === null) {
      return '';
    }
    const bits: string[] = [];
    const date: string = UpdateService.formatDate(release.publishedAt);
    if (date.length > 0) {
      bits.push(`发布于 ${date}`);
    }
    const size: string = UpdateService.formatSize(release.hapSize);
    if (release.hapName.length > 0) {
      bits.push(size.length > 0 ? `安装包 ${release.hapName}（${size}）` : `安装包 ${release.hapName}`);
    }
    return bits.join(' · ');
  }

  private notesText(): string {
    const release: ReleaseInfo | null = this.release;
    if (release === null) {
      return '';
    }
    const body: string = release.body.trim();
    return body.length > 0 ? body : '本次发布未提供升级说明，可前往 GitHub 发布页查看。';
  }

  private downloadUrl(): string {
    const release: ReleaseInfo | null = this.release;
    if (release === null) {
      return '';
    }
    return release.hapUrl.length > 0 ? release.hapUrl : release.htmlUrl;
  }

  private releasePageUrl(): string {
    const release: ReleaseInfo | null = this.release;
    return release !== null ? release.htmlUrl : '';
  }

  build() {
    Column() {
      PageScaffold({
        title: '检查更新',
        showBack: true,
        action: () => {
          this.refreshAction();
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
  refreshAction() {
    Text('重新检查')
      .fontSize(14)
      .fontColor($r('app.color.brand_primary'))
      .padding({ left: 8, right: 16 })
      .onClick(() => {
        if (!this.loading) {
          void this.check();
        }
      });
  }

  @Builder
  pageContent() {
    if (this.loading) {
      LoadingState({ hint: '正在检查更新…' });
    } else {
      Scroll() {
        Column({ space: 12 }) {
          this.currentCard();
          if (this.error.length > 0) {
            this.errorCard();
          } else if (this.hasUpdate) {
            this.updateCard();
            this.notesCard();
            this.actionCard();
          } else {
            this.latestCard();
          }
        }
        .width('100%')
        .padding($r('app.float.page_padding'));
      }
      .width('100%')
      .layoutWeight(1)
      // 内容不满一屏时避免 Scroll 垂直居中
      .align(Alignment.Top)
      .scrollBar(BarState.Auto);
    }
  }

  @Builder
  currentCard() {
    Column({ space: 6 }) {
      Text('当前版本')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      Text(this.currentVersionLabel())
        .fontSize(24)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%');
      Text('从 GitHub 获取最新发布版本')
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

  @Builder
  latestCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize(20)
          .fontColor([$r('app.color.success')]);
        Text('已是最新版本')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'));
      }
      .width('100%');

      Text(`${this.currentVersionLabel()} 已是 GitHub 上最新的正式发布版本。`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  errorCard() {
    Column({ space: 8 }) {
      Text('检查更新失败')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.error'))
        .width('100%');
      Text(this.error)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      Text('请确认设备可访问 GitHub；若提示访问频繁，稍后再试即可。')
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

  @Builder
  updateCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.arrow_down_circle'))
          .fontSize(20)
          .fontColor([$r('app.color.brand_primary')]);
        Text(`发现新版本 ${this.latestVersionLabel()}`)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
      }
      .width('100%');

      if (this.releaseMetaLabel().length > 0) {
        Text(this.releaseMetaLabel())
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
      }

      Text(`当前 ${this.currentVersionLabel()} → 最新 ${this.releaseTagLabel()}`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.brand_primary_light'));
  }

  @Builder
  notesCard() {
    Column({ space: 8 }) {
      Text('升级内容')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%');

      // 升级内容是 Markdown 原文，客户端不做渲染，限高滚动展示
      Scroll() {
        Text(this.notesText())
          .fontSize(12)
          .lineHeight(20)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
      }
      .height(240)
      .width('100%')
      .align(Alignment.Top)
      .padding(8)
      .borderRadius(8)
      .backgroundColor($r('app.color.page_background'));
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  actionCard() {
    Column({ space: 10 }) {
      PrimaryButton({
        label: '下载最新安装包',
        onTap: () => this.openUrl(this.downloadUrl()),
      });
      SecondaryButton({
        label: '打开发布页',
        onTap: () => this.openUrl(this.releasePageUrl()),
      });
      Text('发布附件为未签名 HAP，安装前需按仓库 README 完成签名。')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');

      if (!this.ignored) {
        Row() {
          TextButton({
            label: '忽略此版本',
            tone: 'brand',
            onTap: () => this.ignoreCurrent(),
          });
        }
        .width('100%')
        .justifyContent(FlexAlign.Center);
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }
}
