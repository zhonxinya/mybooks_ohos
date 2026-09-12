import { router } from '@kit.ArkUI';
import { BookshelfPage } from './BookshelfPage';
import { BooksTabPage } from './BooksTabPage';
import { SettingsPage } from './SettingsPage';
import { BookshelfRefresh } from '../utils/BookshelfRefresh';

@Entry
@Component
struct MainTabs {
  @State currentIndex: number = 0;
  @State showBooksTab: boolean = false;
  @State showSettingsTab: boolean = false;
  private tabsController: TabsController = new TabsController();

  /**
   * 支持外页深链：`pushUrl({ url: 'pages/MainTabs', params: { tab: 2 } })` 直达指定 Tab。
   * 未传参时保持默认（书架），不改变原有冷启动行为。
   */
  aboutToAppear(): void {
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
    // 仅书架页可见时刷新，避免在设置/小说 Tab 或后台误触发整表重建
    if (this.currentIndex === 0) {
      BookshelfRefresh.notify();
    }
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
