/** 星级评分展示组件（对齐 Web 端 v-rating），rating 为 0-5 星。 */
@Component
export struct StarRating {
  rating: number = 0;
  starSize: number = 14;
  showValue: boolean = false;
  valueText: string = '';

  build() {
    Row({ space: 4 }) {
      Row({ space: 2 }) {
        ForEach([1, 2, 3, 4, 5], (index: number) => {
          SymbolGlyph(index <= Math.round(this.rating) ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
            .fontSize(this.starSize)
            .fontColor([index <= Math.round(this.rating) ?
              $r('app.color.brand_primary') : $r('app.color.divider')]);
        }, (index: number) => `star-${index}-${this.rating}`);
      }
      .alignItems(VerticalAlign.Center);
      if (this.showValue && this.valueText.length > 0) {
        Text(this.valueText)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'));
      }
    }
    .alignItems(VerticalAlign.Center);
  }
}
