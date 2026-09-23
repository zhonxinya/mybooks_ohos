import { AuthImage } from './AuthImage';

/**
 * 文字区行高与字号（vp / fp）。
 *
 * 3 列网格下卡片内宽只有约 107vp，字号不能再按 2 列时的大小走，
 * 否则一行只放得下五六个汉字，书名基本读不全。
 */
const TITLE_LINE_HEIGHT: number = 18;
const META_LINE_HEIGHT: number = 15;
const TITLE_FONT_SIZE: number = 13;
const META_FONT_SIZE: number = 11;
const LINE_GAP: number = 3;
const COVER_TEXT_GAP: number = 6;
/** 3 列网格封面约宽；用于 sourceSize，避免原图全分辨率解码。 */
const COVER_DECODE_WIDTH_VP: number = 120;
const COVER_DECODE_HEIGHT_VP: number = 171;

/**
 * 网格卡片（3 列封面墙，微信读书那类轻量风格）。
 *
 * 纯封面样式：**不带卡片底色、内边距与阴影**，封面与文字直接落在页面背景上，观感更轻。
 * 封面与页面底色接近时有发丝描边兜底，避免浅色封面"糊"在背景里。
 *
 * 文字不预留空行（曾试过把标题固定占两行来让作者行对齐，但短书名时标题与作者之间会空出整行，
 * 看起来像漏了内容）；标题最多两行、按实际行数自然排布。
 */
@Reusable
@Component
export struct BookGridCard {
  @State title: string = '';
  @State author: string = '';
  @State cover: string = '';
  @State format: string = '';
  @State subtitle: string = '';
  /** 状态角标（如「已入库」）；空串不显示。 */
  @State badge: string = '';
  onTap?: () => void = undefined;
  onLongPress?: () => void = undefined;

  aboutToReuse(params: Record<string, Object>): void {
    this.title = params.title as string;
    this.author = params.author as string;
    this.cover = params.cover as string;
    this.format = params.format as string;
    this.subtitle = params.subtitle as string;
    this.badge = params.badge as string;
    this.onTap = params.onTap as (() => void) | undefined;
    this.onLongPress = params.onLongPress as (() => void) | undefined;
  }

  @Builder
  coverArea() {
    if (this.cover.length > 0) {
      AuthImage({
        url: this.cover,
        imageWidth: '100%',
        imageHeight: '100%',
        decodeWidthVp: COVER_DECODE_WIDTH_VP,
        decodeHeightVp: COVER_DECODE_HEIGHT_VP,
      })
        .width('100%')
        .aspectRatio(0.7);
    } else {
      Column() {
        Text((this.title.length > 0 ? this.title : '?').substring(0, 1))
          .fontSize(26)
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
        if (this.badge.length > 0) {
          // Stack 统一按 TopEnd 对齐，角标要落左上角，所以外面套一层撑满宽度的 Row 把它推到左边
          Row() {
            Text(this.badge)
              .fontSize(9)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.success'))
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .margin({ top: 5, left: 5 })
              .borderRadius(5)
              .backgroundColor($r('app.color.success_light'));
          }
          .width('100%')
          .justifyContent(FlexAlign.Start);
        }
        if (this.format.length > 0) {
          // 角标底色是半透明黑，文字固定白色：`on_brand` 在深色主题下是深色，压在黑底上读不出来
          Text(this.format.toUpperCase())
            .fontSize(9)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .margin({ top: 5, right: 5 })
            .borderRadius(5)
            .backgroundColor('#B3000000');
        }
      }
      .width('100%')
      .borderRadius($r('app.float.cover_radius'))
      // 发丝描边：浅色封面与页面底色接近时也要有一条界线，避免封面整块"浮白"
      .border({ width: 0.5, color: $r('app.color.divider') });

      Column({ space: LINE_GAP }) {
        Text(this.title.length > 0 ? this.title : '未知书名')
          .fontSize(TITLE_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .lineHeight(TITLE_LINE_HEIGHT)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
        if (this.author.length > 0) {
          Text(this.author)
            .fontSize(META_FONT_SIZE)
            .fontColor($r('app.color.text_secondary'))
            .lineHeight(META_LINE_HEIGHT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
        }
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(META_FONT_SIZE)
            .fontColor($r('app.color.text_tertiary'))
            .lineHeight(META_LINE_HEIGHT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%')
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
