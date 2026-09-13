import { ReaderTheme } from '../model/ReaderTypes';
import { ReaderPalette } from '../model/ReaderPalette';

/**
 * 阅读控制面板的通用控件（两套阅读器共用）。
 *
 * 与 entry 版（`components/reader/ReaderPanelWidgets`）的差异：
 * 配色改用模块自己的 `ReaderPalette`，强调色用 `ReaderPalette.accentColor()` 字面量，
 * 不引用 `$r('app.color.*')`，保持 feature 模块自包含。
 */

@Component
export struct ReaderPanelSection {
  @Prop theme: ReaderTheme = ReaderTheme.LIGHT;
  @Prop title: string = '';
  @BuilderParam content: () => void = this.defaultContent;

  @Builder
  defaultContent(): void {
  }

  build() {
    Column({ space: 8 }) {
      if (this.title.length > 0) {
        Text(this.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(ReaderPalette.textColor(this.theme))
          .width('100%');
      }
      Column({ space: 12 }) {
        this.content();
      }
      .width('100%')
      .padding(12)
      .backgroundColor(ReaderPalette.sectionBackground(this.theme))
      .borderRadius(12);
    }
    .width('100%');
  }
}

@Component
export struct ReaderSegmentedControl {
  @Prop theme: ReaderTheme = ReaderTheme.LIGHT;
  @Prop labels: string[] = [];
  @Prop selectedIndex: number = 0;
  onSelect: (index: number) => void = (_index: number) => {};

  build() {
    Row({ space: 4 }) {
      ForEach(this.labels, (label: string, index: number) => {
        Text(label)
          .fontSize(12)
          .fontColor(this.selectedIndex === index ? ReaderPalette.accentColor() :
            ReaderPalette.hintColor(this.theme))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 8, bottom: 8 })
          .backgroundColor(this.selectedIndex === index ?
            ReaderPalette.selectedBackground(this.theme) :
            ReaderPalette.chipIdleBackground(this.theme))
          .borderRadius(16)
          .onClick(() => this.onSelect(index));
      }, (label: string, index: number) => `${index}_${label}`);
    }
    .width('100%')
    .padding(4)
    .backgroundColor(ReaderPalette.chipIdleBackground(this.theme))
    .borderRadius(12);
  }
}

@Component
export struct ReaderChip {
  @Prop theme: ReaderTheme = ReaderTheme.LIGHT;
  @Prop label: string = '';
  @Prop selected: boolean = false;
  onTap: () => void = () => {};

  build() {
    Text(this.label)
      .fontSize(12)
      .fontColor(this.selected ? ReaderPalette.accentColor() : ReaderPalette.hintColor(this.theme))
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(this.selected ? ReaderPalette.selectedBackground(this.theme) :
        ReaderPalette.chipIdleBackground(this.theme))
      .borderRadius(16)
      .onClick(() => this.onTap());
  }
}

@Component
export struct ReaderSliderBlock {
  @Prop theme: ReaderTheme = ReaderTheme.LIGHT;
  @Prop label: string = '';
  @Prop value: number = 0;
  @Prop min: number = 0;
  @Prop max: number = 100;
  @Prop step: number = 1;
  onChange: (value: number) => void = (_value: number) => {};

  build() {
    Column({ space: 8 }) {
      Text(this.label)
        .fontSize(14)
        .fontColor(ReaderPalette.textColor(this.theme))
        .width('100%');
      Slider({
        value: this.value,
        min: this.min,
        max: this.max,
        step: this.step,
      })
        .blockColor(ReaderPalette.textColor(this.theme))
        .trackColor(ReaderPalette.dividerColor(this.theme))
        .selectedColor(ReaderPalette.accentColor())
        .onChange((value: number) => this.onChange(value));
    }
    .width('100%');
  }
}

@Component
export struct ReaderSwitchRow {
  @Prop theme: ReaderTheme = ReaderTheme.LIGHT;
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop isOn: boolean = false;
  onChange: (value: boolean) => void = (_value: boolean) => {};

  build() {
    Row({ space: 8 }) {
      Column({ space: 4 }) {
        Text(this.title)
          .fontSize(14)
          .fontColor(ReaderPalette.textColor(this.theme));
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(12)
            .fontColor(ReaderPalette.hintColor(this.theme));
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start);
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor(ReaderPalette.accentColor())
        .onChange((value: boolean) => this.onChange(value));
    }
    .width('100%');
  }
}

@Component
export struct ReaderSelectRow {
  @Prop theme: ReaderTheme = ReaderTheme.LIGHT;
  @Prop leading: string = '';
  @Prop title: string = '';
  @Prop selected: boolean = false;
  @Prop showDivider: boolean = true;
  onTap: () => void = () => {};

  build() {
    Column() {
      Row({ space: 12 }) {
        if (this.leading.length > 0) {
          Text(this.leading)
            .fontSize(13)
            .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.selected ? ReaderPalette.accentColor() :
              ReaderPalette.hintColor(this.theme))
            .width(28);
        }
        Text(this.title)
          .fontSize(15)
          .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.selected ? ReaderPalette.accentColor() :
            ReaderPalette.textColor(this.theme))
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .width('100%')
      .padding({ top: 12, bottom: 12, left: 8, right: 8 })
      .backgroundColor(this.selected ? ReaderPalette.selectedBackground(this.theme) : Color.Transparent)
      .borderRadius(8)
      .onClick(() => this.onTap());
      if (this.showDivider) {
        Divider().color(ReaderPalette.dividerColor(this.theme)).strokeWidth(0.5);
      }
    }
    .width('100%');
  }
}

/** 面板里的文字按钮（替代 entry 的 `TextButton`，避免模块依赖宿主组件）。 */
@Component
export struct ReaderPanelButton {
  @Prop theme: ReaderTheme = ReaderTheme.LIGHT;
  @Prop label: string = '';
  /** 'normal' | 'danger' */
  @Prop tone: string = 'normal';
  onTap: () => void = () => {};

  build() {
    Text(this.label)
      .fontSize(14)
      .fontColor(this.tone === 'danger' ? '#E84026' : ReaderPalette.accentColor())
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor(ReaderPalette.chipIdleBackground(this.theme))
      .borderRadius(16)
      .onClick(() => this.onTap());
  }
}
