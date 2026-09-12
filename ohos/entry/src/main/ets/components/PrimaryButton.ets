@Component
export struct PrimaryButton {
  @Prop label: string = '';
  @Prop buttonEnabled: boolean = true;
  @Prop fullWidth: boolean = true;
  onTap?: () => void;

  build() {
    Button(this.label, { type: ButtonType.Normal, stateEffect: false })
      .height($r('app.float.button_height'))
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.on_brand'))
      .enabled(this.buttonEnabled)
      .opacity(this.buttonEnabled ? 1 : 0.55)
      .width(this.fullWidth ? '100%' : undefined)
      // 圆角矩形不像胶囊那样自带弧度收边，非全宽时必须给足水平内边距，否则文字会顶到圆角
      .padding({ left: this.fullWidth ? 16 : 24, right: this.fullWidth ? 16 : 24 })
      .borderRadius($r('app.float.button_radius'))
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
