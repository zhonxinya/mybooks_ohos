import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ReaderAnnotation,
  ReaderBlock,
  READER_DEFAULT_FONT_FAMILY,
  ReaderBlockKind,
  ReaderTheme,
} from '../model/ReaderTypes';
import { ReaderPalette } from '../model/ReaderPalette';
import { PageLayout, PageMetrics, ReaderPage } from '../engine/PageLayout';
import { LazyDataSource } from './LazyDataSource';
import { ReaderBattery } from './ReaderBattery';
import { ReaderClock } from './ReaderClock';

const TAG: string = 'ReaderPageView';
/** 划线渲染片段：`marked` 的片段画高亮底色，其余保持原样（切分不改变文字与顺序）。 */
interface ReaderTextSegment {
  text: string;
  marked: boolean;
}
/** 菜单项 id：自定义项用它区分点击（`TextMenuItemId.of`）。 */
const MARK_MENU_ID: string = 'reader_mark';
const UNMARK_MENU_ID: string = 'reader_unmark';
const PARAGRAPH_SPACING: number = 12;
/** 阅读区顶部章节名占用的高度（vp），需与分页预算里的扣减保持一致。 */
export const PAGE_HEADER_SPACE: number = 26;
/** 底部分隔线 + 页脚（左书名 / 右页码）占用的高度（vp），保持小高度。 */
export const PAGE_FOOTER_SPACE: number = 26;

/**
 * 单页视图（分页阅读器用）：按块渲染文本段落与插图。
 *
 * 页码与位移都走 `@Prop`：翻页拖拽时父组件每帧改 `offsetX`，子组件必须能可靠重建，
 * 而 `@Builder` 按值传参的刷新语义不适合这种高频更新。
 * `pages` 用普通成员按引用传递，避免每帧深拷贝页面内容。
 */
@Component
export struct ReaderPageView {
  pages: LazyDataSource<ReaderPage> = new LazyDataSource<ReaderPage>();
  @Prop pageIndex: number = 0;
  @Prop pageCount: number = 0;
  /**
   * 分页令牌：`pages` 是普通成员（避免每帧深拷贝），切章后页码可能不变（如两章都停在第 1 页），
   * 仅靠 `pageIndex` 无法触发重建，会显示上一章的陈旧内容。令牌随每次分页变化，用它强制刷新。
   */
  @Prop pageToken: number = 0;
  @Prop offsetX: number = 0;
  @Prop layerOrder: number = 0;
  @Prop fontSize: number = 18;
  @Prop lineHeight: number = 1.6;
  @Prop theme: ReaderTheme = ReaderTheme.LIGHT;
  @Prop horizontalSpace: number = 22;
  @Prop topSpace: number = 44;
  @Prop bottomSpace: number = 32;
  /** 正文可用区（与分页预算一致），用于按宽高比换算图片高度。 */
  @Prop pageWidthVp: number = 0;
  @Prop pageHeightVp: number = 0;
  /** 顶部章节名（阅读区顶部常显）。 */
  @Prop chapterTitle: string = '';
  /** 底部左侧书名。 */
  @Prop bookTitle: string = '';
  /** 页脚电量（-1 表示未知，不渲染）。 */
  @Prop batteryLevel: number = -1;
  @Prop batteryCharging: boolean = false;
  /** 正文字体家族名（空 = 系统默认；由宿主解析并用 UIContext 注册后传入）。 */
  @Prop fontFamily: string = '';
  /**
   * 选词模式：正文 `Text` 设为可选中（长按选中 → 拖手柄 → 复制）。
   * 注意这会让 `Text` 吃掉点按与拖动，父组件的翻页手势收不到事件，所以只在选词模式下开。
   */
  @Prop selectable: boolean = false;
  /** 当前章序号（批注锚点的一部分）。 */
  @Prop chapterIndex: number = 0;
  /** 全部划线批注（本页只画落在本页块里的那些）。 */
  @Prop annotations: ReaderAnnotation[] = [];
  /** 命中「划线」菜单项：把（段落序号, 原文）交给宿主记录。 */
  onMark: (paragraphIndex: number, text: string) => void = (_p: number, _t: string): void => {};
  /** 命中「取消划线」：删除同段落里原文匹配（或该段全部）的划线。 */
  onUnmark: (paragraphIndex: number, text: string) => void = (_p: number, _t: string): void => {};

  build() {
    Column() {
      // 阅读区顶部：章节名（比页脚字号稍大）+ 右上角时间（与章节名齐平）
      Row({ space: 8 }) {
        Text(this.chapterTitle)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(ReaderPalette.hintColor(this.theme))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        ReaderClock({ theme: this.theme });
      }
      .width('100%')
      .height(PAGE_HEADER_SPACE)
      .alignItems(VerticalAlign.Center);

      Column({ space: PARAGRAPH_SPACING }) {
        ForEach(this.pageBlocks(), (block: ReaderBlock, index: number) => {
          if (block.kind === ReaderBlockKind.IMAGE) {
            this.imageBlock(block);
          } else {
            this.readLine(block);
          }
        // key 必须含分页令牌：切章后同页码同下标会与新内容撞 key，ArkUI 会复用旧节点
        // （正文列表 → 图片页 时表现为仍显示上一章的旧文字）
        }, (block: ReaderBlock, index: number) => `${this.pageToken}_${this.pageIndex}_${index}`);
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .clip(true);

      // 底部分隔线 + 页脚：左侧书名、右侧电量与页码；整块高度小
      Divider()
        .color(ReaderPalette.dividerColor(this.theme))
        .strokeWidth(0.5);
      Row({ space: 10 }) {
        Text(this.bookTitle.length > 0 ? this.bookTitle : ' ')
          .fontSize(10)
          .fontColor(ReaderPalette.hintColor(this.theme))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        ReaderBattery({
          theme: this.theme,
          level: this.batteryLevel,
          charging: this.batteryCharging,
        });
        if (this.pageCount >= 1) {
          Text(`${this.pageIndex + 1} / ${this.pageCount}`)
            .fontSize(10)
            .fontColor(ReaderPalette.hintColor(this.theme));
        }
      }
      .width('100%')
      .height(PAGE_FOOTER_SPACE)
      .alignItems(VerticalAlign.Center);    }
    .width('100%')
    .height('100%')
    .padding({
      left: this.horizontalSpace,
      right: this.horizontalSpace,
      top: this.topSpace,
      bottom: this.bottomSpace,
    })
    .translate({ x: this.offsetX })
    .zIndex(this.layerOrder)
    .backgroundColor(ReaderPalette.pageBackground(this.theme))
    .clip(true);
  }

  /** 插图：按宽高比占位（与分页时同一个公式），并按显示尺寸解码避免大图整幅解码。 */
  /**
   * 一行正文：没有划线时就是普通 `Text`（快路径，与加批注前完全一致）；
   * 有划线时改用 `Span` 逐段渲染，命中段画高亮底色。
   */
  @Builder
  readLine(block: ReaderBlock) {
    if (this.hasMark(block)) {
      Text() {
        ForEach(this.segmentsOf(block), (segment: ReaderTextSegment) => {
          Span(segment.text)
            .textBackgroundStyle(segment.marked ?
              { color: ReaderPalette.annotationColor(this.theme), radius: 2 } :
              { color: Color.Transparent, radius: 0 });
        }, (segment: ReaderTextSegment, index: number) => `${index}_${segment.marked}`);
      }
      .fontSize(this.fontSize)
      .lineHeight(this.lineHeight * this.fontSize)
      .fontColor(ReaderPalette.textColor(this.theme))
      .fontFamily(this.fontFamily.length > 0 ? this.fontFamily : READER_DEFAULT_FONT_FAMILY)
      .textAlign(TextAlign.JUSTIFY)
      .width('100%')
      .copyOption(this.selectable ? CopyOptions.InApp : CopyOptions.None)
      .editMenuOptions(this.menuFor(block));
    } else {
      Text(block.text)
        .fontSize(this.fontSize)
        .lineHeight(this.lineHeight * this.fontSize)
        .fontColor(ReaderPalette.textColor(this.theme))
        .fontFamily(this.fontFamily.length > 0 ? this.fontFamily : READER_DEFAULT_FONT_FAMILY)
        // 两端对齐：否则每行右侧参差，视觉上右边留白明显大于左边
        .textAlign(TextAlign.JUSTIFY)
        .width('100%')
        // 只在选词模式下可选中：可选中正文与父组件的拖动翻页无法共存
        .copyOption(this.selectable ? CopyOptions.InApp : CopyOptions.None)
        .editMenuOptions(this.menuFor(block));
    }
  }

  /** 文案：该块所在章的划线清单。 */
  private marksOf(block: ReaderBlock): ReaderAnnotation[] {
    const out: ReaderAnnotation[] = [];
    for (let i = 0; i < this.annotations.length; i++) {
      const item: ReaderAnnotation = this.annotations[i];
      if (item.chapterIndex === this.chapterIndex && item.paragraphIndex === block.paragraphIndex &&
        item.text.length > 0 && block.text.indexOf(item.text) >= 0) {
        out.push(item);
      }
    }
    return out;
  }

  private hasMark(block: ReaderBlock): boolean {
    return this.marksOf(block).length > 0;
  }

  /**
   * 把块文本按划线切成片段。
   *
   * 划线按原文定位（见 `ReaderAnnotation`），同一段落里多条划线按起点排序，重叠时后一条被裁掉，
   * 保证片段既不重叠也不丢字。找不到的划线直接跳过（段落被分页器切开时，碎片可能落在相邻页）。
   */
  private segmentsOf(block: ReaderBlock): ReaderTextSegment[] {
    const marks: ReaderAnnotation[] = this.marksOf(block);
    if (marks.length === 0) {
      return [];
    }
    const starts: number[] = [];
    const ends: number[] = [];
    for (let i = 0; i < marks.length; i++) {
      const at: number = block.text.indexOf(marks[i].text);
      if (at < 0) {
        continue;
      }
      starts.push(at);
      ends.push(at + marks[i].text.length);
    }
    // 按起点排序（插入排序，条数极少）
    for (let i = 1; i < starts.length; i++) {
      const sValue: number = starts[i];
      const eValue: number = ends[i];
      let j: number = i - 1;
      while (j >= 0 && starts[j] > sValue) {
        starts[j + 1] = starts[j];
        ends[j + 1] = ends[j];
        j--;
      }
      starts[j + 1] = sValue;
      ends[j + 1] = eValue;
    }
    const segments: ReaderTextSegment[] = [];
    let cursor: number = 0;
    for (let i = 0; i < starts.length; i++) {
      const start: number = Math.max(starts[i], cursor);
      const end: number = Math.max(ends[i], start);
      if (end <= cursor) {
        continue;
      }
      if (start > cursor) {
        segments.push({ text: block.text.substring(cursor, start), marked: false });
      }
      segments.push({ text: block.text.substring(start, end), marked: true });
      cursor = end;
    }
    if (cursor < block.text.length) {
      segments.push({ text: block.text.substring(cursor), marked: false });
    }
    return segments;
  }

  /**
   * 正文的编辑菜单：在系统默认项（复制/全选/翻译/搜索）后面追加划线项。
   * `onMenuItemClick` 才拿得到选中范围，所以菜单构建时只能按「这一块有没有划线」决定给哪一项。
   */
  private menuFor(block: ReaderBlock): EditMenuOptions {
    return {
      onCreateMenu: (menuItems: Array<TextMenuItem>): Array<TextMenuItem> => {
        const items: Array<TextMenuItem> = menuItems.slice();
        items.push({ content: '划线', id: TextMenuItemId.of(MARK_MENU_ID) });
        if (this.hasMark(block)) {
          items.push({ content: '取消划线', id: TextMenuItemId.of(UNMARK_MENU_ID) });
        }
        return items;
      },
      onMenuItemClick: (menuItem: TextMenuItem, range: TextRange): boolean => {
        const start: number = range.start === undefined ? 0 : range.start;
        const end: number = range.end === undefined ? 0 : range.end;
        const selected: string = end > start ? block.text.substring(start, end) : '';
        // 自定义项只能靠 `TextMenuItemId.equals` 判定：它的 `of()` 造出来的对象没有可读的字符串
        if (menuItem.id.equals(TextMenuItemId.of(UNMARK_MENU_ID))) {
          this.onUnmark(block.paragraphIndex, selected);
          return true;
        }
        if (menuItem.id.equals(TextMenuItemId.of(MARK_MENU_ID))) {
          this.onMark(block.paragraphIndex, selected);
          return true;
        }
        return false;
      },
    };
  }

  @Builder
  imageBlock(block: ReaderBlock) {
    Image('file://' + block.src)
      .width('100%')
      .height(this.imageHeightVp(block))
      .objectFit(ImageFit.Contain)
      .sourceSize({
        width: Math.max(1, Math.round(this.vpToPx(this.pageWidthVp))),
        height: Math.max(1, Math.round(this.vpToPx(this.imageHeightVp(block)))),
      })
      .backgroundColor(ReaderPalette.imageBackground(this.theme))
      .borderRadius(4)
      .onError(() => {
        // 图片损坏时留白即可，不阻断阅读
        hilog.warn(0x0000, TAG, 'image load failed: %{public}s', block.src);
      });
  }

  private pageBlocks(): ReaderBlock[] {
    const page: ReaderPage | undefined = this.pages.getData(this.pageIndex);
    return page === undefined ? [] : page.blocks;
  }

  private imageHeightVp(block: ReaderBlock): number {
    const metrics: PageMetrics = {
      widthVp: this.pageWidthVp,
      widthPx: this.vpToPx(this.pageWidthVp),
      heightPx: this.vpToPx(this.pageHeightVp),
      fontSize: this.fontSize,
      lineHeight: this.lineHeight,
      paragraphSpacingPx: 0,
    };
    return this.pxToVp(PageLayout.imageHeightPx(block, metrics));
  }

  private vpToPx(value: number): number {
    try {
      return this.getUIContext().vp2px(value);
    } catch (_error) {
      return value;
    }
  }

  private pxToVp(value: number): number {
    try {
      return this.getUIContext().px2vp(value);
    } catch (_error) {
      return value;
    }
  }
}
