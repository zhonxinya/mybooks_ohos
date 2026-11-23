import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { collectLinks, linkHost, MdBlock, MdInline, mdAppendCaret, mdParseBlocks } from '../services/MdParse';
import { ExternalLinkOpener } from '../services/ExternalLinkOpener';

/**
 * AI 回复的轻量 Markdown 渲染（解析在 services/MdParse，可离线回归）。
 * 流式更新：content 每次变化整体重解析——文本量小（KB 级），开销可忽略。
 */
@Component
export struct MarkdownText {
  @Prop @Watch('reparse') content: string = '';
  /** 打字光标（#1622）：showCaret=流式期在尾行注入光标 seg；caretOn=闪烁相位（只切颜色）。 */
  @Prop @Watch('reparse') showCaret: boolean = false;
  @Prop caretOn: boolean = false;
  @State blocks: MdBlock[] = [];

  aboutToAppear(): void {
    this.reparse();
  }

  reparse(): void {
    this.blocks = mdParseBlocks(this.content);
    if (this.showCaret) {
      mdAppendCaret(this.blocks);
    }
  }

  /** 块尾行是否带注入的光标 seg（决定闪烁相位是否进 key）。 */
  private tailHasCaret(block: MdBlock): boolean {
    if (block.segs.length === 0) {
      return false;
    }
    const tail: MdInline[] = block.segs[block.segs.length - 1];
    return tail.length > 0 && tail[tail.length - 1].style === 5;
  }

  private headSize(level: number): number {
    if (level === 1) { return 19; }
    if (level === 2) { return 17; }
    if (level === 3) { return 16; }
    return 15;
  }

  /** 打开外链：统一走 ExternalLinkOpener（协议白名单内建），失败文案直接 toast。 */
  private openLink(url: string): void {
    if (url.length === 0) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ExternalLinkOpener.open(context, url).then((error: string) => {
      if (error.length > 0) {
        try {
          this.getUIContext().getPromptAction().showToast({ message: error });
        } catch (_error) {
          // 提示失败不影响已发起的跳转
        }
      }
    });
  }

  @Builder
  inlineText(segs: MdInline[]) {
    Text() {
      ForEach(segs, (seg: MdInline) => {
        Span(seg.text)
          .fontWeight(seg.style === 1 ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(seg.style === 4 ? FontStyle.Italic : FontStyle.Normal)
          .fontFamily(seg.style === 2 ? 'monospace' : undefined)
          .fontColor(seg.style === 5 ? (this.caretOn ? $r('app.color.brand_primary') : Color.Transparent) :
            (seg.style === 2 || seg.style === 3 ? $r('app.color.brand_primary') : undefined))
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

  /**
   * 可点链接清单（#1511）：Span 无点击事件，把段内链接去重后列成可点行，
   * 标题=链接文字、副标=主机名，点击走 ExternalLinkOpener（协议白名单内建）。
   */
  @Builder
  linkList(lines: MdInline[][]) {
    Column({ space: 4 }) {
      ForEach(collectLinks(lines), (seg: MdInline, idx: number) => {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.link'))
            .fontSize(13)
            .fontColor([$r('app.color.brand_primary')]);
          Column({ space: 1 }) {
            Text(seg.text)
              .fontSize(13)
              .fontColor($r('app.color.brand_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
            Text(linkHost(seg.href ?? ''))
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1);
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .borderRadius(6)
        .backgroundColor($r('app.color.page_background'))
        .onClick(() => this.openLink(seg.href ?? ''));
      }, (seg: MdInline, idx: number) => `${idx}-${seg.href}`);
    }
    .alignItems(HorizontalAlign.Start)
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
        // 行内链接收成分离可点清单（#1511）：Span 无点击事件，段落尾给可点条目
        if (collectLinks(block.segs).length > 0) {
          this.linkList(block.segs);
        }
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
              // 列表项常带来源链接：清单跟在该条目正下方
              if (collectLinks([item]).length > 0) {
                this.linkList([item]);
              }
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
      CodeBlockView({ raw: block.raw });
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
        // key 必须覆盖「尾行段数 + 闪烁相位」：光标 seg 是解析后注入的，不改 raw.length/segs.length——
        // 若 key 不含它，末块前移时旧块 key 不变会被 ForEach 复用，旧块（含光标）卡屏，
        // 流式全程每个历史末块都钉上一个光标（#1622 上板实测）；而 caretOn 不进带光标的
        // 末块 key，闪烁时子树不重建、Span 颜色表达式不重估，光标就不眨。
        // 重建范围仅末段（宽度恒占、布局不变），无旧实现的回绕抖动。
      }, (block: MdBlock, index: number) => `${index}-${block.kind}-${block.raw.length}-${block.segs.length}` +
        `-${block.segs.length > 0 ? block.segs[block.segs.length - 1].length : 0}` +
        `${this.caretOn && this.tailHasCaret(block) ? '-c' : ''}`);
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }
}

/**
 * 代码块（#1511）：横向滚动 + 一键复制。copied 是本组件局部 @State，
 * 复制反馈只重绘这一小块，不牵动整篇 Markdown。
 */
@Component
struct CodeBlockView {
  @Prop raw: string = '';
  @State copied: boolean = false;

  private async doCopy(): Promise<void> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.raw);
      await pasteboard.getSystemPasteboard().setData(data);
      this.copied = true;
      setTimeout((): void => {
        this.copied = false;
      }, 1500);
    } catch (_error) {
      // 系统剪贴板繁忙时静默，不弹错误打扰阅读
    }
  }

  build() {
    Column() {
      Row() {
        Blank();
        Text(this.copied ? '已复制' : '复制')
          .fontSize(11)
          .fontColor(this.copied ? $r('app.color.brand_primary') : $r('app.color.text_secondary'))
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick(() => this.doCopy());
      }
      .width('100%');
      Scroll() {
        Text(this.raw)
          .fontSize(13)
          .fontFamily('monospace')
          .lineHeight(20)
          .fontColor($r('app.color.text_primary'))
          .padding({ left: 10, right: 10, bottom: 10 })
          .textAlign(TextAlign.Start);
      }
      .scrollable(ScrollDirection.Horizontal)
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.page_background'))
    .borderRadius(8);
  }
}
