import { DownloadRecord } from '../services/TalebookService';
import { DateFormat } from '../utils/DateFormat';
import { AuthImage } from './AuthImage';

@Component
export struct BookCard {
  @Prop record: DownloadRecord;
  @Prop progressPercent: number = -1;
  onTap?: () => void;

  private metaLine(): string {
    const parts: string[] = [];
    const progress = this.record.progress;
    if (progress?.chapterName !== undefined && progress.chapterName.length > 0) {
      parts.push(`读到：${progress.chapterName}`);
    } else if (this.progressPercent >= 0) {
      parts.push(`已读 ${Math.round(this.progressPercent)}%`);
    }
    const lastRead = DateFormat.lastReadLabel(progress?.lastReadTime);
    if (lastRead.length > 0) {
      parts.push(lastRead);
    }
    return parts.join(' · ');
  }

  @Builder
  coverContent() {
    if (this.record.coverUrl && this.record.coverUrl.length > 0) {
      AuthImage({
        url: this.record.coverUrl,
        imageWidth: '100%',
        imageHeight: '100%',
      })
        .width('100%')
        .aspectRatio(0.7);
    } else {
      Column() {
        Text((this.record.title ?? '?').substring(0, 1))
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
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Stack({ alignContent: Alignment.Bottom }) {
          this.coverContent();
          if (this.progressPercent >= 0) {
            Row() {
              Row()
                .width(`${Math.min(100, Math.max(0, this.progressPercent))}%`)
                .height(3)
                .backgroundColor($r('app.color.brand_primary'))
                .borderRadius(2);
            }
            .width('100%')
            .height(3)
            .backgroundColor('#33FFFFFF')
            .borderRadius(2)
            .padding({ left: 4, right: 4, bottom: 4 });
          }
        }
        .width('100%');
        if (this.record.format !== undefined && this.record.format.length > 0) {
          Text(this.record.format.toUpperCase())
            .fontSize(10)
            .fontColor($r('app.color.on_brand'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ top: 6, right: 6 })
            .borderRadius(4)
            .backgroundColor('#99000000');
        }
      }
      .width('100%');

      Text(this.record.title ?? '未知书名')
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
      if (this.record.author) {
        Text(this.record.author)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      if (this.metaLine().length > 0) {
        Text(this.metaLine())
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
    }
    .width('100%')
    .padding($r('app.float.card_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .shadow({ radius: 8, color: '#14000000', offsetX: 0, offsetY: 2 })
    .onClick(() => {
      if (this.onTap) {
        this.onTap();
      }
    });
  }
}
