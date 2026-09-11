import { ReaderTheme } from '../../models/ReaderTheme';
import { ReaderThemeColors } from '../../theme/ReaderThemeColors';
import { IconCircleButton } from '../IconCircleButton';

@Component
export struct ReaderChrome {
  @Prop bookTitle: string = '';
  @Prop chapterTitle: string = '';
  @Prop theme: ReaderTheme = ReaderTheme.LIGHT;
  @Prop expanded: boolean = false;
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
        IconCircleButton({
          icon: $r('sys.symbol.chevron_left'),
          variant: 'ghost',
          iconColor: ReaderThemeColors.textColor(this.theme),
          onTap: () => this.onBack(),
        });
        Text(this.bookTitle.length > 0 ? this.bookTitle : '阅读中')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(ReaderThemeColors.textColor(this.theme))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center);
        this.topIconButton($r('sys.symbol.bookmark'), () => this.onBookmark());
        this.topIconButton($r('sys.symbol.arrow_clockwise'), () => this.onRefresh());
        this.topIconButton($r('sys.symbol.bookmark'), () => this.onOpenBookmarks());
      }
      .width('100%')
      .padding({ left: 4, right: 4, top: 6, bottom: 4 })
      .alignItems(VerticalAlign.Center);
      Text(this.chapterTitle.length > 0 ? this.chapterTitle : ' ')
        .fontSize(13)
        .fontColor(ReaderThemeColors.textHint(this.theme))
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 16, right: 16, bottom: 8 });
    }
    .width('100%')
    .backgroundColor(ReaderThemeColors.barBackground(this.theme))
    .align(Alignment.Top)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP]);
  }

  @Builder
  topIconButton(icon: Resource, action: () => void) {
    IconCircleButton({
      icon: icon,
      variant: 'ghost',
      iconSize: 18,
      iconColor: ReaderThemeColors.textColor(this.theme),
      onTap: action,
    });
  }
}
