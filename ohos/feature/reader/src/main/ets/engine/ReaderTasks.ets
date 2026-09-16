import { BookFile } from './BookFile';
import { EpubStructure, EpubStructureData } from './EpubStructure';
import { imageAspect } from './ImageAspect';
import { MarkupText, ParsedBlock } from './MarkupText';
import { HuffCdic } from './HuffCdic';
import { MobiChapter } from './MobiChapter';
import { MobiDoc, MobiDocData, MobiInfo, MobiSection } from './MobiDoc';
import { MobiIndexData } from './MobiIndex';
import { MobiKf8, MobiKf8Parts, MobiKf8TocItem } from './MobiKf8';
import { MobiRecords } from './MobiRecords';
import { TxtParser, TxtSectionData } from './TxtParser';
import { ReaderBlock, ReaderBlockKind } from '../model/ReaderTypes';

/**
 * 阅读器的后台任务（taskpool 子线程）。
 *
 * **约束：UI 进程禁止复杂任务** —— 文件读取、编码探测、正则解析、图片头部解码都属于重活，
 * 一律在这里以 `@Concurrent` 函数执行，由 UI 线程 `taskpool.execute` 调用。
 * `@Concurrent` 函数只能使用 import 的模块符号或局部变量（不能调用本文件内的普通函数），
 * 所以解析逻辑都放在 `BookFile` / `MobiDoc` / `MobiIndex` / `MobiKf8` / `MobiRecords` /
 * `MarkupText` / `EpubStructure` / `TxtParser` / `ImageAspect` 里，
 * 且这些模块不得触碰任何 ArkUI/UIContext API。
 */

/** 读取并解析 EPUB 结构（container.xml → OPF → spine → NCX/nav 目录）。 */
@Concurrent
export function loadEpubStructureTask(extractDir: string, fallbackTitle: string): EpubStructureData {
  return EpubStructure.parse(extractDir, fallbackTitle);
}

/**
 * 准备解压目录：清掉上次中断的解压残留并确保目录存在。
 * 递归删除成千上万个文件属重活，放子线程（正常路径下目录不存在，开销极小）。
 */
@Concurrent
export function prepareExtractDirTask(extractDir: string, cacheDir: string): void {
  BookFile.removeDir(extractDir);
  BookFile.ensureDir(cacheDir);
  // decompressFile 要求目标目录已存在，否则报 900002（The input destination file is invalid）
  BookFile.ensureDir(extractDir);
}

/**
 * 读取并解析一章：XHTML → 文本/图片块（解析图片绝对路径、按需读图片宽高比）。
 * 文件 IO、正则解析、图片头部解码全部在子线程完成。
 */
@Concurrent
export function loadEpubChapterTask(chapterPath: string, chapterDir: string): ReaderBlock[] {
  const parsed: ParsedBlock[] = MarkupText.toBlocks(BookFile.readText(chapterPath));
  const blocks: ReaderBlock[] = [];
  let paragraphIndex: number = 0;
  for (let i = 0; i < parsed.length; i++) {
    const item: ParsedBlock = parsed[i];
    if (!item.isImage) {
      blocks.push({
        kind: ReaderBlockKind.TEXT,
        text: item.text,
        src: '',
        alt: '',
        aspect: 0,
        paragraphIndex: paragraphIndex,
      });
      paragraphIndex++;
      continue;
    }
    const src: string = BookFile.join(chapterDir, BookFile.normalizeHref(item.src));
    if (!BookFile.exists(src)) {
      continue;
    }
    blocks.push({
      kind: ReaderBlockKind.IMAGE,
      text: '',
      src: src,
      alt: item.alt,
      aspect: imageAspect(src),
      paragraphIndex: paragraphIndex,
    });
  }
  return blocks;
}

/** 读取整本 TXT 并切章（编码探测 + 章节正则都在子线程）。 */
@Concurrent
export function loadTxtBookTask(filePath: string): TxtSectionData[] {
  return TxtParser.load(filePath);
}

/**
 * 打开 MOBI：读 PDB 头 → 记录表 → 记录 0 → 正文记录，解压并切章。
 *
 * 只读需要的区间（正文记录在文件里是连续的，一次读完再按记录表切片），
 * 因此即使 MOBI 有几十 MB 插图，内存里也只留正文。
 */
@Concurrent
export function loadMobiDocTask(filePath: string): MobiDocData {
  const head: Uint8Array = new Uint8Array(BookFile.readRange(filePath, 0, MobiDoc.HEADER_BYTES));
  const recordCount: number = MobiDoc.recordCount(head);
  const list: Uint8Array = new Uint8Array(BookFile.readRange(filePath, MobiDoc.HEADER_BYTES, recordCount * 8));
  const records: number[] = MobiDoc.recordOffsets(list, recordCount, BookFile.size(filePath));
  const record0: Uint8Array = new Uint8Array(BookFile.readRange(filePath, records[0], records[1] - records[0]));
  const info: MobiInfo = MobiDoc.parse(records, record0);
  const huff: HuffCdic | null = MobiRecords.readHuffman(filePath, records, info);
  const textFrom: number = records[1];
  const textTo: number = records[info.textRecordCount + 1];
  const payload: Uint8Array = new Uint8Array(BookFile.readRange(filePath, textFrom, textTo - textFrom));
  const raw: Uint8Array = MobiDoc.assembleText(payload, textFrom, records, info, huff);
  if (raw.length === 0) {
    throw new Error('这本书没有可阅读的正文');
  }
  // KF8：正文由「骨架 + 片段」拼成，章节即部件；KF7：整篇 HTML 按目录偏移切区间
  let text: Uint8Array = raw;
  let sections: MobiSection[] = [];
  let flowResources: number[] = [];
  if (info.kf8) {
    const fdst: Uint8Array = MobiRecords.read(filePath, records, info.fdstOffset);
    const skeleton: MobiIndexData = MobiRecords.readIndex(filePath, records, info.skeletonIndex, info.codepage);
    const fragments: MobiIndexData = MobiRecords.readIndex(filePath, records, info.fragmentIndex, info.codepage);
    const ncx: MobiIndexData = MobiRecords.readIndex(filePath, records, info.ncxIndex, info.codepage);
    const built: MobiKf8Parts = MobiKf8.parts(raw, fdst, skeleton, fragments);
    // 上限常量取自 MobiKf8：@Concurrent 函数只能使用 import 进来的符号或局部变量
    const toc: MobiKf8TocItem[] = MobiKf8.toc(ncx, MobiKf8.MAX_TOC_ITEMS);
    text = built.text;
    sections = MobiDoc.kf8Sections(built.parts, built.fragmentParts, toc, text, info.codepage);
    // KF8 的插图常包在 SVG flow 里，正文只写 kindle:flow:N，这里先换算成资源序号
    flowResources = MobiKf8.flowResources(MobiKf8.flows(raw, fdst));
  } else {
    sections = MobiDoc.sections(info, raw);
  }
  if (sections.length === 0 || text.length === 0) {
    throw new Error('这本书没有可阅读的正文');
  }
  MobiDoc.checkText(text);
  // 只把正文本身带回去（Uint8Array 可能是更大缓冲的视图，必须精确拷贝）
  const exact: ArrayBuffer = new ArrayBuffer(text.length);
  new Uint8Array(exact).set(text);
  return { info: info, records: records, text: exact, sections: sections, flowResources: flowResources };
}

/** 解析 MOBI 的一章：按图片引用落盘插图 → HTML 转文本/图片块。 */
@Concurrent
export function loadMobiChapterTask(filePath: string, imageDir: string, records: number[],
  firstResource: number, section: ArrayBuffer, codepage: number,
  flowResources: number[]): ReaderBlock[] {
  return MobiChapter.load(filePath, imageDir, records, firstResource, section, codepage, flowResources);
}
