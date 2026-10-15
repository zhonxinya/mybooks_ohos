import { common } from '@kit.AbilityKit';
import { PageScaffold, LoadingState, PrimaryButton, SecondaryButton, TextButton } from '../components';
import { ReleaseInfo, UpdateCheckResult, UpdateService } from '../services/UpdateService';
import { ApkDownloadProgress, ApkUpdater } from '../services/ApkUpdater';
import { ExternalLinkOpener } from '../services/ExternalLinkOpener';
import { ErrorFormat } from '../utils/ErrorFormat';

/**
 * 客户端更新检查页：展示当前版本、GitHub 最新 release 版本与升级内容，并提供下载 / 发布页入口。
 *
 * 数据源：UpdateService（GitHub `releases/latest`）。进入页面即强制刷新一次，忽略缓存。
 * Android 走应用内升级（下载 APK 后交系统安装器）；HarmonyOS 仍为下载 HAP 自行签名安装。
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
  /** Android 应用内升级：是否正在下载安装包 */
  @State downloading: boolean = false;
  /** 下载百分比；-1 表示服务端未给出总大小（进度条走不确定态） */
  @State downloadPercent: number = -1;
  /** 已下载 / 总大小文案，如「12.3 MB / 29.4 MB」 */
  @State downloadSizeLabel: string = '';

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

  /** 打开外部链接（http/https）；跨端分派与协议校验见 `ExternalLinkOpener`。 */
  private openUrl(url: string): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ExternalLinkOpener.open(context, url).then((error: string) => {
      if (error.length > 0) {
        this.toast(error);
      }
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

  /** 平台对应的安装包附件（Android 取 .apk，其余取 .hap）。 */
  private installAssetName(): string {
    const release: ReleaseInfo | null = this.release;
    if (release === null) {
      return '';
    }
    return ApkUpdater.supported() ? release.apkName : release.hapName;
  }

  private installAssetSize(): number {
    const release: ReleaseInfo | null = this.release;
    if (release === null) {
      return 0;
    }
    return ApkUpdater.supported() ? release.apkSize : release.hapSize;
  }

  private installAssetUrl(): string {
    const release: ReleaseInfo | null = this.release;
    if (release === null) {
      return '';
    }
    return ApkUpdater.supported() ? release.apkUrl : release.hapUrl;
  }

  /** 该平台是否具备应用内安装能力（Android 且 release 带 APK 附件）。 */
  private canInstallInApp(): boolean {
    return ApkUpdater.supported() && this.installAssetUrl().length > 0;
  }

  /** 「发布于 … · 安装包 …（… MB）」一行元信息。 */
  private releaseMetaLabel(): string {
    const bits: string[] = [];
    const release: ReleaseInfo | null = this.release;
    if (release === null) {
      return '';
    }
    const date: string = UpdateService.formatDate(release.publishedAt);
    if (date.length > 0) {
      bits.push(`发布于 ${date}`);
    }
    const assetName: string = this.installAssetName();
    const size: string = UpdateService.formatSize(this.installAssetSize());
    if (assetName.length > 0) {
      bits.push(size.length > 0 ? `安装包 ${assetName}（${size}）` : `安装包 ${assetName}`);
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
    const url: string = this.installAssetUrl();
    if (url.length > 0) {
      return url;
    }
    const release: ReleaseInfo | null = this.release;
    return release !== null ? release.htmlUrl : '';
  }

  private releasePageUrl(): string {
    const release: ReleaseInfo | null = this.release;
    return release !== null ? release.htmlUrl : '';
  }

  /** 下载进度文案；总大小未知时只报已下载量。 */
  private downloadProgressLabel(): string {
    const size: string = this.downloadSizeLabel;
    if (this.downloadPercent < 0) {
      return size.length > 0 ? `正在下载 ${size}` : '正在下载安装包…';
    }
    return size.length > 0
      ? `正在下载 ${this.downloadPercent}%（${size}）`
      : `正在下载 ${this.downloadPercent}%`;
  }

  /** 下载安装包并唤起系统安装器（仅 Android）。 */
  private async downloadAndInstall(): Promise<void> {
    const release: ReleaseInfo | null = this.release;
    if (release === null || this.downloading) {
      return;
    }
    const url: string = this.installAssetUrl();
    if (url.length === 0) {
      this.toast('当前发布没有可安装的 APK 附件');
      return;
    }
    this.downloading = true;
    this.downloadPercent = -1;
    this.downloadSizeLabel = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const fileName: string = ApkUpdater.safeFileName(release.apkName,
        `mybooks-${release.version}-android.apk`);
      // 回调按块触发，逐块 setState 会让整页高频重建：按百分比（总大小未知时按 1MB）步进更新
      let lastPercent: number = -2;
      let lastReportedBytes: number = 0;
      await ApkUpdater.download(context, url, fileName, release.apkSize,
        (progress: ApkDownloadProgress) => {
          if (progress.total > 0) {
            const percent: number = Math.floor((progress.received / progress.total) * 100);
            if (percent === lastPercent) {
              return;
            }
            lastPercent = percent;
            this.downloadPercent = percent;
            this.downloadSizeLabel =
              `${UpdateService.formatSize(progress.received)} / ${UpdateService.formatSize(progress.total)}`;
            return;
          }
          if (lastReportedBytes > 0 && progress.received - lastReportedBytes < 1024 * 1024) {
            return;
          }
          lastReportedBytes = progress.received;
          this.downloadPercent = -1;
          this.downloadSizeLabel = UpdateService.formatSize(progress.received);
        });
      await ApkUpdater.install(fileName);
      this.downloading = false;
      this.toast('安装包已下载，请在系统安装界面确认安装');
    } catch (error) {
      this.downloading = false;
      this.toast(ErrorFormat.message(error as Object));
    }
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
      if (this.canInstallInApp()) {
        PrimaryButton({
          label: this.downloading ? '正在下载…' : '下载并安装',
          buttonEnabled: !this.downloading,
          onTap: () => {
            void this.downloadAndInstall();
          },
        });
        if (this.downloading) {
          this.downloadProgressBlock();
        }
        Text('下载完成后会唤起系统安装器；若提示“未知来源”，请按系统引导允许本应用安装应用。')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      } else {
        PrimaryButton({
          label: '下载最新安装包',
          onTap: () => this.openUrl(this.downloadUrl()),
        });
        Text('发布附件为未签名 HAP，安装前需按仓库 README 完成签名。')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      }

      SecondaryButton({
        label: '打开发布页',
        onTap: () => this.openUrl(this.releasePageUrl()),
      });

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

  /** 应用内升级的下载进度（百分比未知时只给文案，避免进度条撒谎）。 */
  @Builder
  downloadProgressBlock() {
    Column({ space: 6 }) {
      if (this.downloadPercent >= 0) {
        Progress({ value: this.downloadPercent, total: 100, type: ProgressType.Linear })
          .width('100%')
          .color($r('app.color.brand_primary'));
      }
      Text(this.downloadProgressLabel())
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }
}
