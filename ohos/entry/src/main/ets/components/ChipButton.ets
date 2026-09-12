@Component
export struct ChipButton {
  @Prop label: string = '';
  @Prop selected: boolean = false;
  onTap?: () => void;

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      Text(this.label)
        .fontSize(13)
        .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.selected ? $r('app.color.on_brand') : $r('app.color.text_primary'));
    }
    .height(34)
    .padding({ left: 14, right: 14 })
    .backgroundColor(this.selected ? $r('app.color.brand_primary') : $r('app.color.card_background'))
    // 圆角必须写进 border：先 borderRadius 再 border 会重置圆角，旧写法使芯片/分段控件渲染成直角方块
    .border({
      width: 1,
      color: this.selected ? $r('app.color.brand_primary') : $r('app.color.divider'),
      radius: $r('app.float.chip_radius'),
    })
    .shadow(this.selected ? {
      radius: 6,
      color: '#26007DFF',
      offsetX: 0,
      offsetY: 2,
    } : {
      radius: 0,
      color: Color.Transparent,
      offsetX: 0,
      offsetY: 0,
    })
    .stateStyles({
      pressed: {
        .backgroundColor(this.selected ?
          $r('app.color.brand_primary_pressed') : $r('app.color.chip_background_pressed'))
      },
    })
    .onClick(() => {
      if (this.onTap) {
        this.onTap();
      }
    });
  }
}
