@Component
export struct DangerButton {
  label: string = '';
  buttonEnabled: boolean = true;
  fullWidth: boolean = true;
  onTap?: () => void;

  build() {
    Button(this.label, { type: ButtonType.Capsule, stateEffect: false })
      .height($r('app.float.button_height'))
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.error'))
      .enabled(this.buttonEnabled)
      .opacity(this.buttonEnabled ? 1 : 0.55)
      .width(this.fullWidth ? '100%' : undefined)
      .backgroundColor($r('app.color.error_light'))
      .border({
        width: 1,
        color: '#33E84026',
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
