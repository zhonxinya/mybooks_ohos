/**
 * 纯文本解码：BOM → UTF-16；合法 UTF-8 → UTF-8；否则按 GBK/GB18030 兜底。
 *
 * 中文 TXT 电子书大量使用 GBK，若不探测会整本乱码。
 * 解码能力交给系统 `util.TextDecoder`（ICU），不手写码表。
 */
import { util } from '@kit.ArkTS';
import { GBK_TABLE_B64 } from './GbkTable';

const GBK_LABELS: string[] = ['gbk', 'gb18030'];
/** GBK 双字节区每个 lead 的合法 trail 数：0x40–0xFE 去掉 0x7F。 */
const GBK_TRAIL_COUNT: number = 190;

export class TextCodec {
  /** 解码器按编码复用，避免开书/切章时反复创建。 */
  private static readonly decoders: Map<string, util.TextDecoder> = new Map<string, util.TextDecoder>();
  /** 引擎 gbk 能力探测结果：-1 未探测，0 不可用，1 可用。 */
  private static engineGbkProbe: number = -1;
  /** 内置 GBK 表（懒加载）。 */
  private static gbkTableBytes: Uint8Array | null = null;
  static decode(buffer: ArrayBuffer): string {
    const bytes = new Uint8Array(buffer);
    if (bytes.length === 0) {
      return '';
    }
    if (bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) {
      return TextCodec.decodeAs(bytes.subarray(3), 'utf-8');
    }
    if (bytes.length >= 2 && bytes[0] === 0xFF && bytes[1] === 0xFE) {
      return TextCodec.decodeAs(bytes.subarray(2), 'utf-16le');
    }
    if (bytes.length >= 2 && bytes[0] === 0xFE && bytes[1] === 0xFF) {
      return TextCodec.decodeAs(bytes.subarray(2), 'utf-16be');
    }
    if (TextCodec.isUtf8(bytes)) {
      return TextCodec.decodeAs(bytes, 'utf-8');
    }
    if (TextCodec.engineGbkUsable()) {
      for (let i = 0; i < GBK_LABELS.length; i++) {
        try {
          return TextCodec.decodeAs(bytes, GBK_LABELS[i]);
        } catch (_error) {
          // 当前环境不支持该编码标签时换下一个
        }
      }
    }
    // 引擎不支持 gbk（ArkUI-X Android 实测）→ 用内置映射表兜底
    return TextCodec.decodeGbk(bytes);
  }

  /**
   * 引擎的 gbk 解码是否可用（只在首次调用时探测一次）。
   *
   * ArkUI-X 的 Android 端 `util.TextDecoder` 对 'gbk' **不抛错但按错误编码解码**
   * （整本乱码），因此不能靠 try/catch 判断，必须用已知样本比对结果。
   */
  private static engineGbkUsable(): boolean {
    if (TextCodec.engineGbkProbe < 0) {
      let ok: number = 0;
      try {
        // GBK 的「中文」= D6 D0 CE C4
        const probe = new Uint8Array([0xD6, 0xD0, 0xCE, 0xC4]);
        ok = TextCodec.decodeAs(probe, 'gbk') === '中文' ? 1 : 0;
      } catch (_error) {
        ok = 0;
      }
      TextCodec.engineGbkProbe = ok;
    }
    return TextCodec.engineGbkProbe === 1;
  }

  /** 用内置映射表解码 GBK（单字节 ASCII/0x80 直通，双字节查表，非法序列给 U+FFFD）。 */
  private static decodeGbk(bytes: Uint8Array): string {
    const table: Uint8Array = TextCodec.gbkTable();
    const parts: string[] = [];
    let chunk: string = '';
    const n: number = bytes.length;
    let i: number = 0;
    while (i < n) {
      const b0: number = bytes[i];
      if (b0 < 0x80) {
        chunk += String.fromCharCode(b0);
        i++;
      } else if (b0 === 0x80) {
        chunk += '€';
        i++;
      } else if (i + 1 >= n) {
        chunk += String.fromCharCode(0xFFFD);
        i++;
      } else {
        const b1: number = bytes[i + 1];
        if (b1 < 0x40 || b1 === 0x7F || b1 > 0xFE) {
          chunk += String.fromCharCode(0xFFFD);
          i++;
        } else {
          const index: number = 1 + (b0 - 0x81) * GBK_TRAIL_COUNT +
            (b1 < 0x7F ? b1 - 0x40 : b1 - 0x41);
          const code: number = table[index * 2] | (table[index * 2 + 1] << 8);
          chunk += code === 0 ? String.fromCharCode(0xFFFD) : String.fromCharCode(code);
          i += 2;
        }
      }
      // 分块拼接，避免超长字符串反复扩容
      if (chunk.length >= 4096) {
        parts.push(chunk);
        chunk = '';
      }
    }
    parts.push(chunk);
    return parts.join('');
  }

  /** 懒加载内置 GBK 表（base64 → 字节，2 字节/项，小端）。 */
  private static gbkTable(): Uint8Array {
    if (TextCodec.gbkTableBytes === null) {
      const helper: util.Base64Helper = new util.Base64Helper();
      TextCodec.gbkTableBytes = helper.decodeSync(GBK_TABLE_B64);
    }
    return TextCodec.gbkTableBytes;
  }

  /** 按显式编码解码（调用方已知编码时用，例如 MOBI 头里的代码页）。 */
  static decodeAs(bytes: Uint8Array, encoding: string): string {
    return TextCodec.decoder(encoding).decodeToString(bytes);
  }

  private static decoder(encoding: string): util.TextDecoder {
    const cached: util.TextDecoder | undefined = TextCodec.decoders.get(encoding);
    if (cached !== undefined) {
      return cached;
    }
    const created: util.TextDecoder = util.TextDecoder.create(encoding);
    TextCodec.decoders.set(encoding, created);
    return created;
  }

  /** 对字节切片做探测式解码（`decode` 的入参是整块 ArrayBuffer，切片场景用这个）。 */
  static decodeBytes(bytes: Uint8Array): string {
    return TextCodec.decode(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
  }

  /** 按 MOBI 头里的代码页解码（65001 = UTF-8，其余按 Windows-1252）。 */
  static decodeCodepage(bytes: Uint8Array, codepage: number): string {
    const encoding: string = codepage === 65001 || codepage === 65002 ? 'utf-8' : 'windows-1252';
    try {
      return TextCodec.decodeAs(bytes, encoding);
    } catch (_error) {
      return TextCodec.decodeBytes(bytes);
    }
  }

  /** 严格 UTF-8 校验：出现非法序列即判定为非 UTF-8（ASCII 视为合法）。 */
  private static isUtf8(bytes: Uint8Array): boolean {
    let i = 0;
    while (i < bytes.length) {
      const first = bytes[i];
      if (first < 0x80) {
        i++;
        continue;
      }
      let extra = 0;
      let code = 0;
      let minCode = 0;
      if ((first & 0xE0) === 0xC0) {
        extra = 1;
        code = first & 0x1F;
        minCode = 0x80;
      } else if ((first & 0xF0) === 0xE0) {
        extra = 2;
        code = first & 0x0F;
        minCode = 0x800;
      } else if ((first & 0xF8) === 0xF0) {
        extra = 3;
        code = first & 0x07;
        minCode = 0x10000;
      } else {
        return false;
      }
      if (i + extra >= bytes.length) {
        return false;
      }
      for (let k = 1; k <= extra; k++) {
        const next = bytes[i + k];
        if ((next & 0xC0) !== 0x80) {
          return false;
        }
        code = (code << 6) | (next & 0x3F);
      }
      if (code < minCode || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) {
        return false;
      }
      i += extra + 1;
    }
    return true;
  }
}
