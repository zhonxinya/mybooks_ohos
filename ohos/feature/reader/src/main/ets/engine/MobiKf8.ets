/**
 * KF8（AZW3 / MOBI 8）正文拼装 —— **纯计算，无平台依赖**。
 *
 * KF8 的正文不是一整篇 HTML，而是「骨架 + 片段」：
 * - `FDST` 记录把解压后的正文切成若干 flow，flow 0 是骨架与片段的存储区，其后是 CSS/SVG 等；
 * - 骨架索引（INDX）给出每个骨架在 flow 0 中的位置长度，以及它包含几个片段；
 * - 片段索引给出每个片段的插入位置、所属骨架（file number）与数据位置长度；
 * - 把片段按插入位置塞回骨架，就还原出原始的每个 XHTML 文件（一个文件即一章）。
 *
 * 这样还原出的「部件」正好是章节单位，因此 KF8 不需要像 KF7 那样按目录偏移切字节。
 * 目录标题来自 NCX 索引的 CNCX 字符串（tag 3），它给出骨架序号（tag 6 的第一个值）。
 */
import { MobiIndexData, MobiIndexEntry } from './MobiIndex';

/** 骨架索引里各 tag 的含义（值为取该 tag 的第几个数值）。 */
const SKELETON_TAG_FRAGMENTS: number = 1;
const SKELETON_TAG_POSITION: number = 6;
/** 片段索引里各 tag 的含义。 */
const FRAGMENT_TAG_AID: number = 2;
const FRAGMENT_TAG_FILE: number = 3;
const FRAGMENT_TAG_POSITION: number = 6;
/** NCX 索引里各 tag 的含义。 */
const NCX_TAG_LABEL: number = 3;
const NCX_TAG_POSITION: number = 6;
/** 拼装出的正文总长度上限保护（防止索引损坏时无限增长）。 */
const MAX_TEXT_BYTES: number = 64 * 1024 * 1024;

/** 一个骨架（= 原始 XHTML 文件 = 一章）的索引信息。 */
interface MobiSkeleton {
  name: string;
  fragCount: number;
  start: number;
  length: number;
}

/** 一个片段的索引信息。 */
interface MobiFragment {
  insert: number;
  file: number;
  start: number;
  length: number;
}

/** 拼装结果：连续的正文缓冲 + 每个部件的区间 + 片段行号到部件的映射。 */
export interface MobiKf8Parts {
  text: Uint8Array;
  parts: number[][];
  /**
   * `fragmentParts[片段行号] = 部件序号`。
   * NCX 里的 `kindle:pos:fid:X:off:Y` 的 `X` 就是**片段行号**（不是部件序号），
   * 章节标题必须经它换算成部件，否则标题会张冠李戴。
   */
  fragmentParts: number[];
}

/** NCX 条目（目录项）：标题 + 指向的片段行号。 */
export interface MobiKf8TocItem {
  title: string;
  /** 片段行号（`kindle:pos:fid:X` 的 X）；-1 表示索引里没有。 */
  fragment: number;
}

export class MobiKf8 {
  /** 目录最多取多少条（防止索引损坏时把整本书塞进目录面板）。 */
  static readonly MAX_TOC_ITEMS: number = 5000;
  /** 扫描 flow 找图片 URI 的字节上限（SVG 包装通常几十字节）。 */
  private static readonly FLOW_SCAN_BYTES: number = 4096;

  /** 用 FDST 表把正文切成 flow（没有 FDST 时整段算一个 flow）。 */
  static flows(text: Uint8Array, fdst: Uint8Array): Uint8Array[] {
    if (fdst.length < 12 || MobiKf8.ascii(fdst, 0, 4) !== 'FDST') {
      return [text];
    }
    const count: number = MobiKf8.u32(fdst, 8);
    const bounds: number[] = [];
    for (let i = 0; i < count; i++) {
      const at: number = 12 + i * 8;
      if (at + 4 > fdst.length) {
        break;
      }
      bounds.push(MobiKf8.u32(fdst, at));
    }
    if (bounds.length === 0) {
      return [text];
    }
    const flows: Uint8Array[] = [];
    for (let i = 0; i < bounds.length; i++) {
      const end: number = i + 1 < bounds.length ? bounds[i + 1] : text.length;
      flows.push(text.subarray(Math.min(bounds[i], text.length), Math.min(end, text.length)));
    }
    return flows;
  }

  /**
   * 还原骨架部件：按骨架顺序取骨架字节，再把属于它的片段按插入位置塞进去。
   * 返回值里的 `text` 是各部件首尾相接的缓冲，`parts` 是每个部件的 [start, end)。
   */
  static parts(text: Uint8Array, fdst: Uint8Array, skeleton: MobiIndexData,
    fragments: MobiIndexData): MobiKf8Parts {
    const body: Uint8Array = MobiKf8.flows(text, fdst)[0];
    const skeletons: MobiSkeleton[] = MobiKf8.skeletons(skeleton);
    const pieces: MobiFragment[] = MobiKf8.fragments(fragments);
    const out: Uint8Array = new Uint8Array(Math.min(Math.max(body.length, 1024), MAX_TEXT_BYTES));
    const ranges: number[][] = [];
    const fragmentParts: number[] = [];
    let written: number = 0;
    let fragmentIndex: number = 0;
    let base: number = 0;
    for (let i = 0; i < skeletons.length; i++) {
      const skel: MobiSkeleton = skeletons[i];
      base = skel.start + skel.length;
      if (skel.start < 0 || base > body.length) {
        continue;
      }
      let assembled: Uint8Array = body.subarray(skel.start, base).slice();
      for (let k = 0; k < skel.fragCount; k++) {
        if (fragmentIndex >= pieces.length) {
          break;
        }
        const frag: MobiFragment = pieces[fragmentIndex];
        fragmentParts.push(ranges.length);
        fragmentIndex++;
        const from: number = base;
        const to: number = Math.min(base + frag.length, body.length);
        base = base + frag.length;
        if (to <= from) {
          continue;
        }
        let insert: number = frag.insert - skel.start;
        if (insert < 0 || insert > assembled.length) {
          insert = assembled.length;
        }
        const merged: Uint8Array = new Uint8Array(assembled.length + (to - from));
        merged.set(assembled.subarray(0, insert), 0);
        merged.set(body.subarray(from, to), insert);
        merged.set(assembled.subarray(insert), insert + (to - from));
        assembled = merged;
      }
      if (written + assembled.length > out.length) {
        break;
      }
      out.set(assembled, written);
      ranges.push([written, written + assembled.length]);
      written += assembled.length;
    }
    return { text: out.subarray(0, written), parts: ranges, fragmentParts: fragmentParts };
  }

  /**
   * 每个 flow 包裹的图片资源序号（KF8 常把插图放在 SVG flow 里，
   * 正文只写 `<img src="kindle:flow:0004?mime=image/svg+xml">`，真正的栅格图在 flow 内以
   * `kindle:embed:XXXX` 引用）。取不到时该 flow 记为 0。
   */
  static flowResources(flows: Uint8Array[]): number[] {
    const out: number[] = [];
    for (let i = 0; i < flows.length; i++) {
      const text: string = MobiKf8.latin1(flows[i]);
      const embed: RegExpExecArray | null = /kindle:embed:([0-9A-Va-v]+)/.exec(text);
      // flow 自身就是栅格图时（极少数）也按同一路径处理：记 0 表示解不出
      out.push(embed === null ? 0 : MobiKf8.base32(embed[1]));
    }
    return out;
  }

  /** KF8 的资源序号是 base32（0-9、A-V）编码的字符串；含非法字符返回 -1。 */
  static base32(text: string): number {
    let value: number = 0;
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      let digit: number = -1;
      if (code >= 0x30 && code <= 0x39) {
        digit = code - 0x30;
      } else if (code >= 0x41 && code <= 0x56) {
        digit = code - 0x41 + 10;
      } else if (code >= 0x61 && code <= 0x76) {
        digit = code - 0x61 + 10;
      }
      if (digit < 0) {
        return -1;
      }
      value = value * 32 + digit;
    }
    return value;
  }

  /** 目录项：NCX 的标签（CNCX 字符串）与所属骨架序号，按索引顺序返回。 */
  static toc(ncx: MobiIndexData, limit: number): MobiKf8TocItem[] {
    const items: MobiKf8TocItem[] = [];
    for (let i = 0; i < ncx.entries.length; i++) {
      const entry: MobiIndexEntry = ncx.entries[i];
      const label: number[] | undefined = entry.tags.get(NCX_TAG_LABEL);
      if (label === undefined || label.length === 0) {
        continue;
      }
      const title: string | undefined = ncx.strings.get(label[0]);
      if (title === undefined || title.trim().length === 0) {
        continue;
      }
      const position: number[] | undefined = entry.tags.get(NCX_TAG_POSITION);
      items.push({
        title: title.trim(),
        fragment: position !== undefined && position.length > 0 ? position[0] : -1,
      });
      if (items.length >= limit) {
        break;
      }
    }
    return items;
  }

  private static skeletons(index: MobiIndexData): MobiSkeleton[] {
    const out: MobiSkeleton[] = [];
    for (let i = 0; i < index.entries.length; i++) {
      const entry: MobiIndexEntry = index.entries[i];
      const fragments: number[] | undefined = entry.tags.get(SKELETON_TAG_FRAGMENTS);
      const position: number[] | undefined = entry.tags.get(SKELETON_TAG_POSITION);
      if (position === undefined || position.length < 2) {
        continue;
      }
      out.push({
        name: entry.text,
        fragCount: fragments !== undefined && fragments.length > 0 ? fragments[0] : 0,
        start: position[0],
        length: position[1],
      });
    }
    return out;
  }

  private static fragments(index: MobiIndexData): MobiFragment[] {
    const out: MobiFragment[] = [];
    for (let i = 0; i < index.entries.length; i++) {
      const entry: MobiIndexEntry = index.entries[i];
      const position: number[] | undefined = entry.tags.get(FRAGMENT_TAG_POSITION);
      if (position === undefined || position.length < 2) {
        continue;
      }
      const file: number[] | undefined = entry.tags.get(FRAGMENT_TAG_FILE);
      const insert: number = Number.parseInt(entry.text, 10);
      out.push({
        insert: Number.isNaN(insert) ? 0 : insert,
        file: file !== undefined && file.length > 0 ? file[0] : -1,
        start: position[0],
        length: position[1],
      });
    }
    return out;
  }

  private static u32(data: Uint8Array, offset: number): number {
    if (offset + 4 > data.length) {
      return 0;
    }
    return (data[offset] * 0x1000000) + (data[offset + 1] << 16) + (data[offset + 2] << 8) +
      data[offset + 3];
  }

  /** 按 latin-1 转字符串：只用于在 flow 字节里找 ASCII 形式的 URI，不做真正解码。 */
  private static latin1(data: Uint8Array): string {
    let text: string = '';
    const limit: number = Math.min(data.length, MobiKf8.FLOW_SCAN_BYTES);
    for (let i = 0; i < limit; i++) {
      text += String.fromCharCode(data[i]);
    }
    return text;
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
