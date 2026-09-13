import { BookFile } from './BookFile';
import { EpubStructure, EpubStructureData } from './EpubStructure';
import { imageAspect } from './ImageAspect';
import { MarkupText, ParsedBlock } from './MarkupText';
import { TxtParser, TxtSectionData } from './TxtParser';
import { ReaderBlock, ReaderBlockKind } from '../model/ReaderTypes';

/**
 * 阅读器的后台任务（taskpool 子线程）。
 *
 * **约束：UI 进程禁止复杂任务** —— 文件读取、编码探测、正则解析、图片头部解码都属于重活，
 * 一律在这里以 `@Concurrent` 函数执行，由 UI 线程 `taskpool.execute` 调用。
 * `@Concurrent` 函数只能使用 import 的模块符号或局部变量（不能调用本文件内的普通函数），
 * 所以解析逻辑都放在 `BookFile` / `MarkupText` / `EpubStructure` / `TxtParser` / `ImageAspect` 里，
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
