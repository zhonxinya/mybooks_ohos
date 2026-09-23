import { ReaderTheme } from '../model/ReaderTypes';
import { ReaderChrome } from './ReaderChrome';
import { ReaderOverlayBar } from './ReaderOverlayBar';

/**
 * 阅读器浮层工具栏（顶栏 + 底栏）。
 *
 * 独立 @Component：显隐由父级控制挂载，内部只接收低频展示数据，
 * 避免与翻页 dragOffset 等高频态挤在同一组件里相互拖累重建。
 */
@Component
export struct ReaderBarsOverlay {
  @Prop bookTitle: string = '';
  @Prop chapterTitle: string = '';
  @Prop chapterProgressText: string = '';
  @Prop theme: ReaderTheme = ReaderTheme.LIGHT;
  @Prop chapterProgress: number = 0;
  @Prop canGoPrevChapter: boolean = false;
  @Prop canGoNextChapter: boolean = false;
  @Prop activeNav: string = '';
  @Prop showBookmarkActions: boolean = false;
  onBack: () => void = () => {};
  onRefresh: () => void = () => {};
  onToggleNight: () => void = () => {};
  onPrevChapter: () => void = () => {};
  onNextChapter: () => void = () => {};
  onChapterProgressChange: (value: number) => void = (_value: number) => {};
  onOpenToc: () => void = () => {};
  onOpenAppearance: () => void = () => {};
  onOpenSettings: () => void = () => {};

  build() {
    Column() {
      ReaderChrome({
        bookTitle: this.bookTitle,
        chapterTitle: this.chapterTitle,
        chapterProgressText: this.chapterProgressText,
        theme: this.theme,
        expanded: true,
        showBookmarkActions: this.showBookmarkActions,
        onBack: () => this.onBack(),
        onRefresh: () => this.onRefresh(),
      });
      // Blank 也必须放行：它是子节点，默认会吃掉中间区域的点击/滑动
      Blank()
        .hitTestBehavior(HitTestMode.None);
      ReaderOverlayBar({
        theme: this.theme,
        chapterProgress: this.chapterProgress,
        canGoPrevChapter: this.canGoPrevChapter,
        canGoNextChapter: this.canGoNextChapter,
        activeNav: this.activeNav,
        showSearch: false,
        showAloud: false,
        showRefresh: true,
        showNight: true,
        onRefresh: () => this.onRefresh(),
        onToggleNight: () => this.onToggleNight(),
        onPrevChapter: () => this.onPrevChapter(),
        onNextChapter: () => this.onNextChapter(),
        onChapterProgressChange: (value: number) => this.onChapterProgressChange(value),
        onOpenToc: () => this.onOpenToc(),
        onOpenAppearance: () => this.onOpenAppearance(),
        onOpenSettings: () => this.onOpenSettings(),
      });
    }
    .width('100%')
    .height('100%')
    // 工具栏之间的空白必须让点击穿透到正文：否则工具栏显示时中间点击/左右翻页都失效
    .hitTestBehavior(HitTestMode.None);
  }
}
