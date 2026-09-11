@Component
export struct SecondaryButton {
  label: string = '';
  buttonEnabled: boolean = true;
  fullWidth: boolean = true;
  compact: boolean = false;
  onTap?: () => void;

  build() {
    Button(this.label, { type: ButtonType.Capsule, stateEffect: false })
      .height(this.compact ? $r('app.float.button_height_compact') : $r('app.float.button_height'))
      .fontSize(this.compact ? 14 : 16)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.brand_primary'))
      .enabled(this.buttonEnabled)
      .opacity(this.buttonEnabled ? 1 : 0.55)
      .width(this.fullWidth ? '100%' : undefined)
      .backgroundColor($r('app.color.brand_primary_light'))
      .border({
        width: 1,
        color: '#66007DFF',
      })
      .stateStyles({
        pressed: {
          .backgroundColor($r('app.color.brand_primary_light_pressed'))
        },
      })
      .onClick(() => {
        if (this.buttonEnabled && this.onTap) {
          this.onTap();
        }
      });
  }
}
