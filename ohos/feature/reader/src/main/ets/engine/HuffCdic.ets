/**
 * HUFF/CDIC 解压（Amazon 自研的 Huffman + 短语词典压缩）—— **纯计算，无平台依赖**。
 *
 * 部分 MOBI / AZW / AZW3 用这种方式压缩（`compression = 17480`）：
 * - `HUFF` 记录：256 项的码表 dict1 + 32 组 min/max code（dict2）；
 * - 紧随其后的 `CDIC` 记录：短语词典（第 0 批是 256 个字面字节）；
 * - 文本记录按位流查表：码值落在 [mincode, maxcode] 内即命中该长度的符号，
 *   符号 < 256 是字面字节，否则是词典短语（短语本身可能仍是压缩数据，需递归解压）。
 *
 * 实现说明：原算法按 64 位读窗口取码，但 JS 位运算只有 32 位，
 * 这里改成「按位偏移取 32 位窗口 + 用浮点算 min/max code」，结果与 64 位实现等价。
 */
/** 单条 CDIC 记录最多追加的短语数由 bits 决定，这里只做上限保护。 */
const MAX_PHRASES: number = 1 << 20;

interface HuffEntry {
  /** 码长（位）。 */
  codelen: number;
  /** 是否为终结点（非终结需要继续比 min/max code 定长）。 */
  terminal: boolean;
  /** 该码长下的最大码值。 */
  maxcode: number;
}

interface Phrase {
  /** 原始字节（可能仍是压缩数据）。 */
  bytes: Uint8Array;
  /** 是否已解压（解压后就地替换，避免重复递归）。 */
  expanded: boolean;
}

export class HuffCdic {
  private readonly dict1: HuffEntry[] = [];
  private readonly mincode: number[] = [];
  private readonly maxcode: number[] = [];
  private readonly phrases: Phrase[] = [];

  private constructor() {
  }

  /** 用 HUFF 记录 + 若干 CDIC 记录构造解码器（记录顺序即文件中的顺序）。 */
  static create(huff: Uint8Array, cdic: Uint8Array[]): HuffCdic {
    const reader = new HuffCdic();
    if (huff.length < 24 || HuffCdic.ascii(huff, 0, 4) !== 'HUFF') {
      throw new Error('HUFF 表损坏');
    }
    const dict1Offset: number = HuffCdic.u32(huff, 8);
    const dict2Offset: number = HuffCdic.u32(huff, 12);
    for (let i = 0; i < 256; i++) {
      const value: number = HuffCdic.u32(huff, dict1Offset + i * 4);
      const codelen: number = value & 0x1F;
      const terminal: boolean = (value & 0x80) !== 0;
      const raw: number = value >>> 8;
      reader.dict1.push({
        codelen: codelen,
        terminal: terminal,
        maxcode: (raw + 1) * HuffCdic.pow2(32 - codelen) - 1,
      });
    }
    for (let len = 1; len <= 32; len++) {
      const min: number = HuffCdic.u32(huff, dict2Offset + (len - 1) * 8);
      const max: number = HuffCdic.u32(huff, dict2Offset + (len - 1) * 8 + 4);
      reader.mincode.push(min * HuffCdic.pow2(32 - len));
      reader.maxcode.push((max + 1) * HuffCdic.pow2(32 - len) - 1);
    }
    for (let i = 0; i < cdic.length; i++) {
      reader.loadCdic(cdic[i]);
    }
    return reader;
  }

  /** 解压一条（或多条拼接的）文本记录。 */
  unpack(data: Uint8Array): Uint8Array {
    let out: Uint8Array = new Uint8Array(Math.max(4096, data.length * 8));
    let length: number = 0;
    const bitsTotal: number = data.length * 8;
    let bitpos: number = 0;
    while (bitpos < bitsTotal) {
      const code: number = HuffCdic.window(data, bitpos);
      const entry: HuffEntry = this.dict1[Math.floor(code / 0x1000000)];
      let codelen: number = entry.codelen;
      let maxcode: number = entry.maxcode;
      if (codelen === 0) {
        break;
      }
      if (!entry.terminal) {
        while (codelen <= 32 && code < this.mincode[codelen - 1]) {
          codelen++;
        }
        if (codelen > 32) {
          break;
        }
        maxcode = this.maxcode[codelen - 1];
      }
      bitpos += codelen;
      if (bitpos > bitsTotal) {
        break;
      }
      const index: number = Math.floor((maxcode - code) / HuffCdic.pow2(32 - codelen));
      if (index < 0 || index >= this.phrases.length) {
        break;
      }
      const slice: Uint8Array = this.phrase(index);
      if (length + slice.length > out.length) {
        out = HuffCdic.grow(out, length + slice.length);
      }
      out.set(slice, length);
      length += slice.length;
    }
    return out.subarray(0, length);
  }

  /** 取词典短语（首次使用时递归解压）。 */
  private phrase(index: number): Uint8Array {
    const phrase: Phrase = this.phrases[index];
    if (phrase.expanded) {
      return phrase.bytes;
    }
    const expanded: Uint8Array = this.unpack(phrase.bytes);
    this.phrases[index] = { bytes: expanded, expanded: true };
    return expanded;
  }

  /** 读一条 CDIC 记录，把其中的短语追加到词典。 */
  private loadCdic(cdic: Uint8Array): void {
    if (cdic.length < 16 || HuffCdic.ascii(cdic, 0, 4) !== 'CDIC') {
      throw new Error('CDIC 表损坏');
    }
    const phrases: number = HuffCdic.u32(cdic, 8);
    const bits: number = HuffCdic.u32(cdic, 12);
    const capacity: number = bits >= 31 ? MAX_PHRASES : (1 << bits);
    const count: number = Math.min(capacity, phrases - this.phrases.length);
    for (let i = 0; i < count; i++) {
      const tableAt: number = 16 + i * 2;
      if (tableAt + 2 > cdic.length) {
        break;
      }
      const offset: number = (cdic[tableAt] << 8) | cdic[tableAt + 1];
      const dataAt: number = 16 + offset;
      if (dataAt + 2 > cdic.length) {
        break;
      }
      const descriptor: number = (cdic[dataAt] << 8) | cdic[dataAt + 1];
      const length: number = descriptor & 0x7FFF;
      const end: number = Math.min(dataAt + 2 + length, cdic.length);
      // 长度字的最高位表示短语是否已解压过：置位则是明文，清零说明内容本身仍是压缩数据
      this.phrases.push({
        bytes: cdic.subarray(dataAt + 2, end),
        expanded: (descriptor & 0x8000) !== 0,
      });
    }
  }

  /**
   * 取从 `bitpos` 起的 32 位窗口（大端位序），等价于原实现的 64 位窗口取码。
   *
   * **越过缓冲区末尾的位按 0 补齐**：最后一个符号的窗口常会伸出记录末尾（记录按字节对齐），
   * 若这里直接判越界返回 0，末尾一两个符号就会解码失败（表现为正文结尾少几个字）。
   */
  private static window(data: Uint8Array, bitpos: number): number {
    const byte: number = bitpos >> 3;
    const shift: number = bitpos & 7;
    const hi: number = HuffCdic.windowWord(data, byte);
    if (shift === 0) {
      return hi >>> 0;
    }
    const lo: number = HuffCdic.windowWord(data, byte + 4);
    return ((hi << shift) | (lo >>> (32 - shift))) >>> 0;
  }

  /** 读 4 字节（大端），不足部分按 0 补。 */
  private static windowWord(data: Uint8Array, offset: number): number {
    let value: number = 0;
    for (let i = 0; i < 4; i++) {
      const at: number = offset + i;
      value = (value << 8) | (at >= 0 && at < data.length ? data[at] : 0);
    }
    return value >>> 0;
  }

  private static grow(buffer: Uint8Array, needed: number): Uint8Array {
    let size: number = buffer.length * 2;
    while (size < needed) {
      size *= 2;
    }
    const bigger: Uint8Array = new Uint8Array(size);
    bigger.set(buffer.subarray(0, buffer.length));
    return bigger;
  }

  private static pow2(exp: number): number {
    return exp <= 0 ? 1 : Math.pow(2, exp);
  }

  private static u32(data: Uint8Array, offset: number): number {
    if (offset < 0 || offset + 4 > data.length) {
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
