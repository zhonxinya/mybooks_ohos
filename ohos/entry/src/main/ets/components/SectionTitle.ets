@Component
export struct SectionTitle {
  title: string = '';
  actionLabel: string = '';
  /** 动作按钮的加载态：显示转圈、文字转灰，并屏蔽点击（防重复请求）。 */
  actionLoading: boolean = false;
  onAction?: () => void;
  /** 墨水屏模式：去掉持续旋转的转圈（文字转灰仍表达「进行中」）。 */
  @StorageProp('eink_mode') private einkMode: boolean = false;

  build() {
    Row({ space: 8 }) {
      Column()
        .width(4)
        .height(16)
        .borderRadius(2)
        .backgroundColor($r('app.color.brand_primary'));
      Text(this.title)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1);
      if (this.actionLabel.length > 0 && this.onAction) {
        Row({ space: 4 }) {
          if (this.actionLoading && !this.einkMode) {
            LoadingProgress()
              .width(14)
              .height(14)
              .color($r('app.color.brand_primary'));
          }
          Text(this.actionLabel)
            .fontSize(13)
            .fontColor(this.actionLoading
              ? $r('app.color.text_tertiary')
              : $r('app.color.brand_primary'));
        }
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          if (!this.actionLoading) {
            this.onAction!();
          }
        });
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 8 });
  }
}
