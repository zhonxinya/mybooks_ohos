import { BookFile } from './BookFile';
import { HuffCdic } from './HuffCdic';
import { MobiIndex, MobiIndexData } from './MobiIndex';
import { MobiInfo } from './MobiDoc';
import { PalmDoc } from './PalmDoc';

/** 空索引（记录号缺失或越界时的返回值）。 */
function emptyIndex(): MobiIndexData {
  return { entries: [], strings: new Map<number, string>() };
}

/**
 * 按记录表读写 MOBI 文件（**含文件 IO，无 UI 调用**）。
 *
 * 独立成模块的原因与 `MobiChapter` 相同：`@Concurrent` 任务只能调用 import 进来的符号，
 * 不能调用同文件里的普通函数，因此「按记录号取一段字节」这类公共步骤必须放在模块里。
 */
export class MobiRecords {
  /** 取第 `index` 条记录的字节（越界或空记录返回空数组）。 */
  static read(filePath: string, records: number[], index: number): Uint8Array {
    if (index < 0 || index + 1 >= records.length) {
      return new Uint8Array(0);
    }
    const from: number = records[index];
    const to: number = records[index + 1];
    if (to <= from) {
      return new Uint8Array(0);
    }
    return new Uint8Array(BookFile.readRange(filePath, from, to - from));
  }

  /**
   * 读一个 INDX 索引：先读主记录拿头（据此算出还要读几条），再读条目记录与 CNCX 记录。
   * 记录号缺失（MOBI 头里为 0xFFFFFFFF）时返回空索引。
   */
  static readIndex(filePath: string, records: number[], index: number, codepage: number): MobiIndexData {
    if (index < 0 || index + 1 >= records.length) {
      return emptyIndex();
    }
    const header: Uint8Array = MobiRecords.read(filePath, records, index);
    const span: number = MobiIndex.span(header);
    const following: Uint8Array[] = [];
    for (let i = 1; i <= span; i++) {
      if (index + i + 1 >= records.length) {
        break;
      }
      following.push(MobiRecords.read(filePath, records, index + i));
    }
    return MobiIndex.parse(header, following, codepage);
  }

  /** 装载 HUFF/CDIC 解压表（非 HUFF 压缩时返回 null）。 */
  static readHuffman(filePath: string, records: number[], info: MobiInfo): HuffCdic | null {
    if (info.compression !== PalmDoc.COMPRESSION_HUFF || info.huffCount <= 0) {
      return null;
    }
    const huff: Uint8Array = MobiRecords.read(filePath, records, info.huffOffset);
    const cdic: Uint8Array[] = [];
    for (let i = 1; i < info.huffCount; i++) {
      cdic.push(MobiRecords.read(filePath, records, info.huffOffset + i));
    }
    return HuffCdic.create(huff, cdic);
  }
}
