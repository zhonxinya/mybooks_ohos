@Component
export struct SwipeDeleteAction {
  onDelete: () => void = () => {};

  build() {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Column({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(20)
          .fontColor([Color.White]);
        Text('删除')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White);
      }
      .justifyContent(FlexAlign.Center);
    }
    .width(72)
    .height('100%')
    .backgroundColor($r('app.color.error'))
    .borderRadius({ topRight: $r('app.float.card_radius'), bottomRight: $r('app.float.card_radius') })
    .onClick(() => this.onDelete());
  }
}
