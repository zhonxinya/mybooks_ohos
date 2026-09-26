import { ReaderBlock, ReaderBlockKind } from '../model/ReaderTypes';

/**
 * 分页：把一章的正文块（文本段落 + 插图）按「正文可用高度」切成一页页。
 *
 * - 测量走宿主注入的 `MeasureTextHeight`（ArkUI `measureTextSize` 不能在辅助线程调用，
 *   所以分页留在 UI 线程，只对**当前章**做，且按章缓存）；
 * - 长章节用 `PagePager` **分片推进**：先同步推进一小段让首屏可见，其余按帧切片补完，
 *   避免一次测量把一帧拖到几百毫秒（实测中文长章一次分页约 0.8–1.5s）；
 * - 文本块过长会跨页切分；图片块不切分，整张放到能容纳它的那一页；
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

/**
 * 取「能放进 availablePx 的最大前缀」；返回空串表示可用高度不足一行。
 * `fullHeight` 由调用方已经测过，这里不再对整段重复测量。
 */
function headThatFits(text: string, availablePx: number, metrics: PageMetrics,
  measure: MeasureTextHeight, fullHeight: number): string {
  if (availablePx <= 0 || text.length === 0 || fullHeight <= 0) {
    return '';
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

/** 图片在页面中的高度（px）：按满宽等比，并限制单图最多占页面 85%。 */
export function imageHeightPx(block: ReaderBlock, metrics: PageMetrics): number {
  const aspect: number = block.aspect > 0 ? block.aspect : DEFAULT_IMAGE_ASPECT;
  const natural: number = metrics.widthPx / aspect;
  const capped: number = Math.min(natural, metrics.heightPx * MAX_IMAGE_PAGE_RATIO);
  // 极宽图（如细横幅）至少留一点高度，避免看起来像分割线
  return Math.max(metrics.widthPx * 0.15, capped);
}

function textBlock(text: string, paragraphIndex: number): ReaderBlock {
  return {
    kind: ReaderBlockKind.TEXT,
    text: text,
    src: '',
    alt: '',
    aspect: 0,
    paragraphIndex: paragraphIndex,
  };
}

/**
 * 可分片推进的分页器。
 *
 * `advance(budget)` 每次最多处理 `budget` 个「页内片段」，调用方按帧切片即可让出 UI 线程。
 * 分页状态（未消费完的文本块、当前页已用高度等）都保存在实例里，因此可以随时中断/继续。
 */
export class PagePager {
  private readonly blocks: ReaderBlock[];
  private readonly metrics: PageMetrics;
  private readonly measure: MeasureTextHeight;
  private readonly pages: ReaderPage[] = [];
  private blockIndex: number = 0;
  private rest: string = '';
  private pageBlocks: ReaderBlock[] = [];
  private usedPx: number = 0;
  private firstParagraph: number = 0;
  private activeParagraph: number = 0;
  private finished: boolean = false;

  constructor(blocks: ReaderBlock[], metrics: PageMetrics, measure: MeasureTextHeight) {
    this.blocks = blocks;
    this.metrics = metrics;
    this.measure = measure;
    if (blocks.length === 0 || metrics.heightPx <= 0 || metrics.widthVp <= 0) {
      this.finished = true;
    }
  }

  isFinished(): boolean {
    return this.finished;
  }

  /** 已完成的分页结果（未完成时可作为「当前已知页」使用）。 */
  getPages(): ReaderPage[] {
    return this.pages;
  }

  /** 下一个待消费的块下标：用于判断某个段落是否已被分页覆盖。 */
  getNextBlockIndex(): number {
    return this.blockIndex;
  }

  /**
   * 推进至多 `budget` 个页内片段，并受 `deadlineMs` 毫秒预算约束（0 表示不限时）。
   *
   * 分页必须在 UI 线程（`measureTextSize` 需要 UIContext），所以用**步数 + 时间双预算**
   * 保证单次调用不会长时间占用一帧。
   * @returns 是否已全部分页完成
   */
  advance(budget: number, deadlineMs: number = 0): boolean {
    const started: number = Date.now();
    let remaining: number = budget;
    while (remaining > 0 && !this.finished) {
      this.stepOnce();
      remaining--;
      if (deadlineMs > 0 && Date.now() - started >= deadlineMs) {
        break;
      }
    }
    return this.finished;
  }

  /** 一步 = 放置一个块（图片/短文本）或填满当前页的一段文本。 */
  private stepOnce(): void {
    if (this.rest.length > 0) {
      this.consumeText(this.rest);
      return;
    }
    if (this.blockIndex >= this.blocks.length) {
      this.flush();
      this.finished = true;
      return;
    }
    const block: ReaderBlock = this.blocks[this.blockIndex];
    this.blockIndex++;
    this.activeParagraph = block.paragraphIndex;
    if (this.pageBlocks.length === 0) {
      this.firstParagraph = block.paragraphIndex;
    }
    if (block.kind === ReaderBlockKind.IMAGE) {
      this.placeImage(block);
      return;
    }
    this.consumeText(block.text);
  }

  /** 文本块：整块放得下就整块放，否则切出能放下的前缀、收页、余下部分留到下一页。 */
  private consumeText(text: string): void {
    if (text.length === 0) {
      this.rest = '';
      return;
    }
    const gap: number = this.pageBlocks.length > 0 ? this.metrics.paragraphSpacingPx : 0;
    const available: number = this.metrics.heightPx - this.usedPx - gap;
    const fullHeight: number = this.measure(text, this.metrics.fontSize, this.metrics.widthVp, this.metrics.lineHeight);
    if (fullHeight <= available) {
      this.pageBlocks.push(textBlock(text, this.activeParagraph));
      this.usedPx += gap + fullHeight;
      this.rest = '';
      return;
    }
    const head: string = headThatFits(text, available, this.metrics, this.measure, fullHeight);
    if (head.length === 0) {
      // 空页也放不下一行：强制切 1 字保证前进；非空页则收页后重试
      if (this.pageBlocks.length === 0) {
        this.pageBlocks.push(textBlock(text.substring(0, 1), this.activeParagraph));
        this.rest = text.substring(1);
      } else {
        this.rest = text;
      }
      this.flush();
      return;
    }
    this.pageBlocks.push(textBlock(head, this.activeParagraph));
    this.rest = text.substring(head.length);
    this.flush();
  }

  /** 图片：整张放到能容纳它的页（当前页放不下就先收页）。 */
  private placeImage(block: ReaderBlock): void {
    const height: number = imageHeightPx(block, this.metrics);
    const gap: number = this.pageBlocks.length > 0 ? this.metrics.paragraphSpacingPx : 0;
    if (this.pageBlocks.length > 0 && this.usedPx + gap + height > this.metrics.heightPx) {
      this.flush();
    }
    const nextGap: number = this.pageBlocks.length > 0 ? this.metrics.paragraphSpacingPx : 0;
    this.pageBlocks.push(block);
    this.usedPx += nextGap + height;
  }

  private flush(): void {
    if (this.pageBlocks.length === 0) {
      return;
    }
    this.pages.push({
      index: this.pages.length,
      firstParagraph: this.firstParagraph,
      blocks: this.pageBlocks.slice(),
    });
    this.pageBlocks = [];
    this.usedPx = 0;
    // 续页仍属于同一段（切分场景）：下次进入时若 rest 非空，firstParagraph 会沿用
    this.firstParagraph = this.activeParagraph;
  }
}

export class PageLayout {
  /** 图片在页面中的高度（px）：与分页时同一个公式。 */
  static imageHeightPx(block: ReaderBlock, metrics: PageMetrics): number {
    return imageHeightPx(block, metrics);
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

  /** 找到第一个覆盖指定段落下标的块下标（用于判断恢复位置是否已分页到）。 */
  static blockIndexForParagraph(blocks: ReaderBlock[], paragraphIndex: number): number {
    for (let i = 0; i < blocks.length; i++) {
      if (blocks[i].paragraphIndex >= paragraphIndex) {
        return i;
      }
    }
    return blocks.length;
  }
}
