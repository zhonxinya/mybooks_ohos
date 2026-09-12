import { router } from '@kit.ArkUI';
import { BookshelfPage } from './BookshelfPage';
import { BooksTabPage } from './BooksTabPage';
import { SettingsPage } from './SettingsPage';
import { BookshelfRefresh } from '../utils/BookshelfRefresh';
import { ReleaseInfo, UpdateCheckResult, UpdateService } from '../services/UpdateService';

@Entry
@Component
struct MainTabs {
  @State currentIndex: number = 0;
  @State showBooksTab: boolean = false;
  @State showSettingsTab: boolean = false;
  /** 自动登录失败原因（由 EntryAbility 写入；登录页已移除，这里负责提示）。 */
  @StorageProp('authFailureReason') @Watch('onAuthFailureChanged') authFailure: string = '';
  /** 服务端类型被自愈纠正后的提示（值为纠正后的服务端展示名）。 */
  @StorageProp('serverKindNotice') @Watch('onAuthFailureChanged') serverKindNotice: string = '';
  private tabsController: TabsController = new TabsController();

  /**
   * 支持外页深链：`pushUrl({ url: 'pages/MainTabs', params: { tab: 2 } })` 直达指定 Tab。
   * 未传参时保持默认（书架），不改变原有冷启动行为。
   */
  aboutToAppear(): void {
    // 冷启动静默检查更新：命中缓存或无新版本时不会有任何打扰
    void this.checkUpdateOnStartup();
    const params: Record<string, Object> | null = router.getParams() as Record<string, Object> | null;
    if (params === null || params === undefined) {
      return;
    }
    const raw: Object | undefined = params['tab'];
    if (raw === undefined) {
      return;
    }
    const tab: number = Number(raw);
    if (tab === 1) {
      this.showBooksTab = true;
      this.currentIndex = tab;
    } else if (tab === 2) {
      this.showSettingsTab = true;
      this.currentIndex = tab;
    }
  }

  onPageShow(): void {
    // 兜底：EntryAbility 先于本页写入失败原因时，@Watch 不会触发，这里主动提示一次
    this.reportAuthFailure();
    // 仅书架页可见时刷新，避免在设置/小说 Tab 或后台误触发整表重建
    if (this.currentIndex === 0) {
      BookshelfRefresh.notify();
    }
  }

  private onAuthFailureChanged(): void {
    this.reportAuthFailure();
  }

  /** 提示一次启动期的失败/纠正信息并清空，避免每次回到首页重复打扰。 */
  private reportAuthFailure(): void {
    if (this.serverKindNotice.length > 0) {
      const kind: string = this.serverKindNotice;
      AppStorage.setOrCreate('serverKindNotice', '');
      this.getUIContext().getPromptAction().showToast({
        message: `已按服务器实际类型识别为 ${kind}`,
      });
      return;
    }
    if (this.authFailure.length === 0) {
      return;
    }
    const reason: string = this.authFailure;
    // 先清空（会触发 @Watch，此时已为空直接返回），再提示
    AppStorage.setOrCreate('authFailureReason', '');
    this.getUIContext().getPromptAction().showToast({
      message: `自动登录失败：${reason}。请在「账号与服务器」中核对地址与账号`,
    });
  }

  private onTabChanged(index: number): void {
    this.currentIndex = index;
    if (index === 1) {
      this.showBooksTab = true;
    } else if (index === 2) {
      this.showSettingsTab = true;
    } else if (index === 0) {
      BookshelfRefresh.notify();
    }
  }

  /**
   * 冷启动静默检查更新：仅当存在更高版本、且既未被「忽略」也未提示过时，弹一次升级提示。
   * 任何失败都保持静默（用户可在 设置 → 关于 → 检查更新 手动触发）。
   */
  private async checkUpdateOnStartup(): Promise<void> {
    try {
      const result: UpdateCheckResult = await UpdateService.check(false);
      const release: ReleaseInfo | null = result.release;
      if (!result.ok || !result.hasUpdate || release === null) {
        return;
      }
      const tag: string = release.tag;
      if (tag === UpdateService.skippedTag() || tag === UpdateService.promptedTag()) {
        return;
      }
      UpdateService.markPrompted(tag);
      this.promptUpdate(tag, release.version, UpdateService.summarize(release.body));
    } catch (_error) {
      // 启动检查失败无需打扰用户
    }
  }

  private promptUpdate(tag: string, version: string, summary: string): void {
    this.getUIContext().getPromptAction().showDialog({
      title: `发现新版本 v${version}`,
      message: summary.length > 0 ? summary : '前往更新页查看本次升级内容。',
      buttons: [
        { text: '查看升级内容', color: '#007DFF' },
        { text: '忽略此版本', color: '#999999' },
      ],
    }).then((result) => {
      if (result.index === 0) {
        router.pushUrl({ url: 'pages/UpdatePage' }).catch(() => {
        });
      } else if (result.index === 1) {
        UpdateService.skipVersion(tag);
      }
    }).catch(() => {
    });
  }

  @Builder
  tabBuilder(index: number, title: string, symbol: Resource) {
    Column({ space: 4 }) {
      SymbolGlyph(symbol)
        .fontSize(22)
        .fontColor([this.currentIndex === index ? $r('app.color.brand_primary') :
          $r('app.color.text_secondary')]);
      Text(title)
        .fontSize(10)
        .fontColor(this.currentIndex === index ? $r('app.color.brand_primary') :
          $r('app.color.text_secondary'));
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center);
  }

  build() {
    Tabs({ barPosition: BarPosition.End, controller: this.tabsController, index: this.currentIndex }) {
      TabContent() {
        BookshelfPage();
      }.tabBar(this.tabBuilder(0, '书架', $r('sys.symbol.square_grid_2x2')));

      TabContent() {
        if (this.showBooksTab) {
          BooksTabPage();
        }
      }.tabBar(this.tabBuilder(1, '小说', $r('sys.symbol.book')));

      TabContent() {
        if (this.showSettingsTab) {
          SettingsPage();
        }
      }.tabBar(this.tabBuilder(2, '设置', $r('sys.symbol.gearshape')));
    }
    .barMode(BarMode.Fixed)
    .barHeight(56)
    .barBackgroundColor($r('app.color.card_background'))
    .onChange((index: number) => this.onTabChanged(index))
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'));
  }
}
