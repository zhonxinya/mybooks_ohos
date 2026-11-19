import { MdBlock, MdInline, mdParseBlocks } from '../services/MdParse';

/**
 * AI 回复的轻量 Markdown 渲染（解析在 services/MdParse，可离线回归）。
 * 流式更新：content 每次变化整体重解析——文本量小（KB 级），开销可忽略。
 */
@Component
export struct MarkdownText {
  @Prop @Watch('reparse') content: string = '';
  @State blocks: MdBlock[] = [];

  aboutToAppear(): void {
    this.reparse();
  }

  reparse(): void {
    this.blocks = mdParseBlocks(this.content);
  }

  private headSize(level: number): number {
    if (level === 1) { return 19; }
    if (level === 2) { return 17; }
    if (level === 3) { return 16; }
    return 15;
  }

  @Builder
  inlineText(segs: MdInline[]) {
    Text() {
      ForEach(segs, (seg: MdInline) => {
        Span(seg.text)
          .fontWeight(seg.style === 1 ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(seg.style === 4 ? FontStyle.Italic : FontStyle.Normal)
          .fontFamily(seg.style === 2 ? 'monospace' : undefined)
          .fontColor(seg.style === 2 || seg.style === 3 ? $r('app.color.brand_primary') : undefined)
          .decoration({
            type: seg.style === 3 ? TextDecorationType.Underline : TextDecorationType.None,
            color: $r('app.color.brand_primary'),
          });
      }, (seg: MdInline, idx: number) => `${idx}-${seg.style}-${seg.text}`);
    }
    .fontSize(15)
    .lineHeight(23)
    .fontColor($r('app.color.text_primary'))
    .textAlign(TextAlign.Start)
    .width('100%');
  }

  @Builder
  blockView(block: MdBlock, index: number) {
    if (block.kind === 'h') {
      Text() {
        ForEach(block.segs[0], (seg: MdInline) => {
          Span(seg.text);
        }, (seg: MdInline, idx: number) => `${idx}-${seg.text}`);
      }
      .fontSize(this.headSize(block.level))
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.text_primary'))
      .lineHeight(this.headSize(block.level) + 6)
      .margin({ top: index === 0 ? 0 : 8 })
      .width('100%');
    } else if (block.kind === 'p') {
      Column({ space: 2 }) {
        ForEach(block.segs, (line: MdInline[], idx: number) => {
          this.inlineText(line);
        }, (line: MdInline[], idx: number) => `${idx}-${line.length}`);
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%');
    } else if (block.kind === 'ul' || block.kind === 'ol') {
      Column({ space: 4 }) {
        ForEach(block.segs, (item: MdInline[], idx: number) => {
          Row({ space: 6 }) {
            Text(block.kind === 'ul' ? '•' : `${idx + 1}.`)
              .fontSize(15)
              .fontColor($r('app.color.text_secondary'))
              .width(block.kind === 'ul' ? 12 : 22);
            Column() {
              this.inlineText(item);
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start);
          }
          .alignItems(VerticalAlign.Top)
          .width('100%');
        }, (item: MdInline[], idx: number) => `${idx}-${item.length}`);
      }
      .width('100%');
    } else if (block.kind === 'quote') {
      Row({ space: 8 }) {
        Divider()
          .vertical(true)
          .strokeWidth(3)
          .color($r('app.color.divider'))
          .height('100%');
        Column({ space: 2 }) {
          ForEach(block.segs, (line: MdInline[], idx: number) => {
            this.inlineText(line);
          }, (line: MdInline[], idx: number) => `${idx}-${line.length}`);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);
      }
      .width('100%')
      .padding({ top: 2, bottom: 2 });
    } else if (block.kind === 'code') {
      Scroll() {
        Text(block.raw)
          .fontSize(13)
          .fontFamily('monospace')
          .lineHeight(20)
          .fontColor($r('app.color.text_primary'))
          .padding(10)
          .textAlign(TextAlign.Start);
      }
      .scrollable(ScrollDirection.Horizontal)
      .width('100%')
      .backgroundColor($r('app.color.page_background'))
      .borderRadius(8);
    } else if (block.kind === 'table') {
      Column() {
        ForEach(block.rows, (row: string[], ri: number) => {
          Row() {
            ForEach(row, (cell: string, ci: number) => {
              Text(cell)
                .fontSize(13)
                .fontWeight(ri === 0 ? FontWeight.Bold : FontWeight.Normal)
                .fontColor($r('app.color.text_primary'))
                .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                .layoutWeight(1)
                .maxLines(3)
                .textOverflow({ overflow: TextOverflow.Ellipsis });
            }, (cell: string, ci: number) => `${ci}-${cell}`);
          }
          .width('100%')
          .backgroundColor(ri === 0 ? $r('app.color.page_background') : Color.Transparent);
        }, (row: string[], ri: number) => `${ri}-${row.length}`);
      }
      .width('100%')
      .borderRadius(8)
      .clip(true)
      .border({ width: 1, color: $r('app.color.divider') });
    } else if (block.kind === 'hr') {
      Divider()
        .strokeWidth(1)
        .color($r('app.color.divider'))
        .margin({ top: 6, bottom: 6 });
    }
  }

  build() {
    Column({ space: 8 }) {
      ForEach(this.blocks, (block: MdBlock, index: number) => {
        this.blockView(block, index);
      }, (block: MdBlock, index: number) => `${index}-${block.kind}-${block.raw.length}-${block.segs.length}`);
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }
}
