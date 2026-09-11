export type TextButtonTone = 'brand' | 'danger';

@Component
export struct TextButton {
  label: string = '';
  tone: TextButtonTone = 'brand';
  onTap?: () => void;

  build() {
    Button(this.label, { type: ButtonType.Normal, stateEffect: false })
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.tone === 'danger' ? $r('app.color.error') : $r('app.color.brand_primary'))
      .backgroundColor(Color.Transparent)
      .padding({ left: 8, right: 8 })
      .stateStyles({
        pressed: {
          .backgroundColor($r('app.color.surface_pressed'))
        },
      })
      .onClick(() => {
        if (this.onTap) {
          this.onTap();
        }
      });
  }
}
