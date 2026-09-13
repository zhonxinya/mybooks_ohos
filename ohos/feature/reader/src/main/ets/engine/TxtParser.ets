import { BookFile } from './BookFile';

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

/** 切章结果。 */
export interface TxtSectionData {
  title: string;
  paragraphs: string[];
}

export class TxtParser {
  /** 读取整本 TXT 并按标题行切章。 */
  static load(filePath: string): TxtSectionData[] {
    const text = BookFile.readText(filePath).replace(/\r\n?/g, '\n');
    return TxtParser.splitChapters(text);
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
