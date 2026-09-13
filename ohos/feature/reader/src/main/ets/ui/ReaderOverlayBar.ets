import { ReaderTheme } from '../model/ReaderTypes';
import { ReaderPalette } from '../model/ReaderPalette';
import { ReaderIconButton } from './ReaderIconButton';

/**
 * 阅读页底部浮层：快捷动作 + 上一章/章节进度/下一章 + 底部页签。
 *
 * 结构与 ReadKit 阅读器一致（两个阅读器观感统一）；未实现的能力用开关隐藏，
 * 避免出现「点了没反应」的入口。
 */
@Component
export struct ReaderOverlayBar {
  @Prop theme: ReaderTheme = ReaderTheme.LIGHT;
  /** 本章进度 0~1，滑杆拖动后回调新值 */
  @Prop chapterProgress: number = 0;
  @Prop canGoPrevChapter: boolean = false;
  @Prop canGoNextChapter: boolean = false;
  @Prop activeNav: string = '';
  /** 能力开关：默认只开「刷新 / 夜间 / 目录 / 界面 / 设置」 */
  @Prop showSearch: boolean = false;
  @Prop showAloud: boolean = false;
  @Prop showRefresh: boolean = true;
  @Prop showNight: boolean = true;
  onSearch: () => void = () => {};
  onReadAloud: () => void = () => {};
  onRefresh: () => void = () => {};
  onToggleNight: () => void = () => {};
  onPrevChapter: () => void = () => {};
  onNextChapter: () => void = () => {};
  onChapterProgressChange: (value: number) => void = (_value: number) => {};
  onOpenToc: () => void = () => {};
  onOpenAloud: () => void = () => {};
  onOpenAppearance: () => void = () => {};
  onOpenSettings: () => void = () => {};

  build() {
    Column({ space: 10 }) {
      this.quickActionsRow();
      this.chapterNavRow();
      this.bottomNavRow();
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 8 })
    .backgroundColor(ReaderPalette.barBackground(this.theme))
    .borderRadius({ topLeft: 16, topRight: 16 })
    .shadow({ radius: 20, color: '#30000000', offsetX: 0, offsetY: -6 })
    // 圆角必须写进 border：先 borderRadius 再 border 会重置圆角
    .border({
      width: { top: 0.5 },
      color: ReaderPalette.dividerColor(this.theme),
      radius: { topLeft: 16, topRight: 16 },
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM]);
  }

  @Builder
  quickActionsRow() {
    Row() {
      if (this.showSearch) {
        this.quickActionButton($r('sys.symbol.magnifyingglass'), () => this.onSearch());
      }
      if (this.showAloud) {
        this.quickActionButton($r('sys.symbol.doc_text'), () => this.onReadAloud());
      }
      if (this.showRefresh) {
        this.quickActionButton($r('sys.symbol.arrow_clockwise'), () => this.onRefresh());
      }
      if (this.showNight) {
        this.quickActionButton($r('sys.symbol.moon'), () => this.onToggleNight());
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceAround);
  }

  @Builder
  quickActionButton(icon: Resource, action: () => void) {
    ReaderIconButton({
      icon: icon,
      iconSize: 20,
      buttonSize: 44,
      iconColor: ReaderPalette.textColor(this.theme),
      buttonBackground: ReaderPalette.chipIdleBackground(this.theme),
      onTap: action,
    });
  }

  @Builder
  chapterNavRow() {
    Row({ space: 8 }) {
      Text('上一章')
        .fontSize(14)
        .fontColor(this.chapterNavColor(this.canGoPrevChapter))
        .padding({ left: 4, right: 4, top: 8, bottom: 8 })
        .onClick(() => {
          if (this.canGoPrevChapter) {
            this.onPrevChapter();
          }
        });
      Slider({
        value: Math.round(this.chapterProgress * 100),
        min: 0,
        max: 100,
        step: 1,
        style: SliderStyle.OutSet,
      })
        .layoutWeight(1)
        .blockColor(ReaderPalette.textColor(this.theme))
        .trackColor(ReaderPalette.dividerColor(this.theme))
        .selectedColor(ReaderPalette.accentColor())
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.onChapterProgressChange(value / 100);
          }
        });
      Text('下一章')
        .fontSize(14)
        .fontColor(this.chapterNavColor(this.canGoNextChapter))
        .padding({ left: 4, right: 4, top: 8, bottom: 8 })
        .onClick(() => {
          if (this.canGoNextChapter) {
            this.onNextChapter();
          }
        });
    }
    .width('100%')
    .alignItems(VerticalAlign.Center);
  }

  @Builder
  bottomNavRow() {
    Row() {
      this.navItem('目录', $r('sys.symbol.list_bullet'), 'toc', () => this.onOpenToc());
      if (this.showAloud) {
        this.navItem('朗读', $r('sys.symbol.doc_text'), 'aloud', () => this.onOpenAloud());
      }
      this.navItem('界面', $r('sys.symbol.sun_max'), 'appearance', () => this.onOpenAppearance());
      this.navItem('设置', $r('sys.symbol.gearshape'), 'settings', () => this.onOpenSettings());
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceAround)
    .padding({ top: 4, bottom: 4 });
  }

  @Builder
  navItem(label: string, icon: Resource, key: string, action: () => void) {
    Column({ space: 4 }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([this.activeNav === key ? ReaderPalette.accentColor() :
          ReaderPalette.textColor(this.theme)]);
      Text(label)
        .fontSize(12)
        .fontColor(this.activeNav === key ? ReaderPalette.accentColor() :
          ReaderPalette.hintColor(this.theme));
    }
    .width(72)
    .padding({ top: 6, bottom: 6 })
    .onClick(action);
  }

  private chapterNavColor(enabled: boolean): string {
    return enabled ? ReaderPalette.textColor(this.theme) : ReaderPalette.hintColor(this.theme);
  }
}
