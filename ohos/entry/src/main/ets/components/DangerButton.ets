@Component
export struct DangerButton {
  label: string = '';
  buttonEnabled: boolean = true;
  fullWidth: boolean = true;
  onTap?: () => void;

  build() {
    Button(this.label, { type: ButtonType.Normal, stateEffect: false })
      .height($r('app.float.button_height'))
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.error'))
      .enabled(this.buttonEnabled)
      .opacity(this.buttonEnabled ? 1 : 0.55)
      .width(this.fullWidth ? '100%' : undefined)
      // 圆角矩形不像胶囊那样自带弧度收边，非全宽时必须给足水平内边距
      .padding({ left: this.fullWidth ? 16 : 24, right: this.fullWidth ? 16 : 24 })
      .backgroundColor($r('app.color.error_light'))
      .border({
        width: 1,
        color: '#33E84026',
        // 圆角必须写进 border：先 borderRadius 再 border 会重置圆角
        radius: $r('app.float.button_radius'),
      })
      .stateStyles({
        pressed: {
          .backgroundColor($r('app.color.error_light_pressed'))
        },
      })
      .onClick(() => {
        if (this.buttonEnabled && this.onTap) {
          this.onTap();
        }
      });
  }
}
