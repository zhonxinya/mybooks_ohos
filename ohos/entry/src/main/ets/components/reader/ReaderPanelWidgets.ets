import { ReaderTheme } from '../../models/ReaderTheme';
import { ReaderThemeColors } from '../../theme/ReaderThemeColors';

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
          .fontColor(ReaderThemeColors.textColor(this.theme))
          .width('100%');
      }
      Column({ space: 12 }) {
        this.content();
      }
      .width('100%')
      .padding(12)
      .backgroundColor(ReaderThemeColors.panelSectionBg(this.theme))
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
          .fontColor(this.selectedIndex === index ? $r('app.color.brand_primary') :
            ReaderThemeColors.textHint(this.theme))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 8, bottom: 8 })
          .backgroundColor(this.selectedIndex === index ?
            ReaderThemeColors.chipSelectedBg(this.theme) :
            ReaderThemeColors.chipIdleBg(this.theme))
          .borderRadius(16)
          .onClick(() => this.onSelect(index));
      }, (label: string, index: number) => `${index}_${label}`);
    }
    .width('100%')
    .padding(4)
    .backgroundColor(ReaderThemeColors.chipIdleBg(this.theme))
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
      .fontColor(this.selected ? $r('app.color.brand_primary') : ReaderThemeColors.textHint(this.theme))
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(this.selected ? ReaderThemeColors.chipSelectedBg(this.theme) :
        ReaderThemeColors.chipIdleBg(this.theme))
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
        .fontColor(ReaderThemeColors.textColor(this.theme))
        .width('100%');
      Slider({
        value: this.value,
        min: this.min,
        max: this.max,
        step: this.step,
      })
        .blockColor(ReaderThemeColors.textColor(this.theme))
        .trackColor(ReaderThemeColors.divider(this.theme))
        .selectedColor($r('app.color.brand_primary'))
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
          .fontColor(ReaderThemeColors.textColor(this.theme));
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(12)
            .fontColor(ReaderThemeColors.textHint(this.theme));
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start);
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
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
            .fontColor(this.selected ? $r('app.color.brand_primary') :
              ReaderThemeColors.textHint(this.theme))
            .width(28);
        }
        Text(this.title)
          .fontSize(15)
          .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.selected ? $r('app.color.brand_primary') :
            ReaderThemeColors.textColor(this.theme))
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .width('100%')
      .padding({ top: 12, bottom: 12, left: 8, right: 8 })
      .backgroundColor(this.selected ? ReaderThemeColors.chipSelectedBg(this.theme) : Color.Transparent)
      .borderRadius(8)
      .onClick(() => this.onTap());
      if (this.showDivider) {
        Divider().color(ReaderThemeColors.divider(this.theme)).strokeWidth(0.5);
      }
    }
    .width('100%');
  }
}
