import { AuthImage } from './AuthImage';

@Component
export struct BookGridCard {
  title: string = '';
  author: string = '';
  cover: string = '';
  format: string = '';
  subtitle: string = '';
  onTap?: () => void;
  onLongPress?: () => void;

  @Builder
  coverArea() {
    if (this.cover.length > 0) {
      AuthImage({
        url: this.cover,
        imageWidth: '100%',
        imageHeight: '100%',
      })
        .width('100%')
        .aspectRatio(0.7);
    } else {
      Column() {
        Text((this.title.length > 0 ? this.title : '?').substring(0, 1))
          .fontSize(28)
          .fontColor($r('app.color.on_brand'));
      }
      .width('100%')
      .aspectRatio(0.7)
      .borderRadius($r('app.float.cover_radius'))
      .backgroundColor($r('app.color.cover_placeholder'))
      .justifyContent(FlexAlign.Center);
    }
  }

  build() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        this.coverArea();
        if (this.format.length > 0) {
          Text(this.format.toUpperCase())
            .fontSize(10)
            .fontColor($r('app.color.on_brand'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ top: 6, right: 6 })
            .borderRadius(4)
            .backgroundColor('#99000000');
        }
      }
      .width('100%');

      Text(this.title.length > 0 ? this.title : '未知书名')
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
      if (this.author.length > 0) {
        Text(this.author)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      if (this.subtitle.length > 0) {
        Text(this.subtitle)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
    }
    .width('100%')
    .height(220)
    .padding($r('app.float.card_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .shadow({ radius: 8, color: '#14000000', offsetX: 0, offsetY: 2 })
    .onClick(() => {
      if (this.onTap) {
        this.onTap();
      }
    })
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction(() => {
          if (this.onLongPress) {
            this.onLongPress();
          }
        }),
    );
  }
}
