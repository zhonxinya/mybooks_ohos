@Component
export struct PrimaryButton {
  @Prop label: string = '';
  @Prop buttonEnabled: boolean = true;
  @Prop fullWidth: boolean = true;
  onTap?: () => void;

  build() {
    Button(this.label, { type: ButtonType.Capsule, stateEffect: false })
      .height($r('app.float.button_height'))
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.on_brand'))
      .enabled(this.buttonEnabled)
      .opacity(this.buttonEnabled ? 1 : 0.55)
      .width(this.fullWidth ? '100%' : undefined)
      .backgroundColor($r('app.color.brand_primary'))
      .shadow({
        radius: 10,
        color: $r('app.color.button_shadow'),
        offsetX: 0,
        offsetY: 4,
      })
      .stateStyles({
        pressed: {
          .backgroundColor($r('app.color.brand_primary_pressed'))
        },
      })
      .onClick(() => {
        if (this.buttonEnabled && this.onTap) {
          this.onTap();
        }
      });
  }
}
