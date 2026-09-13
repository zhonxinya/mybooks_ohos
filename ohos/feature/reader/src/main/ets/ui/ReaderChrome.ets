import { ReaderTheme } from '../model/ReaderTypes';
import { ReaderPalette } from '../model/ReaderPalette';
import { ReaderIconButton } from './ReaderIconButton';

/**
 * 阅读页顶栏：返回 + 书名 + 动作图标 + 章节标题。
 *
 * 与 ReadKit 阅读器共用同一套结构（内置阅读器与 ReaderKit 阅读器观感一致）。
 * `showBookmarkActions` 用于隐藏书签动作：内置阅读器暂无书签能力，点了没反应反而更差。
 */
@Component
export struct ReaderChrome {
  @Prop bookTitle: string = '';
  @Prop chapterTitle: string = '';
  /** 章节行右侧的进度文字（如「第 3/37 页 · 25%」）；空则不显示 */
  @Prop chapterProgressText: string = '';
  @Prop theme: ReaderTheme = ReaderTheme.LIGHT;
  @Prop expanded: boolean = false;
  @Prop showBookmarkActions: boolean = true;
  onBack: () => void = () => {};
  onBookmark: () => void = () => {};
  onRefresh: () => void = () => {};
  onOpenBookmarks: () => void = () => {};

  build() {
    Column() {
      if (this.expanded) {
        this.expandedTopBar();
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  expandedTopBar() {
    Column() {
      Row() {
        ReaderIconButton({
          icon: $r('sys.symbol.chevron_left'),
          iconSize: 22,
          iconColor: ReaderPalette.textColor(this.theme),
          onTap: () => this.onBack(),
        });
        Text(this.bookTitle.length > 0 ? this.bookTitle : '阅读中')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(ReaderPalette.textColor(this.theme))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center);
        if (this.showBookmarkActions) {
          this.topIconButton($r('sys.symbol.bookmark'), () => this.onBookmark());
        }
        this.topIconButton($r('sys.symbol.arrow_clockwise'), () => this.onRefresh());
        if (this.showBookmarkActions) {
          // 不能再用 bookmark：与「加书签」同图难以区分（原实现两个按钮同图标）
          this.topIconButton($r('sys.symbol.list_bullet'), () => this.onOpenBookmarks());
        }
      }
      .width('100%')
      .padding({ left: 4, right: 4, top: 6, bottom: 4 })
      .alignItems(VerticalAlign.Center);
      Row() {
        Text(this.chapterTitle.length > 0 ? this.chapterTitle : ' ')
          .fontSize(13)
          .fontColor(ReaderPalette.hintColor(this.theme))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        if (this.chapterProgressText.length > 0) {
          Text(this.chapterProgressText)
            .fontSize(12)
            .fontColor(ReaderPalette.hintColor(this.theme))
            .maxLines(1);
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 });
    }
    .width('100%')
    .backgroundColor(ReaderPalette.barBackground(this.theme))
    .align(Alignment.Top)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP]);
  }

  @Builder
  topIconButton(icon: Resource, action: () => void) {
    ReaderIconButton({
      icon: icon,
      iconSize: 18,
      iconColor: ReaderPalette.textColor(this.theme),
      onTap: action,
    });
  }
}
