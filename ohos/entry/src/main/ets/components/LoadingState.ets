@Component
export struct LoadingState {
  hint: string = '';

  build() {
    Column({ space: 12 }) {
      LoadingProgress()
        .width(48)
        .height(48)
        .color($r('app.color.brand_primary'));
      Text(this.hint.length > 0 ? this.hint : $r('app.string.loading_hint'))
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'));
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center);
  }
}
