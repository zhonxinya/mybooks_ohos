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
 * 章节标题行：中文小说常见写法（第X章/节/回/卷/部/篇/集/幕/话 + 序章/楔子/番外 等），
 * 兼容「正文」前缀、半角/全角数字、以及 "Chapter 12" 这类外文写法。
 *
 * 标题行尾的句号、感叹号、括号（【第一章】、第1章（求收藏））在识别前会被去掉，
 * 正文句子里提到「第三章 …。」则因句中仍含句末标点被排除——避免误判又不漏真标题。
 */
const CHAPTER_PATTERN: RegExp = new RegExp(
  '^(?:正文[\\s　:：\\-—]*)?(?:' +
    '第[\\s　]*[0-9０-９零〇一二三四五六七八九十百千万两]{1,12}[\\s　]*[章节回卷部篇集幕话]' +
    '|[卷部篇集][\\s　]*[0-9０-９零〇一二三四五六七八九十百千两]{1,6}' +
    // 单个「序」只有带分隔符才是标题；「序列化数据」这类正文行随之排除
    '|序(?=[\\s　:：、，,·\\-—（(【\\[])' +
    // 关键字标题要么独占一行，要么用分隔符接副标题；「外传小道消息」是正文
    '|(?:序章|序言|楔子|引子|前言|后记|尾声|终章|结局|番外篇|番外|外传)(?=[\\s　:：、，,·\\-—（(【\\[]|$)' +
  ')' +
  // 章号后紧跟「的/了/是/他…」多半是正文句子（「第三章的内容让他震惊」），不是标题
  '(?![的了吗呢是在他她它们这那中里后时被把让就也和与为有没不])' +
  '[^\\n]{0,60}$' +
  // 外文标题：Chapter 12 / Chapter 1: The Boy（副标题须以大写开头，「Chapter 1 is long.」是正文）
  '|^(?:正文[\\s　:：\\-—]*)?[Cc]hapter[\\s　]*[0-9IVXLCivxlc]{1,6}' +
  '(?:[\\s　:：.\\-—]+[A-Z][^\\n]{0,50})?$');
/** 只有关键字、没有副标题的独立标题行（「序：」这类结尾冒号在识别前会被去掉）。 */
const BARE_TITLES: string[] = ['序', '序章', '序言', '楔子', '引子', '前言', '后记',
  '尾声', '终章', '结局', '番外', '外传'];
/** 句末标点：真标题只会出现在结尾（已被去掉），句中还有说明是正文句子。 */
const SENTENCE_PUNCT: RegExp = new RegExp('[。！？!?]');
const MAX_TITLE_LENGTH: number = 80;
/** 无法识别章节时，按固定字数切节，避免整本变成一个巨大章节。 */
const FALLBACK_CHUNK_CHARS: number = 3000;
/** 超大文件只解析前 50MB，避免「全文 + 缓存」同时驻留导致 OOM。 */
const MAX_PARSE_SIZE: number = 50 * 1024 * 1024;
/** 索引缓存格式版本：切章规则变化时 +1，旧索引自动失效。 */
const INDEX_VERSION: number = 2;

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
    const len: number = TxtParser.byteLengthOfRange(input, 0, input.length);
    const out: Uint8Array = new Uint8Array(len);
    TxtParser.encodeRange(input, 0, input.length, out, 0);
    return out;
  }

  /** 统计 `[start, end)` 的 UTF-8 字节数；代理对判定必须与 `encodeRange` 完全一致。 */
  private static byteLengthOfRange(input: string, start: number, end: number): number {
    let len: number = 0;
    for (let i = start; i < end; i++) {
      const c: number = input.charCodeAt(i);
      if (c < 0x80) {
        len += 1;
      } else if (c < 0x800) {
        len += 2;
      } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < end) {
        // 落单的高代理只按 3 字节写；若这里固定算 4 字节，尾部会多出 0x00
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
    return len;
  }

  /** 把 `[start, end)` 编码写入 `out` 的 `offset` 处，返回写入后的偏移。 */
  private static encodeRange(input: string, start: number, end: number, out: Uint8Array, offset: number): number {
    let p: number = offset;
    for (let i = start; i < end; i++) {
      const c: number = input.charCodeAt(i);
      if (c < 0x80) {
        out[p] = c;
        p += 1;
      } else if (c < 0x800) {
        out[p] = 0xC0 | (c >> 6);
        out[p + 1] = 0x80 | (c & 0x3F);
        p += 2;
      } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < end) {
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
    return p;
  }

  /** 与 `String.prototype.trim` 对齐的空白字符（含全角空格、BOM、零宽不换行空格）。 */
  private static isSpace(c: number): boolean {
    if (c <= 0x20) {
      return true;
    }
    if (c < 0xA0) {
      return false;
    }
    return c === 0xA0 || c === 0x1680 || (c >= 0x2000 && c <= 0x200A) ||
      c === 0x2028 || c === 0x2029 || c === 0x202F || c === 0x205F ||
      c === 0x3000 || c === 0xFEFF;
  }

  /**
   * 各章按出现顺序紧挨着写入，区间互不重叠，因此章与章之间不需要分隔符。
   *
   * 先统计总字节数、一次分配合并缓冲，再直接按区间编码写入：
   * 不再为每章生成正文字符串、UTF-8 缓冲与合并副本，峰值内存和拷贝次数都明显下降。
   */
  private static writeCache(cachePath: string, text: string, sections: TxtSectionData[]): TxtChapterSpan[] {
    let total: number = 0;
    for (let i = 0; i < sections.length; i++) {
      total += TxtParser.sectionByteLength(text, sections[i].start, sections[i].end);
    }
    const merged: Uint8Array = new Uint8Array(total);
    const spans: TxtChapterSpan[] = [];
    let cursor: number = 0;
    for (let i = 0; i < sections.length; i++) {
      const byteStart: number = cursor;
      cursor = TxtParser.encodeSection(text, sections[i].start, sections[i].end, merged, cursor);
      spans.push({ title: sections[i].title, byteStart: byteStart, byteEnd: cursor });
    }
    const dir: string = BookFile.dirName(cachePath);
    if (dir.length > 0) {
      BookFile.ensureDir(dir);
    }
    BookFile.writeBytes(cachePath, merged.buffer as ArrayBuffer);
    return spans;
  }

  /**
   * 章节正文的缓存字节数：逐行去掉首尾空白、丢弃空行、行间补一个 '\n'。
   * 与 `encodeSection` 共用同一套行遍历规则，先量后写，无需中间字符串。
   */
  private static sectionByteLength(text: string, start: number, end: number): number {
    let total: number = 0;
    let hasLine: boolean = false;
    let lineStart: number = start;
    while (lineStart < end) {
      let lineEnd: number = text.indexOf('\n', lineStart);
      if (lineEnd < 0 || lineEnd > end) {
        lineEnd = end;
      }
      let s: number = lineStart;
      let e: number = lineEnd;
      while (s < e && TxtParser.isSpace(text.charCodeAt(s))) {
        s++;
      }
      while (e > s && TxtParser.isSpace(text.charCodeAt(e - 1))) {
        e--;
      }
      if (e > s) {
        if (hasLine) {
          total += 1;
        }
        total += TxtParser.byteLengthOfRange(text, s, e);
        hasLine = true;
      }
      lineStart = lineEnd + 1;
    }
    return total;
  }

  /** 把章节正文直接编码进合并缓冲，返回写入后的偏移（规则与 `sectionByteLength` 一致）。 */
  private static encodeSection(text: string, start: number, end: number, out: Uint8Array, offset: number): number {
    let p: number = offset;
    let hasLine: boolean = false;
    let lineStart: number = start;
    while (lineStart < end) {
      let lineEnd: number = text.indexOf('\n', lineStart);
      if (lineEnd < 0 || lineEnd > end) {
        lineEnd = end;
      }
      let s: number = lineStart;
      let e: number = lineEnd;
      while (s < e && TxtParser.isSpace(text.charCodeAt(s))) {
        s++;
      }
      while (e > s && TxtParser.isSpace(text.charCodeAt(e - 1))) {
        e--;
      }
      if (e > s) {
        if (hasLine) {
          out[p] = 0x0A;
          p++;
        }
        p = TxtParser.encodeRange(text, s, e, out, p);
        hasLine = true;
      }
      lineStart = lineEnd + 1;
    }
    return p;
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
        // 再按首个非空白字符预筛：正文行绝大多数不以「第/序/楔/引…」开头，
        // 这样就不用为每一行生成子串、跑正则
        let s: number = lineStart;
        while (s < lineEnd) {
          const c: number = text.charCodeAt(s);
          if (!TxtParser.isSpace(c) && !TxtParser.isTitleOpenBracket(c)) {
            break;
          }
          s++;
        }
        const empty: boolean = s >= lineEnd;
        const maybeTitle: boolean = !empty && TxtParser.isTitlePrefix(text.charCodeAt(s));
        if (maybeTitle) {
          const line: string = text.substring(lineStart, lineEnd).trim();
          if (TxtParser.isChapterTitle(line)) {
            titleStarts.push(lineStart);
            contentStarts.push(lineEnd + 1);
            titleTexts.push(line);
          } else if (titleTexts.length === 0) {
            // 以「第…」等开头但不是标题的正文行，同样算首个标题前的内容
            hasPreTitleContent = true;
          }
        } else if (!empty && titleTexts.length === 0) {
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

  /** 标题候选首字（与 `CHAPTER_PATTERN` 的各分支一一对应）。 */
  private static isTitlePrefix(c: number): boolean {
    switch (c) {
      case 0x7B2C: // 第
      case 0x5377: // 卷
      case 0x90E8: // 部
      case 0x7BC7: // 篇
      case 0x96C6: // 集
      case 0x5E8F: // 序
      case 0x6954: // 楔
      case 0x5F15: // 引
      case 0x524D: // 前
      case 0x540E: // 后
      case 0x5C3E: // 尾
      case 0x7EC8: // 终
      case 0x756A: // 番
      case 0x5916: // 外
      case 0x6B63: // 正（正文 第1章）
      case 0x0043: // C
      case 0x0063: // c
        return true;
      default:
        return false;
    }
  }

  /** 标题行开头的括注符号（【第一章】、[第1章]），不是引号——避免把对话行当标题。 */
  private static isTitleOpenBracket(c: number): boolean {
    return c === 0x3010 || c === 0x005B || c === 0xFF08 || c === 0x0028;
  }

  /** 标题行尾可安全剥掉的标点/连字符：真标题的句末点号常被作者误加。 */
  private static isTitleTailNoise(c: number): boolean {
    switch (c) {
      case 0x3002: // 。
      case 0xFF01: // ！
      case 0xFF1F: // ？
      case 0x0021: // !
      case 0x003F: // ?
      case 0xFF0C: // ，
      case 0x002C: // ,
      case 0x3001: // 、
      case 0xFF1A: // ：
      case 0x003A: // :
      case 0xFF1B: // ；
      case 0x003B: // ;
      case 0x00B7: // ·
      case 0x2026: // …
      case 0x2014: // —
      case 0xFF0D: // －
      case 0x002D: // -
      case 0x005F: // _
      case 0x002E: // .
      case 0xFF0E: // ．
        return true;
      default:
        return false;
    }
  }

  /** 去掉标题行首的空白与【[（( 括注。 */
  private static stripTitleHead(line: string): string {
    let start: number = 0;
    while (start < line.length) {
      const c: number = line.charCodeAt(start);
      if (!TxtParser.isSpace(c) && !TxtParser.isTitleOpenBracket(c)) {
        break;
      }
      start++;
    }
    return start === 0 ? line : line.substring(start);
  }

  /**
   * 去掉标题行尾的标点、空白与括号注释（「第一章 初见。（求收藏）」）。
   * 只剥成对出现的括号注释，避免把正文尾巴当成标题的一部分。
   */
  private static stripTitleTail(line: string): string {
    let end: number = line.length;
    while (end > 0) {
      const c: number = line.charCodeAt(end - 1);
      if (TxtParser.isSpace(c) || TxtParser.isTitleTailNoise(c)) {
        end--;
        continue;
      }
      let open: number = -1;
      if (c === 0xFF09) {
        open = line.lastIndexOf('（', end - 1);
      } else if (c === 0x0029) {
        open = line.lastIndexOf('(', end - 1);
      } else if (c === 0x3011) {
        open = line.lastIndexOf('【', end - 1);
      } else if (c === 0x005D) {
        open = line.lastIndexOf('[', end - 1);
      }
      if (open >= 0) {
        end = open;
        continue;
      }
      break;
    }
    return end === line.length ? line : line.substring(0, end);
  }

  private static isChapterTitle(line: string): boolean {
    if (line.length === 0 || line.length > MAX_TITLE_LENGTH) {
      return false;
    }
    const body: string = TxtParser.stripTitleTail(TxtParser.stripTitleHead(line));
    if (body.length === 0) {
      return false;
    }
    // 句中还有句末标点说明是正文句子；标题的句末点号已在 stripTitleTail 去掉
    if (SENTENCE_PUNCT.test(body)) {
      return false;
    }
    if (BARE_TITLES.indexOf(body.replace(/\s/g, '')) >= 0) {
      return true;
    }
    return CHAPTER_PATTERN.test(body);
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
