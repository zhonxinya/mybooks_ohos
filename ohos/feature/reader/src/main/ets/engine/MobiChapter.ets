import { BookFile } from './BookFile';
import { imageAspect } from './ImageAspect';
import { MarkupText, ParsedBlock } from './MarkupText';
import { MobiDoc } from './MobiDoc';
import { MobiImages } from './MobiImages';
import { ReaderBlock, ReaderBlockKind } from '../model/ReaderTypes';

/**
 * MOBI 章节正文解析（**纯计算 + 文件读取，不含任何 UI 调用**）。
 *
 * 与 EPUB 的章节解析同构：先按 `recindex` 把本章用到的插图落到沙箱，再把 HTML
 * 转成文本/图片块。放在独立模块是为了能在 taskpool 子线程里被调用
 * （见 `ReaderTasks.loadMobiChapterTask`）。
 */
export class MobiChapter {
  static load(filePath: string, imageDir: string, records: number[], firstResource: number,
    section: ArrayBuffer, codepage: number, flowResources: number[]): ReaderBlock[] {
    const html: string = MobiDoc.decodeSection(new Uint8Array(section), codepage);
    const wanted: number[] = MobiDoc.imageRecords(html, flowResources);
    const paths: Map<number, string> = new Map<number, string>();
    for (let i = 0; i < wanted.length; i++) {
      const path: string = MobiImages.ensure(filePath, imageDir, records, firstResource, wanted[i]);
      if (path.length > 0) {
        paths.set(wanted[i], path);
      }
    }
    const parsed: ParsedBlock[] = MarkupText.toBlocks(
      MobiDoc.replaceImageRecords(html, paths, flowResources));
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
      if (item.src.length === 0 || !BookFile.exists(item.src)) {
        continue;
      }
      blocks.push({
        kind: ReaderBlockKind.IMAGE,
        text: '',
        src: item.src,
        alt: item.alt,
        aspect: imageAspect(item.src),
        paragraphIndex: paragraphIndex,
      });
    }
    return blocks;
  }
}
