import { hilog } from '@kit.PerformanceAnalysisKit';
import { ReaderBlock, ReaderBlockKind, ReaderTheme } from '../model/ReaderTypes';
import { ReaderPalette } from '../model/ReaderPalette';
import { PageLayout, PageMetrics, ReaderPage } from '../engine/PageLayout';
import { LazyDataSource } from './LazyDataSource';
import { ReaderBattery } from './ReaderBattery';

const TAG: string = 'ReaderPageView';
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

  build() {
    Column() {
      // 阅读区顶部：章节名（比页脚字号稍大）
      if (this.chapterTitle.length > 0) {
        Text(this.chapterTitle)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(ReaderPalette.hintColor(this.theme))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .height(PAGE_HEADER_SPACE);
      }

      Column({ space: PARAGRAPH_SPACING }) {
        ForEach(this.pageBlocks(), (block: ReaderBlock, index: number) => {
          if (block.kind === ReaderBlockKind.IMAGE) {
            this.imageBlock(block);
          } else {
            Text(block.text)
              .fontSize(this.fontSize)
              .lineHeight(this.lineHeight * this.fontSize)
              .fontColor(ReaderPalette.textColor(this.theme))
              // 两端对齐：否则每行右侧参差，视觉上右边留白明显大于左边
              .textAlign(TextAlign.JUSTIFY)
              .width('100%');
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
