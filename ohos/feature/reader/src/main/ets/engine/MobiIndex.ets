/**
 * MOBI 索引（INDX / TAGX / IDXT / CNCX）解析 —— **纯计算，无平台依赖**。
 *
 * KF8（AZW3）的骨架、片段、导航（NCX）、guide 都以 INDX 记录存放：
 * - 主 INDX 记录：头 + TAGX 标签表（描述每个 tag 在位图里的掩码与取值宽度）；
 * - 后续 `count` 条 INDX 记录：各自带 IDXT 位置表，条目形如 `[长度][文本][控制字节][变长数值…]`；
 * - 末尾 `nctoc` 条 CNCX 记录：变长字符串表，条目里用偏移引用（章节标题就来自这里）。
 *
 * 格式依据 MobileRead 的 MOBI 索引文档实现（tag 位图的取值规则：
 * 掩码位全 1 且掩码含多位时，后面跟一个变长的「字节数」，而不是条目个数）。
 */
import { TextCodec } from './TextCodec';

/** INDX 头里 u32 字段的数量（'INDX' 之后的 13 个字）。 */
const HEADER_WORDS: number = 13;
/** 头字段下标（相对 'INDX' 之后第 0 个字）。 */
const FIELD_LENGTH: number = 0;
const FIELD_START: number = 4;
const FIELD_COUNT: number = 5;
const FIELD_NCTOC: number = 12;
/** 每条 CNCX 记录覆盖的偏移范围（偏移按记录序号左移 16 位累加）。 */
const CNCX_STRIDE: number = 0x10000;

/** 一条索引条目：文本 + tag 取值表。 */
export interface MobiIndexEntry {
  text: string;
  tags: Map<number, number[]>;
}

/** 一个完整索引：条目 + CNCX 字符串表。 */
export interface MobiIndexData {
  entries: MobiIndexEntry[];
  /** CNCX 字符串表：条目里 tag 2/3/5 的值是它的偏移。 */
  strings: Map<number, string>;
}

/** TAGX 里的一条标签描述。 */
interface MobiTag {
  tag: number;
  valuesPerEntry: number;
  mask: number;
  endFlag: number;
}

/** 条目位图里解出的一组待读标签。 */
interface MobiPendingTag {
  tag: number;
  /** 值个数（来自掩码数值）；-1 表示用「字节数」模式。 */
  count: number;
  /** 字节数（count 为 -1 时有效）。 */
  bytes: number;
  valuesPerEntry: number;
}

export class MobiIndex {
  /** 解析主 INDX 记录，返回需要继续读取的记录条数（条目记录 + CNCX 记录）。 */
  static span(header: Uint8Array): number {
    if (header.length < 4 + HEADER_WORDS * 4 || MobiIndex.ascii(header, 0, 4) !== 'INDX') {
      return 0;
    }
    return MobiIndex.word(header, FIELD_COUNT) + MobiIndex.word(header, FIELD_NCTOC);
  }

  /**
   * 解析索引。
   * @param header 主 INDX 记录
   * @param following `span()` 条后续记录（先 count 条条目记录，再 nctoc 条 CNCX）
   * @param codepage 文本代码页（条目文本与 CNCX 字符串都用它解码）
   */
  static parse(header: Uint8Array, following: Uint8Array[], codepage: number): MobiIndexData {
    const result: MobiIndexData = { entries: [], strings: new Map<number, string>() };
    if (header.length < 4 + HEADER_WORDS * 4 || MobiIndex.ascii(header, 0, 4) !== 'INDX') {
      return result;
    }
    const headerLength: number = MobiIndex.word(header, FIELD_LENGTH);
    const entryCount: number = MobiIndex.word(header, FIELD_COUNT);
    const cncxCount: number = MobiIndex.word(header, FIELD_NCTOC);
    const tagTable: MobiTag[] = MobiIndex.tags(header, headerLength);
    const controlBytes: number = MobiIndex.controlBytes(header, headerLength);
    for (let j = 0; j < cncxCount && entryCount + j < following.length; j++) {
      MobiIndex.readCncx(following[entryCount + j], j, codepage, result.strings);
    }
    for (let i = 0; i < entryCount && i < following.length; i++) {
      MobiIndex.readEntries(following[i], controlBytes, tagTable, codepage, result.entries);
    }
    return result;
  }

  /** TAGX 标签表：控制字节个数 + 标签描述。 */
  private static tags(header: Uint8Array, headerLength: number): MobiTag[] {
    const tags: MobiTag[] = [];
    if (headerLength + 12 > header.length || MobiIndex.ascii(header, headerLength, 4) !== 'TAGX') {
      return tags;
    }
    const firstEntry: number = MobiIndex.u32(header, headerLength + 4);
    for (let i = 12; i + 4 <= firstEntry; i += 4) {
      const pos: number = headerLength + i;
      if (pos + 4 > header.length) {
        break;
      }
      tags.push({
        tag: header[pos],
        valuesPerEntry: header[pos + 1],
        mask: header[pos + 2],
        endFlag: header[pos + 3],
      });
    }
    return tags;
  }

  private static controlBytes(header: Uint8Array, headerLength: number): number {
    if (headerLength + 12 > header.length) {
      return 0;
    }
    return MobiIndex.u32(header, headerLength + 8);
  }

  /** 一条 INDX 记录里的所有条目（IDXT 给出各条目起点，末条以 IDXT 起点为界）。 */
  private static readEntries(data: Uint8Array, controlBytes: number, tagTable: MobiTag[],
    codepage: number, out: MobiIndexEntry[]): void {
    if (data.length < 4 + HEADER_WORDS * 4 || MobiIndex.ascii(data, 0, 4) !== 'INDX') {
      return;
    }
    const idxt: number = MobiIndex.word(data, FIELD_START);
    const count: number = MobiIndex.word(data, FIELD_COUNT);
    const positions: number[] = [];
    for (let j = 0; j < count; j++) {
      const at: number = idxt + 4 + j * 2;
      if (at + 2 > data.length) {
        break;
      }
      positions.push((data[at] << 8) | data[at + 1]);
    }
    positions.push(idxt);
    for (let j = 0; j + 1 < positions.length; j++) {
      const start: number = positions[j];
      const end: number = positions[j + 1];
      if (start >= data.length) {
        break;
      }
      const textLength: number = data[start];
      const textEnd: number = Math.min(start + 1 + textLength, data.length);
      const text: string = TextCodec.decodeCodepage(data.subarray(start + 1, textEnd), codepage);
      out.push({
        text: text,
        tags: MobiIndex.tagMap(data, controlBytes, tagTable, textEnd, Math.min(end, data.length)),
      });
    }
  }

  /** 控制字节 + 变长数值 → tag 取值表。 */
  private static tagMap(data: Uint8Array, controlBytes: number, tagTable: MobiTag[],
    start: number, end: number): Map<number, number[]> {
    const pending: MobiPendingTag[] = [];
    let controlIndex: number = 0;
    let cursor: number = start + controlBytes;
    for (let i = 0; i < tagTable.length; i++) {
      const tag: MobiTag = tagTable[i];
      if (tag.endFlag === 0x01) {
        controlIndex++;
        continue;
      }
      const at: number = start + controlIndex;
      const control: number = at < data.length ? data[at] : 0;
      const value: number = control & tag.mask;
      if (value === 0) {
        continue;
      }
      if (value === tag.mask) {
        if (MobiIndex.bitCount(tag.mask) > 1) {
          const size: number[] = MobiIndex.variable(data, cursor, end);
          cursor += size[0];
          pending.push({ tag: tag.tag, count: -1, bytes: size[1], valuesPerEntry: tag.valuesPerEntry });
        } else {
          pending.push({ tag: tag.tag, count: 1, bytes: 0, valuesPerEntry: tag.valuesPerEntry });
        }
        continue;
      }
      let mask: number = tag.mask;
      let shifted: number = value;
      while ((mask & 0x01) === 0) {
        mask = mask >> 1;
        shifted = shifted >> 1;
      }
      pending.push({ tag: tag.tag, count: shifted, bytes: 0, valuesPerEntry: tag.valuesPerEntry });
    }
    const tags: Map<number, number[]> = new Map<number, number[]>();
    for (let i = 0; i < pending.length; i++) {
      const item: MobiPendingTag = pending[i];
      const values: number[] = [];
      if (item.count >= 0) {
        for (let k = 0; k < item.count; k++) {
          for (let v = 0; v < item.valuesPerEntry; v++) {
            const read: number[] = MobiIndex.variable(data, cursor, end);
            cursor += read[0];
            values.push(read[1]);
          }
        }
      } else {
        let consumed: number = 0;
        while (consumed < item.bytes) {
          const read: number[] = MobiIndex.variable(data, cursor, end);
          cursor += read[0];
          consumed += read[0];
          values.push(read[1]);
        }
      }
      tags.set(item.tag, values);
    }
    return tags;
  }

  /** 变长数值：每字节 7 位，最高位为 1 表示结束；返回 [占用字节数, 数值]。 */
  private static variable(data: Uint8Array, offset: number, end: number): number[] {
    let value: number = 0;
    let consumed: number = 0;
    let finished: boolean = false;
    while (!finished && offset + consumed < data.length && offset + consumed < end) {
      const byte: number = data[offset + consumed];
      consumed++;
      if ((byte & 0x80) !== 0) {
        finished = true;
      }
      value = (value << 7) | (byte & 0x7F);
    }
    if (consumed === 0) {
      consumed = 1;
    }
    return [consumed, value];
  }

  /** 读一条 CNCX 记录：`[变长长度][字符串]` 循环，偏移按记录序号累加。 */
  private static readCncx(data: Uint8Array, record: number, codepage: number,
    out: Map<number, string>): void {
    let offset: number = 0;
    while (offset < data.length && data[offset] !== 0) {
      const start: number = offset;
      const read: number[] = MobiIndex.variable(data, offset, data.length);
      offset += read[0];
      const textEnd: number = Math.min(offset + read[1], data.length);
      out.set(start + record * CNCX_STRIDE, TextCodec.decodeCodepage(data.subarray(offset, textEnd), codepage));
      offset = textEnd;
    }
  }

  /** 掩码里 1 的个数。 */
  private static bitCount(value: number): number {
    let count: number = 0;
    let bits: number = value;
    for (let i = 0; i < 8; i++) {
      if ((bits & 0x01) === 0x01) {
        count++;
      }
      bits = bits >> 1;
    }
    return count;
  }

  private static word(data: Uint8Array, index: number): number {
    return MobiIndex.u32(data, 4 + index * 4);
  }

  private static u32(data: Uint8Array, offset: number): number {
    if (offset + 4 > data.length) {
      return 0;
    }
    return (data[offset] * 0x1000000) + (data[offset + 1] << 16) + (data[offset + 2] << 8) +
      data[offset + 3];
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
}
