import { ReaderBlock, ReaderBlockKind } from '../model/ReaderTypes';

/**
 * 分页：把一章的正文块（文本段落 + 插图）按「正文可用高度」切成一页页。
 *
 * - 测量走宿主注入的 `MeasureTextHeight`（ArkUI `measureTextSize` 不能在辅助线程调用，
 *   所以分页留在 UI 线程，只对**当前章**做，且按章缓存）；
 * - 文本块过长会跨页切分：中文单段动辄数千字，不切就会出现截断或溢出；
 *   图片块不切分，整张放到能容纳它的那一页；
 * - 切分用「按高度比例估算 + 少量线性校正」，把测量次数压在常数级。
 */
const MAX_SPLIT_ATTEMPTS: number = 3;
/** 取不到图片尺寸时的默认宽高比（宽/高）。 */
const DEFAULT_IMAGE_ASPECT: number = 4 / 3;
/** 单张图片最多占页面的比例，避免超长图把一页撑满后无法与文字共存。 */
const MAX_IMAGE_PAGE_RATIO: number = 0.85;

export interface ReaderPage {
  index: number;
  /** 该页第一个块对应的文本段落序号，用于进度上报与位置恢复。 */
  firstParagraph: number;
  /** 该页的正文块（文本片段 + 图片）。 */
  blocks: ReaderBlock[];
}

export interface PageMetrics {
  /** 正文可用宽度（vp）。 */
  widthVp: number;
  /** 正文可用宽度（px），用于按宽高比换算图片高度。 */
  widthPx: number;
  /** 正文可用高度（px，与测量返回值同单位）。 */
  heightPx: number;
  fontSize: number;
  lineHeight: number;
  /** 段间距（px），需与渲染时的行距设置一致。 */
  paragraphSpacingPx: number;
}

/** 测量一段文本在给定约束下占用的高度（px）。 */
export type MeasureTextHeight = (text: string, fontSize: number, widthVp: number, lineHeight: number) => number;

export class PageLayout {
  static paginate(blocks: ReaderBlock[], metrics: PageMetrics, measure: MeasureTextHeight): ReaderPage[] {
    const pages: ReaderPage[] = [];
    if (blocks.length === 0 || metrics.heightPx <= 0 || metrics.widthVp <= 0) {
      return pages;
    }
    let pageBlocks: ReaderBlock[] = [];
    let usedPx: number = 0;
    let firstParagraph: number = 0;
    for (let i = 0; i < blocks.length; i++) {
      const block: ReaderBlock = blocks[i];
      if (pageBlocks.length === 0) {
        firstParagraph = block.paragraphIndex;
      }
      if (block.kind === ReaderBlockKind.IMAGE) {
        const height: number = PageLayout.imageHeightPx(block, metrics);
        const gap: number = pageBlocks.length > 0 ? metrics.paragraphSpacingPx : 0;
        if (usedPx + gap + height > metrics.heightPx && pageBlocks.length > 0) {
          PageLayout.flush(pages, pageBlocks, firstParagraph);
          pageBlocks = [];
          usedPx = 0;
          firstParagraph = block.paragraphIndex;
        }
        pageBlocks.push(block);
        usedPx += (pageBlocks.length > 1 ? metrics.paragraphSpacingPx : 0) + height;
        continue;
      }
      let rest: string = block.text;
      while (rest.length > 0) {
        const gap: number = pageBlocks.length > 0 ? metrics.paragraphSpacingPx : 0;
        const available: number = metrics.heightPx - usedPx - gap;
        const fullHeight: number = measure(rest, metrics.fontSize, metrics.widthVp, metrics.lineHeight);
        if (fullHeight <= available) {
          pageBlocks.push(PageLayout.textBlock(rest, block.paragraphIndex));
          usedPx += gap + fullHeight;
          rest = '';
          break;
        }
        const head: string = PageLayout.headThatFits(rest, available, metrics, measure);
        if (head.length === 0) {
          // 空页也放不下一行（可用高度小于一行）：强制切 1 字，保证循环一定前进
          if (pageBlocks.length === 0) {
            pageBlocks.push(PageLayout.textBlock(rest.substring(0, 1), block.paragraphIndex));
            rest = rest.substring(1);
          }
          PageLayout.flush(pages, pageBlocks, firstParagraph);
          pageBlocks = [];
          usedPx = 0;
          firstParagraph = block.paragraphIndex;
          continue;
        }
        pageBlocks.push(PageLayout.textBlock(head, block.paragraphIndex));
        rest = rest.substring(head.length);
        PageLayout.flush(pages, pageBlocks, firstParagraph);
        pageBlocks = [];
        usedPx = 0;
        // 续页仍属于同一段：进度恢复时会定位到同一段的任意一页
        firstParagraph = block.paragraphIndex;
      }
    }
    PageLayout.flush(pages, pageBlocks, firstParagraph);
    return pages;
  }

  /** 图片在页面中的高度（px）：按满宽等比，并限制单图最多占页面 85%。 */
  static imageHeightPx(block: ReaderBlock, metrics: PageMetrics): number {
    const aspect: number = block.aspect > 0 ? block.aspect : DEFAULT_IMAGE_ASPECT;
    const natural: number = metrics.widthPx / aspect;
    const capped: number = Math.min(natural, metrics.heightPx * MAX_IMAGE_PAGE_RATIO);
    // 极宽图（如细横幅）至少留一点高度，避免看起来像分割线
    return Math.max(metrics.widthPx * 0.15, capped);
  }

  /** 找到包含指定段落下标的页（滚动模式的位置 → 分页模式的位置）。 */
  static pageForParagraph(pages: ReaderPage[], paragraphIndex: number): number {
    let found: number = 0;
    for (let i = 0; i < pages.length; i++) {
      if (pages[i].firstParagraph <= paragraphIndex) {
        found = i;
      } else {
        break;
      }
    }
    return found;
  }

  private static textBlock(text: string, paragraphIndex: number): ReaderBlock {
    return {
      kind: ReaderBlockKind.TEXT,
      text: text,
      src: '',
      alt: '',
      aspect: 0,
      paragraphIndex: paragraphIndex,
    };
  }

  private static flush(pages: ReaderPage[], blocks: ReaderBlock[], firstParagraph: number): void {
    if (blocks.length === 0) {
      return;
    }
    pages.push({ index: pages.length, firstParagraph: firstParagraph, blocks: blocks.slice() });
  }

  /** 取「能放进 availablePx 的最大前缀」；返回空串表示可用高度不足一行。 */
  private static headThatFits(text: string, availablePx: number, metrics: PageMetrics,
    measure: MeasureTextHeight): string {
    if (availablePx <= 0 || text.length === 0) {
      return '';
    }
    const fullHeight: number = measure(text, metrics.fontSize, metrics.widthVp, metrics.lineHeight);
    if (fullHeight <= availablePx) {
      return text;
    }
    let count: number = Math.floor(text.length * availablePx / fullHeight);
    if (count < 1) {
      count = 1;
    }
    if (count > text.length - 1) {
      count = text.length - 1;
    }
    let lastFitting: number = 0;
    for (let attempt = 0; attempt < MAX_SPLIT_ATTEMPTS; attempt++) {
      const height: number = measure(text.substring(0, count), metrics.fontSize, metrics.widthVp, metrics.lineHeight);
      if (height <= availablePx) {
        lastFitting = count;
        const bigger: number = Math.min(text.length - 1, count + Math.max(1, Math.floor((text.length - count) / 2)));
        if (bigger <= count) {
          break;
        }
        count = bigger;
        continue;
      }
      const smaller: number = Math.floor(count * availablePx / height);
      count = smaller >= count ? count - 1 : smaller;
      if (count < 1) {
        break;
      }
    }
    if (lastFitting > 0) {
      return text.substring(0, lastFitting);
    }
    return count >= 1 ? text.substring(0, count) : '';
  }
}
