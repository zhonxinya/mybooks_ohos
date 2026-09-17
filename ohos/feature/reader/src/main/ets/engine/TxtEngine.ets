import { taskpool } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BookEngine, ReaderBlock, ReaderBlockKind, ReaderCatalogItem, ReaderChapter } from '../model/ReaderTypes';
import { loadTxtBookTask } from './ReaderTasks';
import { TxtSectionData } from './TxtParser';

const TAG: string = 'TxtEngine';

/**
 * TXT 引擎：整本读取、编码探测与章节切分都通过 `taskpool` 在子线程完成
 * （几 MB 文本的解析属重活，**不能在 UI 线程同步执行**，见 `ReaderTasks`）。
 *
 * 切分结果一次性放入内存，翻章零延迟。
 */
export class TxtEngine implements BookEngine {
  private readonly bookTitle: string;
  private readonly catalogItems: ReaderCatalogItem[] = [];
  private readonly chapters: ReaderChapter[] = [];

  private constructor(bookTitle: string) {
    this.bookTitle = bookTitle;
  }

  static async load(filePath: string, bookTitle: string): Promise<TxtEngine> {
    const engine = new TxtEngine(bookTitle);
    let sections: TxtSectionData[];
    try {
      sections = await taskpool.execute(loadTxtBookTask, filePath) as TxtSectionData[];
    } catch (error) {
      hilog.error(0x0000, TAG, 'load failed: %{public}s', (error as Error).message);
      throw new Error(`TXT 解析失败：${(error as Error).message}`);
    }
    for (let i = 0; i < sections.length; i++) {
      const section = sections[i];
      const blocks: ReaderBlock[] = [];
      for (let k = 0; k < section.paragraphs.length; k++) {
        blocks.push({
          kind: ReaderBlockKind.TEXT,
          text: section.paragraphs[k],
          src: '',
          alt: '',
          aspect: 0,
          paragraphIndex: k,
        });
      }
      engine.chapters.push({
        index: i,
        title: section.title,
        paragraphCount: section.paragraphs.length,
        blocks: blocks,
      });
      engine.catalogItems.push({ index: i, title: section.title });
    }
    hilog.info(0x0000, TAG, 'loaded %{public}d chapters', sections.length);
    return engine;
  }

  getTitle(): string {
    return this.bookTitle;
  }

  getCatalog(): ReaderCatalogItem[] {
    return this.catalogItems;
  }

  loadChapter(index: number): Promise<ReaderChapter> {
    const safeIndex = index < 0 || index >= this.chapters.length ? 0 : index;
    return Promise.resolve(this.chapters[safeIndex]);
  }

  close(): void {
    this.chapters.length = 0;
    this.catalogItems.length = 0;
  }
}
