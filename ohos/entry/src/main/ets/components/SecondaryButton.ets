@Component
export struct SecondaryButton {
  label: string = '';
  buttonEnabled: boolean = true;
  fullWidth: boolean = true;
  compact: boolean = false;
  onTap?: () => void;

  /** 非全宽时的水平内边距：圆角矩形不像胶囊那样自带弧度收边，需显式留白 */
  private horizontalPadding(): number {
    if (this.fullWidth) {
      return 16;
    }
    return this.compact ? 20 : 24;
  }

  build() {
    Button(this.label, { type: ButtonType.Normal, stateEffect: false })
      .height(this.compact ? $r('app.float.button_height_compact') : $r('app.float.button_height'))
      .fontSize(this.compact ? 14 : 16)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.brand_primary'))
      .enabled(this.buttonEnabled)
      .opacity(this.buttonEnabled ? 1 : 0.55)
      .width(this.fullWidth ? '100%' : undefined)
      .padding({ left: this.horizontalPadding(), right: this.horizontalPadding() })
      .backgroundColor($r('app.color.brand_primary_light'))
      .border({
        width: 1,
        color: '#66007DFF',
        // 圆角必须写进 border：先 borderRadius 再 border 会重置圆角，导致渲染成直角方块
        radius: $r('app.float.button_radius'),
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
