@Component
export struct SectionTitle {
  title: string = '';
  actionLabel: string = '';
  onAction?: () => void;

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
        Text(this.actionLabel)
          .fontSize(13)
          .fontColor($r('app.color.brand_primary'))
          .onClick(() => this.onAction!());
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 8 });
  }
}
