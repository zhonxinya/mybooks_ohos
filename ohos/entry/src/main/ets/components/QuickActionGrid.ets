export interface QuickActionItem {
  icon: Resource;
  label: string;
  onTap: () => void;
}

@Component
struct QuickActionCell {
  item: QuickActionItem = { icon: $r('sys.symbol.circle'), label: '', onTap: () => {} };

  build() {
    Column({ space: 6 }) {
      Column() {
        SymbolGlyph(this.item.icon)
          .fontSize(22)
          .fontColor([$r('app.color.brand_primary')]);
      }
      .width(48)
      .height(48)
      .justifyContent(FlexAlign.Center)
      .borderRadius(24)
      .backgroundColor($r('app.color.brand_primary_light'))

      Text(this.item.label)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'));
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 8, bottom: 8, left: 4, right: 4 })
    .borderRadius(12)
    .backgroundColor(Color.Transparent)
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(() => {
      this.item.onTap();
    });
  }
}

@Component
export struct QuickActionGrid {
  items: QuickActionItem[] = [];

  build() {
    Grid() {
      ForEach(this.items, (item: QuickActionItem) => {
        GridItem() {
          QuickActionCell({ item: item });
        }
      }, (item: QuickActionItem) => item.label);
    }
    .columnsTemplate('1fr 1fr 1fr 1fr')
    .rowsGap(14)
    .columnsGap(8)
    .width('100%')
    .padding({ left: 12, right: 12, top: 14, bottom: 14 })
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .shadow({ radius: 16, color: '#14000000', offsetX: 0, offsetY: 4 });
  }
}
