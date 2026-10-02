import { zlib } from '@kit.BasicServicesKit';
import { taskpool } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BookEngine, ReaderBlock, ReaderBlockKind, ReaderCatalogItem, ReaderChapter } from '../model/ReaderTypes';
import { BookFile } from './BookFile';
import { EpubStructure, EpubStructureData } from './EpubStructure';
import { LruCache } from './LruCache';
import { loadEpubChapterTask, loadEpubStructureTask, prepareExtractDirTask } from './ReaderTasks';

const TAG: string = 'EpubEngine';
// 章节文本驻留上限：6 章对长篇小说是几十 MB 级的常驻（每章 blocks 都带全文），
// 降到 3 章足够覆盖「往回翻一章再翻回来」的常见路径，跳章重解析走 taskpool 不卡 UI。
const MAX_CACHED_CHAPTERS: number = 3;

/**
 * EPUB 引擎：`zlib` 解压到缓存目录 → 逐章取文。
 *
 * **UI 线程只做调度**：解压走系统异步 API，结构解析（container/OPF/NCX）与章节解析
 * （文件读取、编码探测、正则、图片宽高比）都通过 `taskpool` 丢到子线程（见 `ReaderTasks`）。
 * 解压产物按「文件路径哈希」缓存，二次打开不再解压；章节正文按需加载，仅保留最近数章。
 */
export class EpubEngine implements BookEngine {
  private readonly bookTitle: string;
  private readonly extractDir: string;
  private readonly spinePaths: string[] = [];
  private readonly spineTitles: string[] = [];
  private readonly catalogItems: ReaderCatalogItem[] = [];
  private readonly cache: LruCache<number, ReaderChapter> = new LruCache<number, ReaderChapter>(MAX_CACHED_CHAPTERS);

  private constructor(bookTitle: string, extractDir: string) {
    this.bookTitle = bookTitle;
    this.extractDir = extractDir;
  }

  static async open(filePath: string, bookTitle: string, cacheDir: string): Promise<EpubEngine> {
    const extractDir = BookFile.join(cacheDir, `reader_epub_${EpubEngine.hashPath(filePath)}`);
    const containerPath = BookFile.join(extractDir, EpubStructure.containerRelative());
    if (!BookFile.exists(containerPath)) {
      try {
        // 清理残留 + 建目录（递归删除可能很重）放子线程
        await taskpool.execute(prepareExtractDirTask, extractDir, cacheDir);
        await zlib.decompressFile(filePath, extractDir);
      } catch (error) {
        hilog.error(0x0000, TAG, 'decompress failed: %{public}s (%{public}s)',
          filePath, (error as Error).message);
        throw new Error(`EPUB 解压失败：${(error as Error).message}`);
      }
      hilog.info(0x0000, TAG, 'decompressed %{public}s', extractDir);
    }
    // 结构解析（含容器/OPF/目录的读取与正则）在子线程执行
    let structure: EpubStructureData;
    try {
      structure = await taskpool.execute(loadEpubStructureTask, extractDir, bookTitle) as EpubStructureData;
    } catch (error) {
      hilog.error(0x0000, TAG, 'structure parse failed: %{public}s', (error as Error).message);
      throw new Error(`EPUB 解析失败：${(error as Error).message}`);
    }
    if (structure.spineHrefs.length === 0) {
      throw new Error('EPUB 没有可阅读的正文');
    }
    const engine = new EpubEngine(structure.bookTitle, extractDir);
    for (let i = 0; i < structure.spineHrefs.length; i++) {
      engine.spinePaths.push(BookFile.join(extractDir, structure.spineHrefs[i]));
      engine.spineTitles.push(structure.spineTitles[i]);
      engine.catalogItems.push({ index: i, title: structure.spineTitles[i] });
    }
    hilog.info(0x0000, TAG, 'opened %{public}s: %{public}d chapters', structure.bookTitle,
      structure.spineHrefs.length);
    return engine;
  }

  getTitle(): string {
    return this.bookTitle;
  }

  getCatalog(): ReaderCatalogItem[] {
    return this.catalogItems;
  }

  async loadChapter(index: number): Promise<ReaderChapter> {
    const safeIndex = index < 0 || index >= this.spinePaths.length ? 0 : index;
    const cached = this.cache.get(safeIndex);
    if (cached !== undefined) {
      return cached;
    }
    const chapterPath: string = this.spinePaths[safeIndex];
    let blocks: ReaderBlock[] = [];
    try {
      // 读取 + 编码探测 + XHTML 正则解析 + 图片头部解码都在子线程
      blocks = await taskpool.execute(loadEpubChapterTask, chapterPath,
        BookFile.dirName(chapterPath)) as ReaderBlock[];
    } catch (error) {
      hilog.error(0x0000, TAG, 'chapter %{public}d failed: %{public}s',
        safeIndex, (error as Error).message);
      blocks = [EpubEngine.textBlock('（本章内容读取失败）', 0)];
    }
    let paragraphCount: number = 0;
    for (let i = 0; i < blocks.length; i++) {
      if (blocks[i].kind === ReaderBlockKind.TEXT) {
        paragraphCount++;
      }
    }
    const chapter: ReaderChapter = {
      index: safeIndex,
      title: this.spineTitles[safeIndex],
      paragraphCount: paragraphCount,
      blocks: blocks,
    };
    this.cache.set(safeIndex, chapter);
    return chapter;
  }

  close(): void {
    this.cache.clear();
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

  private static hashPath(value: string): string {
    let hash = 5381;
    for (let i = 0; i < value.length; i++) {
      hash = (hash * 33 + value.charCodeAt(i)) % 0x7FFFFFFF;
    }
    return hash.toString(16);
  }
}
