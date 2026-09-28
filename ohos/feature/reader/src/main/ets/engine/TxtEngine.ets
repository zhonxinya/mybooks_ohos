import { taskpool } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BookEngine, ReaderBlock, ReaderBlockKind, ReaderCatalogItem, ReaderChapter } from '../model/ReaderTypes';
import { LruCache } from './LruCache';
import { loadTxtChapterTask, loadTxtBookTask } from './ReaderTasks';
import { TxtBookIndex, TxtChapterSpan } from './TxtParser';

const TAG: string = 'TxtEngine';
/** 已解析章节的上限。章界索引常驻，正文按章从缓存文件读取。 */
const MAX_CACHED_CHAPTERS: number = 3;

/**
 * TXT 引擎：整本读取、编码探测与章节切分在子线程完成，
 * 结果写成 UTF-8 缓存。引擎只留章界；翻章时再读该章。
 */
export class TxtEngine implements BookEngine {
  private readonly bookTitle: string;
  private readonly cachePath: string;
  private readonly spans: TxtChapterSpan[];
  private readonly catalogItems: ReaderCatalogItem[] = [];
  private readonly cache: LruCache<number, ReaderChapter> =
    new LruCache<number, ReaderChapter>(MAX_CACHED_CHAPTERS);

  private constructor(bookTitle: string, cachePath: string, spans: TxtChapterSpan[]) {
    this.bookTitle = bookTitle;
    this.cachePath = cachePath;
    this.spans = spans;
    for (let i = 0; i < spans.length; i++) {
      this.catalogItems.push({ index: i, title: spans[i].title });
    }
  }

  static async load(filePath: string, bookTitle: string, cacheDir: string): Promise<TxtEngine> {
    const cachePath: string = TxtEngine.cachePathFor(cacheDir, filePath);
    let index: TxtBookIndex;
    try {
      index = await taskpool.execute(loadTxtBookTask, filePath, cachePath) as TxtBookIndex;
    } catch (error) {
      hilog.error(0x0000, TAG, 'load failed: %{public}s', (error as Error).message);
      throw new Error(`TXT 解析失败：${(error as Error).message}`);
    }
    const engine = new TxtEngine(bookTitle, index.cachePath, index.chapters);
    hilog.info(0x0000, TAG, 'loaded %{public}d chapters', index.chapters.length);
    return engine;
  }

  getTitle(): string {
    return this.bookTitle;
  }

  getCatalog(): ReaderCatalogItem[] {
    return this.catalogItems;
  }

  async loadChapter(index: number): Promise<ReaderChapter> {
    const safeIndex: number = index < 0 || index >= this.spans.length ? 0 : index;
    const cached: ReaderChapter | undefined = this.cache.get(safeIndex);
    if (cached !== undefined) {
      return cached;
    }
    const span: TxtChapterSpan = this.spans[safeIndex];
    let paragraphs: string[] = [];
    try {
      paragraphs = await taskpool.execute(loadTxtChapterTask, this.cachePath,
        span.byteStart, span.byteEnd) as string[];
    } catch (error) {
      hilog.error(0x0000, TAG, 'chapter %{public}d failed: %{public}s', safeIndex, (error as Error).message);
      paragraphs = ['（本章内容读取失败）'];
    }
    const blocks: ReaderBlock[] = [];
    for (let k = 0; k < paragraphs.length; k++) {
      blocks.push({
        kind: ReaderBlockKind.TEXT,
        text: paragraphs[k],
        src: '',
        alt: '',
        aspect: 0,
        paragraphIndex: k,
      });
    }
    const chapter: ReaderChapter = {
      index: safeIndex,
      title: span.title,
      paragraphCount: paragraphs.length,
      blocks: blocks,
    };
    this.cache.set(safeIndex, chapter);
    return chapter;
  }

  /**
   * 只丢掉已解析的章节正文。
   * 章界索引保留：阅读中「重新排版」会调用 close 再 loadChapter，不能把目录一起清掉。
   */
  close(): void {
    this.cache.clear();
  }

  private static cachePathFor(cacheDir: string, filePath: string): string {
    let hash: number = 5381;
    for (let i = 0; i < filePath.length; i++) {
      hash = (hash * 33 + filePath.charCodeAt(i)) % 0x7FFFFFFF;
    }
    return `${cacheDir}/reader_txt_${hash.toString(16)}.utf8`;
  }
}
