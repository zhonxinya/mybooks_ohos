import { AuthImage } from './AuthImage';

/** 文字区行高（vp）：标题占两行位，与作者/进度一起拼成等高的文字块。 */
const TITLE_LINE_HEIGHT: number = 20;
const AUTHOR_LINE_HEIGHT: number = 17;
const SUBTITLE_LINE_HEIGHT: number = 16;
const LINE_GAP: number = 3;
const COVER_TEXT_GAP: number = 8;
/**
 * 文字块最小高度。
 *
 * 只给文字块设下限、**不要**给整张卡片定高：封面高度由 0.7 的宽高比决定（两列布局下约 230vp），
 * 卡片定高必然与它打架——早期写死 `height(220)`，标题/作者/进度就被挤出卡片底色、压在页面背景上。
 * 设下限是为了让网格里每张卡片等高（`Grid` 行高取该行最高项，卡片不等高时底边参差）；
 * 文字不足时留白落在文字块底部，观感等同于多留一点内边距。
 * 用 `constraintSize.minHeight` 而不是 `height`：系统字号放大时文字块要能跟着长高，不能被裁掉。
 */
const TEXT_BLOCK_HEIGHT: number = TITLE_LINE_HEIGHT * 2 + LINE_GAP + AUTHOR_LINE_HEIGHT +
  LINE_GAP + SUBTITLE_LINE_HEIGHT;

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
          .fontSize(30)
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
    Column({ space: COVER_TEXT_GAP }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        this.coverArea();
        if (this.format.length > 0) {
          // 角标底色是半透明黑，文字固定白色：`on_brand` 在深色主题下是深色，压在黑底上读不出来
          Text(this.format.toUpperCase())
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .padding({ left: 6, right: 6, top: 3, bottom: 3 })
            .margin({ top: 6, right: 6 })
            .borderRadius(6)
            .backgroundColor('#B3000000');
        }
      }
      .width('100%')
      .borderRadius($r('app.float.cover_radius'))
      // 发丝描边：浅色封面与卡片底色接近时也要有一条界线，避免封面整块"浮白"
      .border({ width: 0.5, color: $r('app.color.divider') });

      Column({ space: LINE_GAP }) {
        Text(this.title.length > 0 ? this.title : '未知书名')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .lineHeight(TITLE_LINE_HEIGHT)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
        if (this.author.length > 0) {
          Text(this.author)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .lineHeight(AUTHOR_LINE_HEIGHT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
        }
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .lineHeight(SUBTITLE_LINE_HEIGHT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
        }
      }
      .width('100%')
      .constraintSize({ minHeight: TEXT_BLOCK_HEIGHT })
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%')
    .padding($r('app.float.card_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .border({ width: 0.5, color: $r('app.color.divider') })
    .shadow({ radius: 6, color: '#0F000000', offsetX: 0, offsetY: 2 })
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
