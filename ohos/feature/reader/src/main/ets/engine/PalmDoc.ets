/**
 * PalmDOC 文本记录的解压与「记录尾巴」裁剪（**纯计算，无平台依赖**）。
 *
 * MOBI 的正文存放在连续若干条 PalmDOC 记录里（每条解压后约 4096 字节），
 * 记录是 LZ77 变体压缩，且**尾部可能挂着非正文数据**（索引、链接等），
 * 不裁掉就会在正文里插入乱码甚至让解压越界（回溯距离超出已输出长度）。
 *
 * 格式依据 MobileRead 的 PalmDOC / MOBI 格式文档实现：
 * - 字节 `0x01..0x08`：后随 N 个字面量字节；
 * - `0x09..0x7F`：单字节字面量；
 * - `0xC0..0xFF`：空格 + `(字节 & 0x7F)`；
 * - `0x80..0xBF`：两字节回溯（距离 11 位 + 长度 3 位，长度再加 3）。
 */

/** 记录尾巴（trailing entry）长度编码：最多回看 4 字节，高位置 1 的字节是最高位那一节。 */
const TRAILING_LOOKBACK: number = 4;
/** 回溯复制的最大长度（长度字段 3 位 + 3）。 */
const MAX_MATCH_LENGTH: number = 10;
/** 解压缓冲初始倍率：单条记录最坏膨胀 5 倍（每 2 字节最多产出 10 字节）。 */
const GROWTH_FACTOR: number = 8;

export class PalmDoc {
  /** 未压缩。 */
  static readonly COMPRESSION_NONE: number = 1;
  /** PalmDOC（LZ77）。 */
  static readonly COMPRESSION_PALMDOC: number = 2;
  /** HUFF/CDIC（Amazon 自研 Huffman + 词典），本模块暂不实现。 */
  static readonly COMPRESSION_HUFF: number = 17480;

  /**
   * 读出记录尾部数据块的长度（该长度值自身也占用记录的末尾若干字节）。
   *
   * 编码是「7 位一组、从低位字节往高位拼」：从记录末尾往前看最多 4 个字节，
   * 遇到最高位为 1 的字节表示数值到此为止（它是最靠前的一组 7 位）。
   */
  static trailingEntrySize(data: Uint8Array): number {
    let size: number = 0;
    const from: number = Math.max(0, data.length - TRAILING_LOOKBACK);
    for (let i = from; i < data.length; i++) {
      const byte: number = data[i];
      if ((byte & 0x80) !== 0) {
        size = 0;
      }
      size = (size << 7) | (byte & 0x7F);
    }
    return size;
  }

  /**
   * 裁掉记录尾部非正文的数据。
   *
   * - `trailers`：尾部数据块个数（由 MOBI 头的记录数据标志决定）；
   * - `multibyte`：记录末尾还额外挂着 1~4 字节的「多字节字符重叠」数据，
   *   其长度写在该字节的最低 2 位里。不裁掉会与下一条记录重复一个字符，
   *   且使全部记录解压后的总长超过头部声明的正文长度。
   */
  static trimRecord(data: Uint8Array, trailers: number, multibyte: boolean): Uint8Array {
    let end: number = data.length;
    for (let i = 0; i < trailers; i++) {
      const size: number = PalmDoc.trailingEntrySize(end > 0 ? data.subarray(0, end) : data);
      if (size <= 0 || size >= end) {
        break;
      }
      end -= size;
    }
    if (multibyte && end > 0) {
      const overlap: number = (data[end - 1] & 0x03) + 1;
      if (overlap < end) {
        end -= overlap;
      }
    }
    return end === data.length ? data : data.subarray(0, end);
  }

  /** 解压一条 PalmDOC 记录；数据本身未压缩（compression = 1）时原样返回。 */
  static decompress(data: Uint8Array): Uint8Array {
    const capacity: number = data.length * GROWTH_FACTOR + 16;
    let out: Uint8Array = new Uint8Array(capacity > 4096 ? capacity : 4096);
    let length: number = 0;
    let i: number = 0;
    while (i < data.length) {
      const byte: number = data[i];
      i++;
      if (byte >= 1 && byte <= 8) {
        const count: number = Math.min(byte, data.length - i);
        if (length + count + MAX_MATCH_LENGTH > out.length) {
          out = PalmDoc.grow(out);
        }
        out.set(data.subarray(i, i + count), length);
        length += count;
        i += count;
        continue;
      }
      if (byte < 0x80) {
        if (length + MAX_MATCH_LENGTH > out.length) {
          out = PalmDoc.grow(out);
        }
        out[length] = byte;
        length++;
        continue;
      }
      if (byte >= 0xC0) {
        if (length + MAX_MATCH_LENGTH > out.length) {
          out = PalmDoc.grow(out);
        }
        out[length] = 0x20;
        out[length + 1] = byte ^ 0x80;
        length += 2;
        continue;
      }
      // 0x80 ~ 0xBF：两字节回溯
      if (i >= data.length) {
        break;
      }
      const pair: number = (byte << 8) | data[i];
      i++;
      const distance: number = (pair >> 3) & 0x07FF;
      const count: number = (pair & 0x07) + 3;
      if (distance === 0 || distance > length) {
        // 数据损坏（回溯到尚未输出的位置）：到此为止，保留已解出的内容
        break;
      }
      if (length + count > out.length) {
        out = PalmDoc.grow(out);
      }
      for (let k = 0; k < count; k++) {
        out[length] = out[length - distance];
        length++;
      }
    }
    return out.subarray(0, length);
  }

  private static grow(buffer: Uint8Array): Uint8Array {
    const bigger: Uint8Array = new Uint8Array(buffer.length * 2);
    bigger.set(buffer.subarray(0, buffer.length));
    return bigger;
  }
}
