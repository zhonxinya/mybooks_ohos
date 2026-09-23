import { AuthImage } from './AuthImage';

export interface BookListItemData {
  id: string;
  title: string;
  author?: string;
  cover?: string;
  subtitle?: string;
  format?: string;
  /** 状态角标（如「已入库」）；空串不显示。 */
  badge?: string;
}

@Reusable
@Component
export struct BookListItem {
  @State item: BookListItemData = { id: '', title: '' };
  onTap?: () => void = undefined;

  aboutToReuse(params: Record<string, Object>): void {
    this.item = params.item as BookListItemData;
    this.onTap = params.onTap as (() => void) | undefined;
  }

  build() {
    Row({ space: 12 }) {
      if (this.item.cover && this.item.cover.length > 0) {
        AuthImage({
          url: this.item.cover,
          imageWidth: 64,
          imageHeight: 92,
          decodeWidthVp: 64,
          decodeHeightVp: 92,
        });
      } else {
        Column() {
          Text((this.item.title ?? '?').substring(0, 1))
            .fontSize(24)
            .fontColor($r('app.color.on_brand'));
        }
        .width(64)
        .height(92)
        .borderRadius($r('app.float.cover_radius'))
        .backgroundColor($r('app.color.cover_placeholder'))
        .justifyContent(FlexAlign.Center);
      }

      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(this.item.title ?? '未知书名')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1);
          if (this.item.badge !== undefined && this.item.badge.length > 0) {
            Text(this.item.badge)
              .fontSize(10)
              .fontColor($r('app.color.success'))
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4)
              .backgroundColor($r('app.color.success_light'));
          }
          if (this.item.format !== undefined && this.item.format.length > 0) {
            Text(this.item.format.toUpperCase())
              .fontSize(10)
              .fontColor($r('app.color.brand_primary'))
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4)
              .backgroundColor($r('app.color.brand_primary_light'));
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top);
        if (this.item.author && this.item.author.length > 0) {
          Text(this.item.author)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }
        if (this.item.subtitle && this.item.subtitle.length > 0) {
          Text(this.item.subtitle)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
    }
    .width('100%')
    .padding($r('app.float.card_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .onClick(() => {
      if (this.onTap) {
        this.onTap();
      }
    });
  }
}
