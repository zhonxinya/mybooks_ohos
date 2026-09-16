import { taskpool } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  BookEngine,
  ReaderBlock,
  ReaderBlockKind,
  ReaderCatalogItem,
  ReaderChapter,
} from '../model/ReaderTypes';
import { MobiDoc, MobiDocData, MobiInfo, MobiSection } from './MobiDoc';
import { loadMobiChapterTask, loadMobiDocTask } from './ReaderTasks';

const TAG: string = 'MobiEngine';
/** 章节正文缓存上限（MOBI 单章可能含大段 HTML，不能无限留）。 */
const MAX_CACHED_CHAPTERS: number = 4;

/**
 * MOBI（KF7）引擎：**解析全在子线程**。
 *
 * 打开时一次性把正文解压到内存（几 MB 级），目录与章节边界也在这里定好；
 * 之后每次翻章只按字节区间取一节、解析成块（插图按需落盘），因此翻章几乎无延迟。
 * 正文以**字节**形式持有（非字符串）：章节边界来自目录里的 `filepos` 字节偏移，
 * 这样切章不需要维护「字节 ↔ 字符」映射，对中文（UTF-8 三字节）尤其重要。
 */
export class MobiEngine implements BookEngine {
  private readonly filePath: string;
  private readonly imageDir: string;
  private readonly info: MobiInfo;
  private readonly records: number[];
  private readonly text: Uint8Array;
  private readonly sections: MobiSection[];
  /** KF8 的 `flow → 图片资源序号` 换算表（KF7 为空）。 */
  private readonly flowResources: number[];
  private readonly bookTitle: string;
  private readonly catalogItems: ReaderCatalogItem[] = [];
  private readonly cache: Map<number, ReaderChapter> = new Map();

  private constructor(filePath: string, imageDir: string, bookTitle: string, data: MobiDocData) {
    this.filePath = filePath;
    this.imageDir = imageDir;
    this.bookTitle = bookTitle;
    this.info = data.info;
    this.records = data.records;
    this.text = new Uint8Array(data.text);
    this.sections = data.sections;
    this.flowResources = data.flowResources;
    for (let i = 0; i < data.sections.length; i++) {
      this.catalogItems.push({ index: i, title: data.sections[i].title });
    }
  }

  static async open(filePath: string, bookTitle: string, cacheDir: string): Promise<MobiEngine> {
    let data: MobiDocData;
    try {
      data = await taskpool.execute(loadMobiDocTask, filePath) as MobiDocData;
    } catch (error) {
      hilog.error(0x0000, TAG, 'parse failed: %{public}s (%{public}s)', filePath, (error as Error).message);
      throw new Error(`MOBI 解析失败：${(error as Error).message}`);
    }
    const imageDir: string = MobiEngine.imageDir(cacheDir, filePath);
    const engine = new MobiEngine(filePath, imageDir, bookTitle, data);
    hilog.info(0x0000, TAG, 'opened %{public}s: %{public}d chapters, %{public}d bytes text',
      engine.getTitle(), engine.sections.length, engine.text.length);
    return engine;
  }

  getTitle(): string {
    return this.info.title.length > 0 ? this.info.title : this.bookTitle;
  }

  getCatalog(): ReaderCatalogItem[] {
    return this.catalogItems;
  }

  async loadChapter(index: number): Promise<ReaderChapter> {
    const safeIndex = index < 0 || index >= this.sections.length ? 0 : index;
    const cached: ReaderChapter | undefined = this.cache.get(safeIndex);
    if (cached !== undefined) {
      return cached;
    }
    const section: MobiSection = this.sections[safeIndex];
    const bytes: Uint8Array = this.text.slice(section.start, section.end);
    let blocks: ReaderBlock[] = [];
    try {
      blocks = await taskpool.execute(loadMobiChapterTask, this.filePath, this.imageDir, this.records,
        this.info.firstResource, bytes.buffer as ArrayBuffer, this.info.codepage,
        this.flowResources) as ReaderBlock[];
    } catch (error) {
      hilog.error(0x0000, TAG, 'chapter %{public}d failed: %{public}s', safeIndex, (error as Error).message);
      blocks = [MobiEngine.textBlock('（本章内容读取失败）')];
    }
    const paragraphs: string[] = [];
    for (let i = 0; i < blocks.length; i++) {
      if (blocks[i].kind === ReaderBlockKind.TEXT) {
        paragraphs.push(blocks[i].text);
      }
    }
    const chapter: ReaderChapter = {
      index: safeIndex,
      title: section.title,
      paragraphs: paragraphs,
      blocks: blocks,
    };
    if (this.cache.size >= MAX_CACHED_CHAPTERS) {
      this.cache.clear();
    }
    this.cache.set(safeIndex, chapter);
    return chapter;
  }

  close(): void {
    this.cache.clear();
  }

  /** 插图落地目录：按文件路径哈希区分，避免同名书互相覆盖（与 EPUB 解压目录同理）。 */
  private static imageDir(cacheDir: string, filePath: string): string {
    let hash = 5381;
    for (let i = 0; i < filePath.length; i++) {
      hash = (hash * 33 + filePath.charCodeAt(i)) % 0x7FFFFFFF;
    }
    return `${cacheDir}/reader_mobi_${hash.toString(16)}`;
  }

  private static textBlock(text: string): ReaderBlock {
    return {
      kind: ReaderBlockKind.TEXT,
      text: text,
      src: '',
      alt: '',
      aspect: 0,
      paragraphIndex: 0,
    };
  }
}
