@Component
export struct LoadingState {
  hint: string = '';
  /** 墨水屏模式：转圈是持续动画，低刷新率面板上只会拖影耗电——只保留静态文字。 */
  @StorageProp('eink_mode') private einkMode: boolean = false;

  build() {
    Column({ space: 12 }) {
      if (!this.einkMode) {
        LoadingProgress()
          .width(48)
          .height(48)
          .color($r('app.color.brand_primary'));
      }
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
