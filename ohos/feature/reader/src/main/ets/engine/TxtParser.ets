import { BookFile } from './BookFile';
import { TextCodec } from './TextCodec';
import { hilog } from '@kit.PerformanceAnalysisKit';

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
/** 超大文件只解析前 50MB，避免「全文 + 缓存」同时驻留导致 OOM。 */
const MAX_PARSE_SIZE: number = 50 * 1024 * 1024;
/** 索引缓存格式版本：切章规则变化时 +1，旧索引自动失效。 */
const INDEX_VERSION: number = 1;

/** 切章结果：标题 + 在解码后全文中的字符区间（左闭右开），不复制正文。 */
export interface TxtSectionData {
  title: string;
  start: number;
  end: number;
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

/** 索引缓存：与格式版本、源文件 size/mtime、UTF-8 缓存的字节数绑定，任一不符即重建。 */
interface TxtIndexCache {
  version: number;
  size: number;
  mtime: number;
  bytes: number;
  chapters: TxtChapterSpan[];
}

export class TxtParser {
  /**
   * TXT 索引：读取（超大文件截断）→ 编码探测 → 按字符偏移切章 → 写 UTF-8 缓存。
   *
   * 章节只记字符区间，写入时再按区间取正文，避免为整本生成数万行字符串数组。
   * 章界连同源文件 size/mtime 存进 `.idx`：重开同一本书直接命中，不再解码与重写整本缓存。
   */
  static index(filePath: string, cachePath: string): TxtBookIndex {
    const fileSize: number = BookFile.size(filePath);
    if (fileSize <= 0) {
      return { cachePath, chapters: [] };
    }
    const mtime: number = BookFile.modifiedTime(filePath);
    const indexPath: string = `${cachePath}.idx`;
    const cached: TxtChapterSpan[] | null = TxtParser.readIndex(indexPath, cachePath, fileSize, mtime);
    if (cached !== null) {
      return { cachePath, chapters: cached };
    }
    let readSize: number = Math.min(fileSize, MAX_PARSE_SIZE);
    if (readSize < fileSize) {
      hilog.warn(0x0000, 'TxtParser', 'file %{public}s is %{public}d bytes (>50MB), parsing first 50MB only',
        filePath, fileSize);
      // 截在行边界上：UTF-8/GBK 的 0x0A 不会出现在多字节序列内部，
      // 否则截断尾部会让 UTF-8 校验失败、整本被误判成 GBK
      readSize = TxtParser.alignToLineBoundary(filePath, readSize);
    }
    let text: string = TextCodec.decode(BookFile.readRange(filePath, 0, readSize));
    if (text.length === 0) {
      return { cachePath, chapters: [] };
    }
    if (text.indexOf('\r') >= 0) {
      text = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    }
    if (readSize < fileSize) {
      // 退到最后一个完整行，丢掉可能被截断的半行
      const lastNewline: number = text.lastIndexOf('\n');
      if (lastNewline >= 0) {
        text = text.substring(0, lastNewline);
      }
    }
    const sections: TxtSectionData[] = TxtParser.splitChapters(text);
    const chapters: TxtChapterSpan[] = TxtParser.writeCache(cachePath, text, sections);
    TxtParser.writeIndex(indexPath, cachePath, fileSize, mtime, chapters);
    return { cachePath, chapters };
  }

  /**
   * 读索引缓存：源文件 size/mtime 与 UTF-8 缓存字节数全部对上才命中。
   * 缓存被清理、或上次写到一半就退出时，字节数对不上，自动退回全量解析。
   */
  private static readIndex(indexPath: string, cachePath: string, size: number, mtime: number): TxtChapterSpan[] | null {
    try {
      if (!BookFile.exists(indexPath)) {
        return null;
      }
      const data: TxtIndexCache = JSON.parse(BookFile.readText(indexPath)) as TxtIndexCache;
      if (data.version !== INDEX_VERSION || data.size !== size || data.mtime !== mtime) {
        return null;
      }
      if (!Array.isArray(data.chapters) || data.chapters.length === 0) {
        return null;
      }
      if (BookFile.size(cachePath) !== data.bytes) {
        return null;
      }
      return data.chapters;
    } catch (_error) {
      // 索引损坏时按未命中处理，不阻塞开书
      return null;
    }
  }

  /** 写索引缓存；写失败不影响开书（下次重新解析即可）。 */
  private static writeIndex(indexPath: string, cachePath: string, size: number, mtime: number,
    chapters: TxtChapterSpan[]): void {
    if (chapters.length === 0) {
      return;
    }
    try {
      const data: TxtIndexCache = {
        version: INDEX_VERSION,
        size: size,
        mtime: mtime,
        bytes: BookFile.size(cachePath),
        chapters: chapters,
      };
      const json: string = JSON.stringify(data);
      BookFile.writeBytes(indexPath, TxtParser.utf8Encode(json).buffer as ArrayBuffer);
    } catch (error) {
      hilog.warn(0x0000, 'TxtParser', 'write index failed: %{public}s', (error as Error).message);
    }
  }

  /** 从 `size` 向前找最后一个换行符，返回其后的字节位置（找不到时原样返回）。 */
  private static alignToLineBoundary(filePath: string, size: number): number {
    const window: number = 64 * 1024;
    const head: Uint8Array = new Uint8Array(BookFile.readRange(filePath, 0, 2));
    const utf16: boolean = head.length === 2 &&
      ((head[0] === 0xFF && head[1] === 0xFE) || (head[0] === 0xFE && head[1] === 0xFF));
    let end: number = size;
    while (end > 0) {
      const start: number = Math.max(0, end - window);
      const chunk: Uint8Array = new Uint8Array(BookFile.readRange(filePath, start, end - start));
      for (let i = chunk.length - 1; i >= 0; i--) {
        if (chunk[i] !== 0x0A) {
          continue;
        }
        let pos: number = start + i + 1;
        if (utf16 && pos % 2 !== 0) {
          // UTF-16 按 2 字节编码单元对齐，避免解码器吃到半个单元
          pos -= 1;
        }
        return pos;
      }
      end = start;
    }
    return size;
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
      } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < input.length) {
        // 必须与下面的写入分支一致：落单的高代理只按 3 字节写，
        // 若这里固定算 4 字节，尾部会多出未使用的 0x00 写进缓存
        const lo: number = input.charCodeAt(i + 1);
        if (lo >= 0xDC00 && lo <= 0xDFFF) {
          len += 4;
          i++;
        } else {
          len += 3;
        }
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
        if (lo >= 0xDC00 && lo <= 0xDFFF) {
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
  private static writeCache(cachePath: string, text: string, sections: TxtSectionData[]): TxtChapterSpan[] {
    const parts: Uint8Array[] = [];
    const spans: TxtChapterSpan[] = [];
    let cursor: number = 0;
    for (let i = 0; i < sections.length; i++) {
      const payload: string = TxtParser.sectionText(text, sections[i].start, sections[i].end);
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
    BookFile.writeBytes(cachePath, merged.buffer as ArrayBuffer);
    return spans;
  }

  /** 取章节区间的正文：逐行 trim、丢弃空行，用 '\n' 连接（缓存文件的段落分隔）。 */
  private static sectionText(text: string, start: number, end: number): string {
    const lines: string[] = [];
    let lineStart: number = start;
    while (lineStart < end) {
      let lineEnd: number = text.indexOf('\n', lineStart);
      if (lineEnd < 0 || lineEnd > end) {
        lineEnd = end;
      }
      const line: string = text.substring(lineStart, lineEnd).trim();
      if (line.length > 0) {
        lines.push(line);
      }
      lineStart = lineEnd + 1;
    }
    return lines.join('\n');
  }

  /** 按标题行切章；识别不到标题时退化为定长切节。 */
  private static splitChapters(text: string): TxtSectionData[] {
    const titleStarts: number[] = [];
    const contentStarts: number[] = [];
    const titleTexts: string[] = [];
    const n: number = text.length;
    let hasPreTitleContent: boolean = false;
    let lineStart: number = 0;
    while (lineStart < n) {
      let lineEnd: number = text.indexOf('\n', lineStart);
      if (lineEnd < 0) {
        lineEnd = n;
      }
      // 章节标题必然很短：先按原始行长度过滤，正文长行连子串都不生成
      if (lineEnd - lineStart <= MAX_TITLE_LENGTH + 16) {
        const line: string = text.substring(lineStart, lineEnd).trim();
        if (TxtParser.isChapterTitle(line)) {
          titleStarts.push(lineStart);
          contentStarts.push(lineEnd + 1);
          titleTexts.push(line);
        } else if (titleTexts.length === 0 && line.length > 0) {
          hasPreTitleContent = true;
        }
      } else if (titleTexts.length === 0) {
        hasPreTitleContent = true;
      }
      lineStart = lineEnd + 1;
    }
    // 只认出一个标题且前面没有正文时，多半不是分章文件，退回定长切节
    if (titleTexts.length === 0 || (titleTexts.length === 1 && !hasPreTitleContent)) {
      return TxtParser.chunkByLength(text);
    }
    const sections: TxtSectionData[] = [];
    // 首个标题之前若有正文，单独作为「开始」章节保留，避免丢内容
    if (hasPreTitleContent) {
      sections.push({ title: '开始', start: 0, end: titleStarts[0] });
    }
    for (let i = 0; i < titleTexts.length; i++) {
      sections.push({
        title: titleTexts[i],
        start: contentStarts[i],
        end: i + 1 < titleTexts.length ? titleStarts[i + 1] : n,
      });
    }
    return sections;
  }

  private static isChapterTitle(line: string): boolean {
    if (line.length === 0 || line.length > MAX_TITLE_LENGTH) {
      return false;
    }
    return CHAPTER_PATTERN.test(line);
  }

  /** 无章节标题时的兜底切分（按行边界切成约 `FALLBACK_CHUNK_CHARS` 字一节）。 */
  private static chunkByLength(text: string): TxtSectionData[] {
    const sections: TxtSectionData[] = [];
    const n: number = text.length;
    let chunkStart: number = 0;
    let part: number = 1;
    let lineStart: number = 0;
    while (lineStart < n) {
      let lineEnd: number = text.indexOf('\n', lineStart);
      if (lineEnd < 0) {
        lineEnd = n;
      }
      if (lineEnd - chunkStart >= FALLBACK_CHUNK_CHARS) {
        sections.push({ title: `第${part}节`, start: chunkStart, end: lineEnd });
        chunkStart = lineEnd + 1;
        part++;
      }
      lineStart = lineEnd + 1;
    }
    if (chunkStart < n) {
      sections.push({ title: `第${part}节`, start: chunkStart, end: n });
    }
    if (sections.length === 0) {
      sections.push({ title: '开始', start: 0, end: 0 });
    }
    return sections;
  }
}
