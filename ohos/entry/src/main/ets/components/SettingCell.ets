@Component
export struct SettingCell {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop valueText: string = '';
  @Prop badgeText: string = '';
  showChevron: boolean = false;
  showToggle: boolean = false;
  @Prop toggleOn: boolean = false;
  onToggle?: (value: boolean) => void;
  onTap?: () => void;

  build() {
    Row() {
      Column({ space: 4 }) {
        Text(this.title)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'));
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'));
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      if (this.showToggle) {
        Toggle({ type: ToggleType.Switch, isOn: this.toggleOn })
          .onChange((value: boolean) => {
            if (this.onToggle) {
              this.onToggle(value);
            }
          });
      } else if (this.badgeText.length > 0) {
        Text(this.badgeText)
          .fontSize(12)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.brand_primary'))
          .borderRadius($r('app.float.badge_radius'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 });
        if (this.showChevron) {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([$r('app.color.text_tertiary')]);
        }
      } else if (this.valueText.length > 0) {
        Text(this.valueText)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'));
      } else if (this.showChevron) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([$r('app.color.text_tertiary')]);
      }
    }
    .width('100%')
    .padding($r('app.float.page_padding'))
    .backgroundColor(Color.Transparent)
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(() => {
      if (this.onTap && !this.showToggle) {
        this.onTap();
      }
    });
  }
}
