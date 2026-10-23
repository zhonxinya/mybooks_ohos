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
/** 流式索引块大小（1MB），兼顾内存占用与跨块匹配精度。 */
const STREAM_BLOCK_SIZE: number = 1024 * 1024;
/** 块间重叠区（2KB），保证章节标题不被截断。 */
const STREAM_OVERLAP: number = 2048;
/** 流式索引文件大小阈值：超过此值退回全量解析，避免 byte offset 追踪错误。 */
const STREAM_INDEX_THRESHOLD: number = 10 * 1024 * 1024; // 10MB

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
   * TXT 索引：按文件大小选择策略。
   * 
   * - ≤10MB：流式索引（分块读取，内存恒定 ~2MB）
   * - >10MB：全量解析（避免 byte offset 追踪错误）
   */
  static index(filePath: string, cachePath: string): TxtBookIndex {
    const fileSize = BookFile.size(filePath);
    if (fileSize <= 0) {
      return { cachePath, chapters: [] };
    }

    // 大文件退回全量解析，保证正确性
    if (fileSize > STREAM_INDEX_THRESHOLD) {
      hilog.info(0x0000, 'TxtParser', 'file %{public}s is %{public}d bytes, using fallback parser',
        filePath, fileSize);
      return TxtParser.indexFallback(filePath, cachePath);
    }

    // 小文件用流式索引
    return TxtParser.indexStreaming(filePath, cachePath, fileSize);
  }

  /**
   * 流式索引实现：按块读取，边读边匹配章节标题。
   * 仅用于 ≤10MB 的文件。
   */
  private static indexStreaming(filePath: string, cachePath: string, fileSize: number): TxtBookIndex {
    // 先探测编码（只读前 1KB）
    const probeLen = Math.min(1024, fileSize);
    const probeBytes = new Uint8Array(BookFile.readRange(filePath, 0, probeLen));
    const encoding = TextCodec.detectEncoding(probeBytes);

    const chapters: TxtChapterSpan[] = [];
    let offset = 0;           // 当前块在文件中的起始字节偏移
    let carryText = '';       // 跨块携带的未完整行（文本）
    let carryByteOffset = 0;  // carryText 在文件中的起始字节偏移
    let chapterStart = 0;     // 当前章起始字节偏移（原始文件）
    let currentTitle = '';    // 当前章标题
    let preTitleBuffer = '';  // 首个标题前的正文缓冲

    while (offset < fileSize) {
      const remaining = fileSize - offset;
      const readLen = Math.min(STREAM_BLOCK_SIZE, remaining);
      const chunkBytes = new Uint8Array(BookFile.readRange(filePath, offset, readLen));
      const chunkText = TextCodec.decodeAs(chunkBytes, encoding);

      // 拼接上一块的残留行
      const combined = carryText + chunkText;
      // 统一换行符
      const normalized = combined.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
      const lines = normalized.split('\n');

      // 最后一行可能不完整，留到下一块处理
      const isLastBlock = (offset + readLen >= fileSize);
      const processCount = isLastBlock ? lines.length : lines.length - 1;
      const leftover = isLastBlock ? '' : lines[lines.length - 1];

      // 计算 leftover 在文件中的起始字节偏移
      // leftover 是 lines 的最后一行，它前面的所有行的总字节数 = combined 总字节 - leftover 字节
      let leftoverStartOffset = offset; // 默认从当前块起始开始算
      if (carryText.length > 0) {
        // 如果有 carryText，leftoverStartOffset 要加上 carryText 的字节数
        const carryEncoded = TxtParser.utf8Encode(carryText);
        leftoverStartOffset += carryEncoded.byteLength;
      }
      // 再加上 processLines 的字节数
      for (let i = 0; i < processCount; i++) {
        const lineEnc = TxtParser.utf8Encode(lines[i] + '\n');
        leftoverStartOffset += lineEnc.byteLength;
      }

      // 逐行匹配章节标题
      for (let i = 0; i < processCount; i++) {
        const rawLine = lines[i];
        const line = rawLine.trim();

        if (TxtParser.isChapterTitle(line)) {
          // 关闭上一章（或首个标题前的正文）
          if (currentTitle.length > 0) {
            // 正常章节：byteEnd 指向新标题行的起始位置
            const titleLineStart = offset + this.calcLineByteOffset(lines, i, carryText, carryByteOffset, encoding);
            chapters.push({
              title: currentTitle,
              byteStart: chapterStart,
              byteEnd: titleLineStart,
            });
          } else if (chapters.length === 0) {
            // 第一个标题前的正文单独成章
            if (preTitleBuffer.length > 0) {
              const preTitleBytes = TxtParser.utf8Encode(preTitleBuffer.replace(/\r\n/g, '\n').replace(/\r/g, '\n'));
              chapters.push({
                title: '开始',
                byteStart: 0,
                byteEnd: preTitleBytes.byteLength,
              });
            }
          }
          currentTitle = line;
          const titleLineStart = offset + this.calcLineByteOffset(lines, i, carryText, carryByteOffset, encoding);
          chapterStart = titleLineStart;
          preTitleBuffer = ''; // 清空预缓冲
        } else {
          // 非标题行，累积到预缓冲（仅在还没遇到任何标题时）
          if (currentTitle.length === 0 && chapters.length === 0) {
            preTitleBuffer += rawLine + '\n';
          }
        }
      }

      // 更新状态
      carryText = leftover;
      carryByteOffset = leftoverStartOffset;
      offset += readLen;
    }

    // 处理最后一章
    if (currentTitle.length > 0) {
      chapters.push({
        title: currentTitle,
        byteStart: chapterStart,
        byteEnd: fileSize,
      });
    } else if (preTitleBuffer.length > 0 && chapters.length === 0) {
      // 整个文件没有标题，全部内容作为一章
      const preTitleBytes = TxtParser.utf8Encode(preTitleBuffer.replace(/\r\n/g, '\n').replace(/\r/g, '\n'));
      chapters.push({
        title: '开始',
        byteStart: 0,
        byteEnd: preTitleBytes.byteLength,
      });
    }

    // 如果没识别到章节，退化为全量解析
    if (chapters.length === 0) {
      return TxtParser.indexFallback(filePath, cachePath);
    }

    // 补空标题
    for (let i = 0; i < chapters.length; i++) {
      if (chapters[i].title.length === 0) {
        chapters[i].title = `第${i + 1}章`;
      }
    }

    // 写入缓存文件
    TxtParser.writeCacheFromSpans(cachePath, filePath, chapters, encoding);

    return { cachePath, chapters };
  }

  /**
   * 计算第 i 行在 combined 文本中的字节偏移（相对于 offset）。
   */
  private static calcLineByteOffset(lines: string[], lineIndex: number, 
                                     carryText: string, carryByteOffset: number,
                                     encoding: string): number {
    let byteOffset = 0;
    // 如果有 carryText，先加它的字节数
    if (carryText.length > 0 && lineIndex > 0) {
      const carryEncoded = TxtParser.utf8Encode(carryText);
      byteOffset += carryEncoded.byteLength;
    }
    // 累加前面所有行的字节数（含换行符）
    for (let j = 0; j < lineIndex; j++) {
      const lineEnc = TxtParser.utf8Encode(lines[j] + '\n');
      byteOffset += lineEnc.byteLength;
    }
    return byteOffset;
  }

  /**
   * 兜底方案：当流式索引未识别到章节时，退回全量读取+正则切分。
   * 仅在小文件或无章节结构的文本中触发。
   */
  private static indexFallback(filePath: string, cachePath: string): TxtBookIndex {
    const text = BookFile.readText(filePath).replace(/\r\n?/g, '\n');
    const sections: TxtSectionData[] = TxtParser.splitChapters(text);
    const chapters: TxtChapterSpan[] = TxtParser.writeCache(cachePath, sections);
    return { cachePath, chapters };
  }

  /**
   * 按章节区间从原文件读取并写入缓存，避免持有整本字符串。
   * 优化：先收集所有章节的 UTF-8 字节，再一次性写入，避免 O(n²) 追加。
   */
  private static writeCacheFromSpans(cachePath: string, srcPath: string, 
                                      chapters: TxtChapterSpan[], encoding: string): void {
    const dir = BookFile.dirName(cachePath);
    if (dir.length > 0) {
      BookFile.ensureDir(dir);
    }

    // 第一趟：逐章读取、解码、重新编码为 UTF-8，收集字节数组
    const parts: Uint8Array[] = [];
    let totalBytes = 0;
    for (let i = 0; i < chapters.length; i++) {
      const ch = chapters[i];
      const len = ch.byteEnd - ch.byteStart;
      if (len <= 0) {
        parts.push(new Uint8Array(0));
        continue;
      }

      const rawBytes = new Uint8Array(BookFile.readRange(srcPath, ch.byteStart, len));
      const text = TextCodec.decodeAs(rawBytes, encoding);
      const normalized = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
      const utf8Bytes = TxtParser.utf8Encode(normalized);

      // 更新区间为新的 UTF-8 缓存文件中的位置
      ch.byteStart = totalBytes;
      totalBytes += utf8Bytes.byteLength;
      ch.byteEnd = totalBytes;

      parts.push(utf8Bytes);
    }

    // 第二趟：合并所有部分，一次性写入
    const merged = new Uint8Array(totalBytes);
    let cursor = 0;
    for (let i = 0; i < parts.length; i++) {
      merged.set(parts[i], cursor);
      cursor += parts[i].byteLength;
    }
    const exact = merged.buffer.slice(merged.byteOffset, merged.byteOffset + merged.byteLength);
    BookFile.writeBytes(cachePath, exact);
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

  /**
   * UTF-8 编码（自带实现）。
   *
   * 不用 `util.TextEncoder`：实测在 ArkUI-X 的 Android 端，taskpool 子线程里
   * `encodeInto()` 返回 `undefined`（本任务正是跑在 taskpool 里），
   * 会在取 `byteLength` 时抛 `Cannot read property byteLength of undefined` → 开书失败。
   */
  private static utf8Encode(input: string): Uint8Array {
    let len: number = 0;
    for (let i = 0; i < input.length; i++) {
      const c: number = input.charCodeAt(i);
      if (c < 0x80) {
        len += 1;
      } else if (c < 0x800) {
        len += 2;
      } else if (c >= 0xD800 && c <= 0xDBFF) {
        len += 4;
        i++;
      } else {
        len += 3;
      }
    }
    const out: Uint8Array = new Uint8Array(len);
    let p: number = 0;
    for (let i = 0; i < input.length; i++) {
      const c: number = input.charCodeAt(i);
      if (c < 0x80) {
        out[p] = c;
        p += 1;
      } else if (c < 0x800) {
        out[p] = 0xC0 | (c >> 6);
        out[p + 1] = 0x80 | (c & 0x3F);
        p += 2;
      } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < input.length) {
        const lo: number = input.charCodeAt(i + 1);
        const cp: number = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00);
        i++;
        out[p] = 0xF0 | (cp >> 18);
        out[p + 1] = 0x80 | ((cp >> 12) & 0x3F);
        out[p + 2] = 0x80 | ((cp >> 6) & 0x3F);
        out[p + 3] = 0x80 | (cp & 0x3F);
        p += 4;
      } else {
        out[p] = 0xE0 | (c >> 12);
        out[p + 1] = 0x80 | ((c >> 6) & 0x3F);
        out[p + 2] = 0x80 | (c & 0x3F);
        p += 3;
      }
    }
    return out;
  }

  /** 各章按出现顺序紧挨着写入，区间互不重叠，因此章与章之间不需要分隔符。 */
  private static writeCache(cachePath: string, sections: TxtSectionData[]): TxtChapterSpan[] {
    const parts: Uint8Array[] = [];
    const spans: TxtChapterSpan[] = [];
    let cursor: number = 0;
    for (let i = 0; i < sections.length; i++) {
      const payload: string = sections[i].paragraphs.join('\n');
      const bytes: Uint8Array = TxtParser.utf8Encode(payload);
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
