export interface SiteStatsData {
  title: string;
  books: number;
  tags: number;
  authors: number;
  series: number;
  publishers: number;
  audiobooks: number;
  version: string;
}

@Component
export struct SiteStatsCard {
  stats: SiteStatsData = {
    title: '', books: 0, tags: 0, authors: 0, series: 0, publishers: 0, audiobooks: 0, version: '',
  };

  @Builder
  statCell(label: string, value: number) {
    Column({ space: 4 }) {
      Text(`${value}`)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'));
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'));
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center);
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text(this.stats.title.length > 0 ? this.stats.title : 'Talebook')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        if (this.stats.version.length > 0) {
          Text(this.stats.version)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'));
        }
      }
      .width('100%');

      Row() {
        this.statCell('书籍', this.stats.books);
        this.statCell('标签', this.stats.tags);
        this.statCell('作者', this.stats.authors);
      }
      .width('100%');

      Row() {
        this.statCell('丛书', this.stats.series);
        this.statCell('出版社', this.stats.publishers);
        this.statCell('有声', this.stats.audiobooks);
      }
      .width('100%');
    }
    .width('100%')
    .padding($r('app.float.card_padding'))
    .margin({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), bottom: 8 })
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }
}
