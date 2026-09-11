import { AuthImage } from './AuthImage';

@Component
export struct BookCoverTile {
  title: string = '';
  cover: string = '';
  onTap?: () => void;

  build() {
    Column({ space: 6 }) {
      if (this.cover.length > 0) {
        AuthImage({
          url: this.cover,
          imageWidth: $r('app.float.cover_tile_width'),
          imageHeight: $r('app.float.cover_tile_height'),
        })
          .borderRadius($r('app.float.cover_radius'))
          .shadow({ radius: 10, color: '#26000000', offsetX: 0, offsetY: 4 });
      } else {
        Column() {
          Text((this.title.length > 0 ? this.title : '?').substring(0, 1))
            .fontSize(24)
            .fontColor($r('app.color.on_brand'));
        }
        .width($r('app.float.cover_tile_width'))
        .height($r('app.float.cover_tile_height'))
        .borderRadius($r('app.float.cover_radius'))
        .backgroundColor($r('app.color.cover_placeholder'))
        .justifyContent(FlexAlign.Center);
      }
      Text(this.title.length > 0 ? this.title : '未知书名')
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width($r('app.float.cover_tile_width'));
    }
    .onClick(() => {
      if (this.onTap) {
        this.onTap();
      }
    });
  }
}
