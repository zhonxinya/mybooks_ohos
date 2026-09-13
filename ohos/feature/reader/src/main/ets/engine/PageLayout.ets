/**
 * 分页：把一章的段落按「正文可用高度」切成一页页。
 *
 * - 测量走宿主注入的 `MeasureTextHeight`（ArkUI `measureTextSize` 不能在辅助线程调用，
 *   所以分页留在 UI 线程，只对**当前章**做，且按章缓存）；
 * - 超长段落会跨页切分：中文单段动辄数千字，不切就会出现截断或溢出；
 * - 切分用「按高度比例估算 + 少量线性校正」，把测量次数压在常数级。
 */
const MAX_SPLIT_ATTEMPTS: number = 3;

export interface ReaderPage {
  index: number;
  /** 该页第一个段落的下标，用于进度上报与位置恢复。 */
  firstParagraph: number;
  /** 该页的段落片段；同一段跨页时会在相邻两页各出现一次。 */
  texts: string[];
}

export interface PageMetrics {
  /** 正文可用宽度（vp）。 */
  widthVp: number;
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
  static paginate(paragraphs: string[], metrics: PageMetrics, measure: MeasureTextHeight): ReaderPage[] {
    const pages: ReaderPage[] = [];
    if (paragraphs.length === 0 || metrics.heightPx <= 0 || metrics.widthVp <= 0) {
      return pages;
    }
    let texts: string[] = [];
    let usedPx: number = 0;
    let firstParagraph: number = 0;
    for (let i = 0; i < paragraphs.length; i++) {
      let rest: string = paragraphs[i];
      if (texts.length === 0) {
        firstParagraph = i;
      }
      while (rest.length > 0) {
        const gap: number = texts.length > 0 ? metrics.paragraphSpacingPx : 0;
        const available: number = metrics.heightPx - usedPx - gap;
        const fullHeight: number = measure(rest, metrics.fontSize, metrics.widthVp, metrics.lineHeight);
        if (fullHeight <= available) {
          texts.push(rest);
          usedPx += gap + fullHeight;
          rest = '';
          break;
        }
        const head: string = PageLayout.headThatFits(rest, available, metrics, measure);
        if (head.length === 0) {
          // 空页也放不下一行（可用高度小于一行）：强制切 1 字，保证循环一定前进
          if (texts.length === 0) {
            texts.push(rest.substring(0, 1));
            rest = rest.substring(1);
          }
          PageLayout.flush(pages, texts, usedPx, firstParagraph);
          texts = [];
          usedPx = 0;
          firstParagraph = i;
          continue;
        }
        texts.push(head);
        rest = rest.substring(head.length);
        PageLayout.flush(pages, texts, usedPx, firstParagraph);
        texts = [];
        usedPx = 0;
        // 续页仍属于同一段：进度恢复时会定位到同一段的任意一页
        firstParagraph = i;
      }
    }
    PageLayout.flush(pages, texts, usedPx, firstParagraph);
    return pages;
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

  private static flush(pages: ReaderPage[], texts: string[], usedPx: number, firstParagraph: number): void {
    if (texts.length === 0) {
      return;
    }
    pages.push({ index: pages.length, firstParagraph: firstParagraph, texts: texts.slice() });
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
