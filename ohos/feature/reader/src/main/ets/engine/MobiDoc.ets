/**
 * MOBI（Mobipocket，KF7）容器解析：PDB 记录表 → MOBI/EXTH 头 → 正文拼装 → 章节切分。
 *
 * **纯计算，无平台依赖**（解码走 `TextCodec`），因此可以在 taskpool 子线程里跑，
 * 也方便脱离设备做回归比对。仅供 `MobiEngine` 调用。
 *
 * 文件结构（依据 MobileRead 的 PDB / MOBI 格式文档）：
 * - Palm Database 头 78 字节 + 每条记录 8 字节的记录表（偏移 4 + 属性 1 + UID 3）；
 *   记录表之后另有 2 字节填充，第一条记录数据从 `78 + 8 * N + 2` 开始；
 * - 记录 0 = PalmDOC 头（16 字节）+ MOBI 头（'MOBI' 起算）+ EXTH（元数据）；
 * - 记录 1..textRecordCount = 压缩正文；其后是图片等资源记录；
 * - 目录（KF7）通常是一个 HTML 目录页，条目形如 `<a filepos=0000030995>第一章</a>`，
 *   `filepos` 是**正文字节偏移**，所以章节切分全按字节做，避免与字符偏移混淆。
 */
import { TextCodec } from './TextCodec';
import { MarkupText } from './MarkupText';
import { PalmDoc } from './PalmDoc';

/** PDB 头长度（记录表紧随其后）。 */
const PDB_HEADER_BYTES: number = 78;
/** PalmDOC 头长度（MOBI 头从记录 0 的该偏移开始）。 */
const PALMDOC_HEADER_BYTES: number = 16;
/** 尾部数据标志字段偏移（MOBI 头 0xF0 是填充，0xF2 才是标志）。 */
const TRAILDATA_FLAGS_OFFSET: number = 0xF2;
/** 书名/目录项的最大展示长度。 */
const MAX_TITLE_LENGTH: number = 40;
/** 目录项少于该数量时认为目录页不可用，改用 `<mbp:pagebreak>` 切章。 */
const MIN_TOC_MARKS: number = 3;
/** 首个目录项之前若不足该字节数（通常只有 `<head>`/`<guide>`）就不单独成章。 */
const MIN_LEAD_BYTES: number = 1024;
/** 从章节开头取样多少字节来推断标题（仅在回退切章时使用）。 */
const TITLE_SAMPLE_BYTES: number = 512;
/** 扫描 `<reference>` 的最大范围（只需覆盖文件头部的 guide）。 */
const GUIDE_SCAN_LIMIT: number = 65536;
/** `<reference>` 标签的取样长度（文件里的标签都远小于它）。 */
const TAG_SAMPLE_BYTES: number = 512;
/** 首个目录项之前那段正文的标题。 */
const START_TITLE: string = '开始';

/** MOBI 头解析结果（字段均已做边界检查，缺失时为 0）。 */
export interface MobiInfo {
  /** 书名（MOBI 头里的全名）。 */
  title: string;
  /** 压缩方式，见 `PalmDoc.COMPRESSION_*`。 */
  compression: number;
  /** 正文解压后的总字节数。 */
  textLength: number;
  /** 正文记录条数。 */
  textRecordCount: number;
  /** 加密方式：0 表示未加密。 */
  encryption: number;
  /** MOBI 版本：6 = KF7，8 = KF8（AZW3）。 */
  version: number;
  /** 文本编码代码页（65001 = UTF-8，1252 = Windows-1252）。 */
  codepage: number;
  /** 首个资源（图片）记录号；`recindex` 相对它计数（从 1 开始）。 */
  firstResource: number;
  /** HUFF/CDIC 记录条数（非 0 表示用了 Huffman 压缩）。 */
  huffCount: number;
  /** 每条记录尾部数据块个数。 */
  trailers: number;
  /** 记录末尾是否额外挂着「多字节字符重叠」数据。 */
  multibyte: boolean;
  /** KF8 部分的起始记录号（0 表示纯 KF7）。 */
  kf8Boundary: number;
}

/** 章节（按正文字节范围切分）。 */
export interface MobiSection {
  title: string;
  /** 起始字节偏移（含）。 */
  start: number;
  /** 结束字节偏移（不含）。 */
  end: number;
}

/** 解析一本书所需的全部结果（也是 taskpool 任务的返回结构）。 */
export interface MobiDocData {
  info: MobiInfo;
  /** 记录偏移表，长度 = 记录数 + 1（末位为文件长度）。 */
  records: number[];
  /** 解压后的正文（长度 = info.textLength）。 */
  text: ArrayBuffer;
  sections: MobiSection[];
}

export class MobiDoc {
  /** PDB 头长度：读记录表之前先读这么多字节。 */
  static readonly HEADER_BYTES: number = PDB_HEADER_BYTES;

  /** 读取 PDB 头即可拿到的记录数。 */
  static recordCount(head: Uint8Array): number {
    if (head.length < PDB_HEADER_BYTES) {
      throw new Error('不是有效的 MOBI 文件（文件过短）');
    }
    if (MobiDoc.ascii(head, 60, 8) !== 'BOOKMOBI') {
      throw new Error('不是有效的 MOBI 文件（缺少 BOOKMOBI 标识）');
    }
    const count: number = MobiDoc.u16(head, 76);
    if (count <= 0) {
      throw new Error('MOBI 记录表为空');
    }
    return count;
  }

  /** 解析记录偏移表，返回「记录数 + 1」个偏移，末位补文件长度作哨兵。 */
  static recordOffsets(list: Uint8Array, recordCount: number, fileLength: number): number[] {
    const offsets: number[] = [];
    for (let i = 0; i < recordCount; i++) {
      offsets.push(MobiDoc.u32(list, i * 8));
    }
    offsets.push(fileLength);
    return offsets;
  }

  /** 解析记录 0：PalmDOC 头 + MOBI 头 + EXTH。不支持的情形直接抛出可展示的错误。 */
  static parse(records: number[], record0: Uint8Array): MobiInfo {
    if (record0.length < PALMDOC_HEADER_BYTES + 8) {
      throw new Error('MOBI 文件头不完整');
    }
    if (MobiDoc.ascii(record0, PALMDOC_HEADER_BYTES, 4) !== 'MOBI') {
      throw new Error('不是有效的 MOBI 文件（缺少 MOBI 头）');
    }
    const info: MobiInfo = {
      title: '',
      compression: MobiDoc.u16(record0, 0),
      textLength: MobiDoc.u32(record0, 4),
      textRecordCount: MobiDoc.u16(record0, 8),
      encryption: MobiDoc.u16(record0, 12),
      version: MobiDoc.u32(record0, 0x24),
      codepage: MobiDoc.u32(record0, 0x1C),
      firstResource: MobiDoc.u32(record0, 0x6C),
      huffCount: MobiDoc.u32(record0, 0x74),
      trailers: 0,
      multibyte: false,
      kf8Boundary: 0,
    };
    const headerLength: number = MobiDoc.u32(record0, 0x14);
    const titleOffset: number = MobiDoc.u32(record0, 0x54);
    const titleLength: number = MobiDoc.u32(record0, 0x58);
    if (titleLength > 0 && titleOffset + titleLength <= record0.length) {
      info.title = MobiDoc.decode(record0.subarray(titleOffset, titleOffset + titleLength),
        info.codepage).trim();
    }
    const trailingFlags: number = MobiDoc.u16(record0, TRAILDATA_FLAGS_OFFSET);
    if (headerLength >= 0xE4 && info.version >= 5) {
      info.multibyte = (trailingFlags & 0x01) !== 0;
      info.trailers = (trailingFlags & 0x02) !== 0 ? 1 : 0;
    }
    const boundary: Uint8Array | null = MobiDoc.exthValue(record0, headerLength, 121);
    if (boundary !== null && boundary.length >= 4) {
      info.kf8Boundary = MobiDoc.u32(boundary, 0);
    }
    MobiDoc.validate(info, records);
    return info;
  }

  /** 把不支持/损坏的情形拦在打开阶段，避免读到一半才报错。 */
  private static validate(info: MobiInfo, records: number[]): void {
    if (info.encryption !== 0) {
      throw new Error('这本书带有 DRM 保护，内置阅读器无法打开');
    }
    if (info.compression === PalmDoc.COMPRESSION_HUFF || info.huffCount > 0) {
      throw new Error('这本书使用 HUFF/CDIC 压缩，内置阅读器暂不支持');
    }
    if (info.compression !== PalmDoc.COMPRESSION_PALMDOC &&
      info.compression !== PalmDoc.COMPRESSION_NONE) {
      throw new Error(`不支持的 MOBI 压缩方式（${info.compression}）`);
    }
    if (info.version >= 8 && info.kf8Boundary === 0) {
      throw new Error('这本书是 KF8（AZW3）格式，内置阅读器暂不支持');
    }
    if (info.textRecordCount <= 0 || info.textLength <= 0) {
      throw new Error('这本书没有可阅读的正文');
    }
    if (records.length <= info.textRecordCount + 1) {
      throw new Error('MOBI 记录表不完整');
    }
  }

  /**
   * 拼装正文：按记录表逐条裁剪尾部数据 → 解压 → 顺序拼接，并截断到头部声明的长度。
   * `payload` 是正文记录在文件中的连续字节，`base` 为其起始文件偏移。
   */
  static assembleText(payload: Uint8Array, base: number, records: number[], info: MobiInfo): Uint8Array {
    const out: Uint8Array = new Uint8Array(info.textLength);
    let written: number = 0;
    const count: number = Math.min(info.textRecordCount, records.length - 1);
    for (let i = 1; i <= count && written < out.length; i++) {
      const from: number = records[i] - base;
      const to: number = records[i + 1] - base;
      if (from < 0 || to > payload.length || to <= from) {
        continue;
      }
      let chunk: Uint8Array = PalmDoc.trimRecord(payload.subarray(from, to), info.trailers, info.multibyte);
      if (info.compression === PalmDoc.COMPRESSION_PALMDOC) {
        chunk = PalmDoc.decompress(chunk);
      }
      const size: number = Math.min(chunk.length, out.length - written);
      out.set(chunk.subarray(0, size), written);
      written += size;
    }
    return written === out.length ? out : out.subarray(0, written);
  }

  /** 章节切分：优先用目录页的 `filepos` 条目，取不到时按 `<mbp:pagebreak>` 切。 */
  static sections(info: MobiInfo, text: Uint8Array): MobiSection[] {
    const marks: MobiSection[] = MobiDoc.tocSections(info, text);
    if (marks.length >= MIN_TOC_MARKS) {
      return MobiDoc.layout(marks, text.length);
    }
    return MobiDoc.pagebreakSections(info, text);
  }

  /** 目录页（`<guide>` 里 type="toc" 的 filepos 指向的页面）里的章节条目。 */
  private static tocSections(info: MobiInfo, text: Uint8Array): MobiSection[] {
    const tocStart: number = MobiDoc.tocOffset(text);
    if (tocStart <= 0 || tocStart >= text.length) {
      return [];
    }
    const nextBreak: number = MobiDoc.indexOf(text, '<mbp:pagebreak', tocStart);
    const end: number = nextBreak < 0 ? text.length : nextBreak;
    const region: string = MobiDoc.decode(text.subarray(tocStart, end), info.codepage);
    const pattern: RegExp = /<a\s[^>]*filepos\s*=\s*"?(\d+)"?[^>]*>([\s\S]*?)<\/a>/gi;
    const marks: MobiSection[] = [];
    const seen: number[] = [];
    let match: RegExpExecArray | null = pattern.exec(region);
    while (match !== null) {
      const offset: number = Number.parseInt(match[1], 10);
      const title: string = MobiDoc.cleanLabel(match[2]);
      if (!Number.isNaN(offset) && offset > 0 && offset < text.length &&
        title.length > 0 && seen.indexOf(offset) < 0) {
        seen.push(offset);
        marks.push({ title: title, start: offset, end: 0 });
      }
      match = pattern.exec(region);
    }
    marks.sort((left: MobiSection, right: MobiSection): number => left.start - right.start);
    return marks;
  }

  /** `<guide><reference type="toc" filepos=...>` 里的目录页偏移（找不到返回 0）。 */
  private static tocOffset(text: Uint8Array): number {
    const limit: number = Math.min(text.length, GUIDE_SCAN_LIMIT);
    let from: number = 0;
    while (from < limit) {
      const at: number = MobiDoc.indexOf(text, '<reference', from);
      if (at < 0 || at >= limit) {
        break;
      }
      const tag: string = MobiDoc.decode(text.subarray(at, Math.min(text.length, at + TAG_SAMPLE_BYTES)), 1252);
      const typeMatch: RegExpExecArray | null = /type\s*=\s*"?([A-Za-z]+)"?/i.exec(tag);
      if (typeMatch !== null && typeMatch[1].toLowerCase() === 'toc') {
        const filepos: RegExpExecArray | null = /filepos\s*=\s*"?(\d+)"?/i.exec(tag);
        if (filepos !== null) {
          const value: number = Number.parseInt(filepos[1], 10);
          if (!Number.isNaN(value) && value > 0 && value < text.length) {
            return value;
          }
        }
      }
      from = at + 10;
    }
    return 0;
  }

  /** 回退切章：`<mbp:pagebreak>` 是 MOBI 的硬分页标记，标题取该节开头的第一段文字。 */
  private static pagebreakSections(info: MobiInfo, text: Uint8Array): MobiSection[] {
    const bounds: number[] = [0];
    let from: number = 0;
    while (from < text.length) {
      const at: number = MobiDoc.indexOf(text, '<mbp:pagebreak', from);
      if (at < 0) {
        break;
      }
      const tagEnd: number = MobiDoc.indexOf(text, '>', at);
      const after: number = tagEnd < 0 ? at : tagEnd + 1;
      if (after > bounds[bounds.length - 1]) {
        bounds.push(after);
      }
      from = after > at ? after : at + 1;
    }
    bounds.push(text.length);
    const sections: MobiSection[] = [];
    for (let i = 0; i + 1 < bounds.length; i++) {
      if (bounds[i + 1] <= bounds[i]) {
        continue;
      }
      sections.push({
        title: MobiDoc.sectionTitle(info, text, bounds[i], bounds[i + 1], sections.length),
        start: bounds[i],
        end: bounds[i + 1],
      });
    }
    return sections;
  }

  /** 把「章节起点列表」补成首尾相接的章节区间。 */
  private static layout(marks: MobiSection[], textLength: number): MobiSection[] {
    const unique: MobiSection[] = [];
    for (let i = 0; i < marks.length; i++) {
      if (unique.length === 0 || marks[i].start > unique[unique.length - 1].start) {
        unique.push(marks[i]);
      }
    }
    const sections: MobiSection[] = [];
    if (unique.length === 0) {
      return sections;
    }
    // 第一个目录项之前的正文（封面/版权页）单独成章，但只有 `<head>` 时不值得占一章
    if (unique[0].start >= MIN_LEAD_BYTES) {
      sections.push({ title: START_TITLE, start: 0, end: unique[0].start });
    }
    for (let i = 0; i < unique.length; i++) {
      const end: number = i + 1 < unique.length ? unique[i + 1].start : textLength;
      if (end <= unique[i].start) {
        continue;
      }
      sections.push({ title: unique[i].title, start: unique[i].start, end: end });
    }
    if (sections.length === 0) {
      sections.push({ title: START_TITLE, start: 0, end: textLength });
    }
    return sections;
  }

  /** 取一节开头的文字做标题（回退切章用）。 */
  private static sectionTitle(info: MobiInfo, text: Uint8Array, start: number, end: number,
    index: number): string {
    const size: number = Math.min(end - start, TITLE_SAMPLE_BYTES);
    const title: string = MobiDoc.cleanLabel(MobiDoc.decode(text.subarray(start, start + size), info.codepage));
    return title.length > 0 ? title : `第${index + 1}节`;
  }

  /**
   * 取一节正文：目录项的偏移偶尔落在标签中间，先把前半截标签丢掉再解码，
   * 否则正文开头会出现 `height="2em">` 这类残渣。
   */
  static decodeSection(bytes: Uint8Array, codepage: number): string {
    let start: number = 0;
    let from: number = 0;
    while (from < bytes.length) {
      const at: number = bytes.indexOf(0x3C, from);
      if (at < 0) {
        break;
      }
      const next: number = at + 1 < bytes.length ? bytes[at + 1] : 0;
      const isTag: boolean = (next >= 0x41 && next <= 0x5A) || (next >= 0x61 && next <= 0x7A) ||
        next === 0x2F || next === 0x21;
      if (isTag) {
        start = at;
        break;
      }
      from = at + 1;
    }
    return MobiDoc.decode(bytes.subarray(start), codepage);
  }

  /** 章节里引用到的图片资源序号（HTML `recindex`，按出现顺序去重）。 */
  static imageRecords(html: string): number[] {
    const tags: RegExp = /<img\b[^>]*>/gi;
    const out: number[] = [];
    let match: RegExpExecArray | null = tags.exec(html);
    while (match !== null) {
      const recindex: RegExpExecArray | null = /recindex\s*=\s*"?(\d+)"?/i.exec(match[0]);
      if (recindex !== null) {
        const value: number = Number.parseInt(recindex[1], 10);
        if (!Number.isNaN(value) && value > 0 && out.indexOf(value) < 0) {
          out.push(value);
        }
      }
      match = tags.exec(html);
    }
    return out;
  }

  /**
   * 把 `<img recindex=...>` 换成沙箱里的真实图片路径。
   * 解不出的图片（记录缺失/格式未知）直接去掉标签，避免正文里留下空占位。
   */
  static replaceImageRecords(html: string, paths: Map<number, string>): string {
    return html.replace(/<img\b[^>]*>/gi, (tag: string): string => {
      const recindex: RegExpExecArray | null = /recindex\s*=\s*"?(\d+)"?/i.exec(tag);
      if (recindex === null) {
        return tag;
      }
      const path: string | undefined = paths.get(Number.parseInt(recindex[1], 10));
      if (path === undefined) {
        return '';
      }
      return tag.replace(/recindex\s*=\s*"?\d+"?/i, `src="${path}"`);
    });
  }

  /** 图片记录里图片数据的起始位置（少数文件在图片前有额外头部），找不到返回 -1。 */
  static imageStart(data: Uint8Array): number {
    const limit: number = Math.min(data.length - 4, 16);
    for (let i = 0; i <= limit; i++) {
      if (data[i] === 0xFF && data[i + 1] === 0xD8 && data[i + 2] === 0xFF) {
        return i;
      }
      if (data[i] === 0x89 && data[i + 1] === 0x50 && data[i + 2] === 0x4E && data[i + 3] === 0x47) {
        return i;
      }
      if (data[i] === 0x47 && data[i + 1] === 0x49 && data[i + 2] === 0x46) {
        return i;
      }
      if (data[i] === 0x42 && data[i + 1] === 0x4D) {
        return i;
      }
    }
    return -1;
  }

  /** 图片记录的文件扩展名（未知格式返回空串）。 */
  static imageExtension(data: Uint8Array, start: number): string {
    if (start < 0 || start + 2 >= data.length) {
      return '';
    }
    if (data[start] === 0xFF && data[start + 1] === 0xD8) {
      return 'jpg';
    }
    if (data[start] === 0x89 && data[start + 1] === 0x50) {
      return 'png';
    }
    if (data[start] === 0x47 && data[start + 1] === 0x49) {
      return 'gif';
    }
    if (data[start] === 0x42 && data[start + 1] === 0x4D) {
      return 'bmp';
    }
    return '';
  }

  /** 按代码页解码正文；代码页解码失败时退回 `TextCodec` 的自动探测。 */
  static decode(bytes: Uint8Array, codepage: number): string {
    const encoding: string = codepage === 65001 || codepage === 65002 ? 'utf-8' : 'windows-1252';
    try {
      return TextCodec.decodeAs(bytes, encoding);
    } catch (_error) {
      return TextCodec.decodeBytes(bytes);
    }
  }

  /** 去标签 + 折叠空白 + 解实体，并截断到展示长度。 */
  private static cleanLabel(raw: string): string {
    const text: string = MarkupText.stripTags(raw);
    return text.length > MAX_TITLE_LENGTH ? text.substring(0, MAX_TITLE_LENGTH) : text;
  }

  /** 在字节流里查找 ASCII 片段（大小写不敏感）。 */
  private static indexOf(data: Uint8Array, needle: string, from: number): number {
    const length: number = needle.length;
    const first: number = MobiDoc.lower(needle.charCodeAt(0));
    for (let i = Math.max(0, from); i + length <= data.length; i++) {
      if (MobiDoc.lower(data[i]) !== first) {
        continue;
      }
      let matched: boolean = true;
      for (let k = 1; k < length; k++) {
        if (MobiDoc.lower(data[i + k]) !== MobiDoc.lower(needle.charCodeAt(k))) {
          matched = false;
          break;
        }
      }
      if (matched) {
        return i;
      }
    }
    return -1;
  }

  private static lower(code: number): number {
    return code >= 0x41 && code <= 0x5A ? code + 32 : code;
  }

  /** 在 EXTH 里取指定类型的数据（找不到或结构异常返回 null）。 */
  private static exthValue(record0: Uint8Array, headerLength: number, wanted: number): Uint8Array | null {
    const start: number = PALMDOC_HEADER_BYTES + headerLength;
    if (headerLength <= 0 || start + 12 > record0.length) {
      return null;
    }
    if (MobiDoc.ascii(record0, start, 4) !== 'EXTH') {
      return null;
    }
    const count: number = MobiDoc.u32(record0, start + 8);
    let pos: number = start + 12;
    for (let i = 0; i < count && pos + 8 <= record0.length; i++) {
      const type: number = MobiDoc.u32(record0, pos);
      const length: number = MobiDoc.u32(record0, pos + 4);
      if (length < 8 || pos + length > record0.length) {
        return null;
      }
      if (type === wanted) {
        return record0.subarray(pos + 8, pos + length);
      }
      pos += length;
    }
    return null;
  }

  private static ascii(data: Uint8Array, offset: number, length: number): string {
    if (offset + length > data.length) {
      return '';
    }
    let text: string = '';
    for (let i = 0; i < length; i++) {
      text += String.fromCharCode(data[offset + i]);
    }
    return text;
  }

  private static u16(data: Uint8Array, offset: number): number {
    if (offset + 2 > data.length) {
      return 0;
    }
    return (data[offset] << 8) | data[offset + 1];
  }

  private static u32(data: Uint8Array, offset: number): number {
    if (offset + 4 > data.length) {
      return 0;
    }
    return (data[offset] * 0x1000000) + (data[offset + 1] << 16) + (data[offset + 2] << 8) + data[offset + 3];
  }
}
