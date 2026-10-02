import { util } from '@kit.ArkTS';
import { BookFile } from './BookFile';
import { TextCodec } from './TextCodec';

/**
 * TXT 解析（**纯计算 + 文件读取，不含任何 UI/ArkUI 调用**）。
 *
 * 整本读取 + 编码探测 + 章节切分对长篇小说是重活（几 MB 文本），
 * 必须能在 taskpool 子线程里跑（见 `ReaderTasks`），不能在 UI 线程同步执行。
 */
/**
 * 章节标题行：中文小说常见写法（第X章/节/回/卷/篇 + 序章/楔子/番外 等）。
 * 限定整行长度，避免把正文里提到「第三章」的句子误判为标题。
 */
const CHAPTER_PATTERN: RegExp = new RegExp(
  '^(?:第[0-9零一二三四五六七八九十百千万两]{1,12}[章节回卷篇集幕]' +
  '|序章|序言|序|楔子|引子|前言|后记|尾声|终章|番外)[^。！？!?]{0,40}$');
const MAX_TITLE_LENGTH: number = 50;
/** 无法识别章节时，按固定字数切节，避免整本变成一个巨大章节。 */
const FALLBACK_CHUNK_CHARS: number = 3000;

/** 切章结果（仅解析过程使用，不随引擎常驻）。 */
export interface TxtSectionData {
  title: string;
  paragraphs: string[];
}

/** 一章在 UTF-8 缓存文件中的字节区间。正文按章再读，开书后不再保留整本字符串。 */
export interface TxtChapterSpan {
  title: string;
  byteStart: number;
  byteEnd: number;
}

/** 开书任务的返回值：缓存路径 + 章界，不含正文。 */
export interface TxtBookIndex {
  cachePath: string;
  chapters: TxtChapterSpan[];
}

export class TxtParser {
  /**
   * 读取整本 TXT、按标题行切章，并把各章正文写成 UTF-8 缓存。
   * 返回的索引只有标题和字节区间，整本字符串随任务结束释放。
   */
  static index(filePath: string, cachePath: string): TxtBookIndex {
    const text = BookFile.readText(filePath).replace(/\r\n?/g, '\n');
    const sections: TxtSectionData[] = TxtParser.splitChapters(text);
    const chapters: TxtChapterSpan[] = TxtParser.writeCache(cachePath, sections);
    const indexed: TxtBookIndex = { cachePath: cachePath, chapters: chapters };
    return indexed;
  }

  /** 按字节区间读回一章，并拆成段落。 */
  static readChapter(cachePath: string, byteStart: number, byteEnd: number): string[] {
    const length: number = byteEnd - byteStart;
    if (length <= 0) {
      return [];
    }
    const bytes: Uint8Array = new Uint8Array(BookFile.readRange(cachePath, byteStart, length));
    const text: string = TextCodec.decodeAs(bytes, 'utf-8');
    if (text.length === 0) {
      return [];
    }
    return text.split('\n');
  }

  /** 各章按出现顺序紧挨着写入，区间互不重叠，因此章与章之间不需要分隔符。 */
  private static writeCache(cachePath: string, sections: TxtSectionData[]): TxtChapterSpan[] {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const parts: Uint8Array[] = [];
    const spans: TxtChapterSpan[] = [];
    let cursor: number = 0;
    for (let i = 0; i < sections.length; i++) {
      const payload: string = sections[i].paragraphs.join('\n');
      const encoded: Uint8Array = encoder.encodeInto(payload);
      // 立刻拷贝：编码器可能复用内部缓冲，循环里直接留着上一次的视图会串章。
      const bytes: Uint8Array = new Uint8Array(encoded.byteLength);
      bytes.set(encoded);
      spans.push({
        title: sections[i].title,
        byteStart: cursor,
        byteEnd: cursor + bytes.byteLength,
      });
      parts.push(bytes);
      cursor += bytes.byteLength;
    }
    const merged: Uint8Array = new Uint8Array(cursor);
    let offset: number = 0;
    for (let i = 0; i < parts.length; i++) {
      merged.set(parts[i], offset);
      offset += parts[i].byteLength;
    }
    const dir: string = BookFile.dirName(cachePath);
    if (dir.length > 0) {
      BookFile.ensureDir(dir);
    }
    const exact: ArrayBuffer = merged.buffer.slice(merged.byteOffset, merged.byteOffset + merged.byteLength);
    BookFile.writeBytes(cachePath, exact);
    return spans;
  }

  /** 按标题行切章；识别不到标题时退化为定长切节。 */
  private static splitChapters(text: string): TxtSectionData[] {
    const lines: string[] = text.split('\n');
    const sections: TxtSectionData[] = [];
    let title: string = '';
    let buffer: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (TxtParser.isChapterTitle(line)) {
        TxtParser.flush(sections, title, buffer);
        title = line;
        buffer = [];
        continue;
      }
      if (line.length > 0) {
        buffer.push(line);
      }
    }
    TxtParser.flush(sections, title, buffer);
    if (sections.length <= 1) {
      return TxtParser.chunkByLength(text);
    }
    for (let i = 0; i < sections.length; i++) {
      if (sections[i].title.length === 0) {
        sections[i].title = `第${i + 1}章`;
      }
    }
    return sections;
  }

  private static isChapterTitle(line: string): boolean {
    if (line.length === 0 || line.length > MAX_TITLE_LENGTH) {
      return false;
    }
    return CHAPTER_PATTERN.test(line);
  }

  private static flush(sections: TxtSectionData[], title: string, buffer: string[]): void {
    // 首个标题之前若有正文，单独作为「开始」章节保留，避免丢内容
    if (title.length === 0 && buffer.length === 0) {
      return;
    }
    sections.push({ title: title.length > 0 ? title : '开始', paragraphs: buffer.slice() });
  }

  /** 无章节标题时的兜底切分。 */
  private static chunkByLength(text: string): TxtSectionData[] {
    const paragraphs: string[] = [];
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length > 0) {
        paragraphs.push(line);
      }
    }
    const sections: TxtSectionData[] = [];
    let buffer: string[] = [];
    let length = 0;
    let part = 1;
    for (let i = 0; i < paragraphs.length; i++) {
      buffer.push(paragraphs[i]);
      length += paragraphs[i].length;
      if (length >= FALLBACK_CHUNK_CHARS) {
        sections.push({ title: `第${part}节`, paragraphs: buffer });
        buffer = [];
        length = 0;
        part++;
      }
    }
    if (buffer.length > 0) {
      sections.push({ title: `第${part}节`, paragraphs: buffer });
    }
    if (sections.length === 0) {
      sections.push({ title: '开始', paragraphs: [] });
    }
    return sections;
  }
}
