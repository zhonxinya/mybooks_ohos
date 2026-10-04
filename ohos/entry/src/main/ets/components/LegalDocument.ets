/** 法务文档的章节结构：标题 + 若干段落，供隐私政策 / 用户协议 / 开源许可页共用。 */
export interface LegalSection {
  title: string;
  paragraphs: string[];
}

/**
 * 纯文本法务文档渲染器：按章节顺序渲染标题与段落。
 * 三个页面内容都是「标题 + 段落」的固定结构，故共用本组件，避免各页重复写样式。
 */
@Component
export struct LegalDocument {
  sections: LegalSection[] = [];

  build() {
    Scroll() {
      Column({ space: 18 }) {
        ForEach(this.sections, (section: LegalSection) => {
          Column({ space: 8 }) {
            Text(section.title)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%');
            ForEach(section.paragraphs, (paragraph: string) => {
              Text(paragraph)
                .fontSize(13)
                .lineHeight(21)
                .fontColor($r('app.color.text_secondary'))
                .width('100%');
            }, (paragraph: string) => paragraph);
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start);
        }, (section: LegalSection) => section.title);
      }
      .width('100%')
      .padding($r('app.float.page_padding'));
    }
    .width('100%')
    .layoutWeight(1)
    // 内容不满一屏时避免 Scroll 垂直居中
    .align(Alignment.Top)
    .scrollBar(BarState.Auto);
  }
}
