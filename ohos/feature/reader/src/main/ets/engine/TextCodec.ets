/**
 * 纯文本解码：BOM → UTF-16；合法 UTF-8 → UTF-8；否则按 GBK/GB18030 兜底。
 *
 * 中文 TXT 电子书大量使用 GBK，若不探测会整本乱码。
 * 解码能力交给系统 `util.TextDecoder`（ICU），不手写码表。
 */
import { util } from '@kit.ArkTS';

const GBK_LABELS: string[] = ['gbk', 'gb18030'];

export class TextCodec {
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
    for (let i = 0; i < GBK_LABELS.length; i++) {
      try {
        return TextCodec.decodeAs(bytes, GBK_LABELS[i]);
      } catch (_error) {
        // 当前环境不支持该编码标签时换下一个
      }
    }
    return TextCodec.decodeAs(bytes, 'utf-8');
  }

  /** 按显式编码解码（调用方已知编码时用，例如 MOBI 头里的代码页）。 */
  static decodeAs(bytes: Uint8Array, encoding: string): string {
    return util.TextDecoder.create(encoding).decodeToString(bytes);
  }

  /** 对字节切片做探测式解码（`decode` 的入参是整块 ArrayBuffer，切片场景用这个）。 */
  static decodeBytes(bytes: Uint8Array): string {
    return TextCodec.decode(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
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
