import { intl } from '@kit.LocalizationKit';
import { DownloadRecord, TalebookService } from '../services/TalebookService';

const PREF_KEY: string = 'bookshelf_sort_mode';

/** 书架排序方式。数值会落盘，调整顺序时不要改动既有取值。 */
export const SHELF_SORT_RECENT_ADDED: number = 0;
export const SHELF_SORT_RECENT_READ: number = 1;
export const SHELF_SORT_PROGRESS: number = 2;
export const SHELF_SORT_TITLE: number = 3;

export interface ShelfSortOption {
  label: string;
  value: number;
}

/** 排序下拉项：常用项在前，默认项（保持不排序）放最后。 */
export const SHELF_SORT_OPTIONS: ShelfSortOption[] = [
  { label: '最近阅读', value: SHELF_SORT_RECENT_READ },
  { label: '阅读进度', value: SHELF_SORT_PROGRESS },
  { label: '书名', value: SHELF_SORT_TITLE },
  { label: '最近加入', value: SHELF_SORT_RECENT_ADDED },
];

/**
 * 本地书架排序。
 *
 * 只在客户端排序：下载记录本就全量在内存里（`TalebookService.getDownloads()`），
 * 服务端接口也没有对应的排序参数。排序结果不落盘，每次进页面按偏好重排。
 */
export class BookSortMode {
  /**
   * 中文按拼音排序必须显式指定中文 locale：系统 locale 为英文时 ICU 只会按码位排。
   * 构造开销大，缓存在这里，`collatorBroken` 用于构造/比较抛异常后不再重试。
   */
  private static collator: intl.Collator | null = null;
  private static collatorBroken: boolean = false;

  static normalize(value: number): number {
    for (const option of SHELF_SORT_OPTIONS) {
      if (option.value === value) {
        return value;
      }
    }
    return SHELF_SORT_RECENT_ADDED;
  }

  static label(mode: number): string {
    const normalized = BookSortMode.normalize(mode);
    for (const option of SHELF_SORT_OPTIONS) {
      if (option.value === normalized) {
        return option.label;
      }
    }
    return '';
  }

  static load(): number {
    const raw = TalebookService.prefGet(PREF_KEY, `${SHELF_SORT_RECENT_ADDED}`);
    return BookSortMode.normalize(Number(raw));
  }

  static save(mode: number): void {
    TalebookService.prefSet(PREF_KEY, `${BookSortMode.normalize(mode)}`);
  }

  /**
   * 按 `mode` 排序（不改动入参数组）。
   *
   * 「最近加入」直接返回入参顺序：下载记录本就按加入时间倒序插入，而历史数据里
   * `downloadTime` 可能缺失，重排会让这类旧书跑到末尾、看起来像丢了书。
   */
  static sort(records: DownloadRecord[], mode: number): DownloadRecord[] {
    const normalized = BookSortMode.normalize(mode);
    if (normalized === SHELF_SORT_RECENT_ADDED) {
      return records;
    }
    const sorted = records.slice();
    if (normalized === SHELF_SORT_RECENT_READ) {
      sorted.sort((left: DownloadRecord, right: DownloadRecord): number =>
        BookSortMode.byLastRead(left, right));
    } else if (normalized === SHELF_SORT_PROGRESS) {
      sorted.sort((left: DownloadRecord, right: DownloadRecord): number =>
        BookSortMode.byProgress(left, right));
    } else if (normalized === SHELF_SORT_TITLE) {
      sorted.sort((left: DownloadRecord, right: DownloadRecord): number =>
        BookSortMode.byTitle(left, right));
    }
    return sorted;
  }

  /** 未读过的排最后；同为已读时按加入时间新→旧。 */
  private static byLastRead(left: DownloadRecord, right: DownloadRecord): number {
    const diff = BookSortMode.lastReadTime(right) - BookSortMode.lastReadTime(left);
    if (diff !== 0) {
      return diff;
    }
    return BookSortMode.downloadTime(right) - BookSortMode.downloadTime(left);
  }

  /** 已读百分比大→小；无进度的排最后，其次按最近阅读、加入时间。 */
  private static byProgress(left: DownloadRecord, right: DownloadRecord): number {
    const diff = BookSortMode.percent(right) - BookSortMode.percent(left);
    if (diff !== 0) {
      return diff;
    }
    return BookSortMode.byLastRead(left, right);
  }

  /** 书名按中文拼音（Collator 不可用时退化为码位比较），同名的保持原相对顺序。 */
  private static byTitle(left: DownloadRecord, right: DownloadRecord): number {
    return BookSortMode.compareTitle(left.title ?? '', right.title ?? '');
  }

  private static lastReadTime(record: DownloadRecord): number {
    const time = record.progress?.lastReadTime;
    return time !== undefined && time > 0 ? time : 0;
  }

  private static downloadTime(record: DownloadRecord): number {
    const time = record.downloadTime;
    return time !== undefined && time > 0 ? time : 0;
  }

  /**
   * 已读百分比（0~100）；无进度记为 -1，保证排在「已读 0%」之后。
   *
   * `progress.progressPercent` 目前**从未被写入**（进度上报链路只落 location，未回填该字段），
   * 所以再回退解析 location JSON 里内置阅读器写下的 `percent`；ReaderKit 的 location 是 CFI、
   * 不含百分比，这类书仍按无进度处理。
   */
  private static percent(record: DownloadRecord): number {
    const percent = record.progress?.progressPercent;
    if (percent !== undefined) {
      return percent;
    }
    return BookSortMode.percentFromLocation(record.progress?.location ?? '');
  }

  private static percentFromLocation(location: string): number {
    if (location.length === 0) {
      return -1;
    }
    try {
      const parsed = JSON.parse(location) as Record<string, Object>;
      const value = parsed['percent'];
      return typeof value === 'number' ? value : -1;
    } catch (_error) {
      return -1;
    }
  }

  private static compareTitle(left: string, right: string): number {
    const collator = BookSortMode.collatorOrNull();
    if (collator !== null) {
      try {
        return collator.compare(left, right);
      } catch (_error) {
        BookSortMode.collator = null;
        BookSortMode.collatorBroken = true;
      }
    }
    if (left === right) {
      return 0;
    }
    return left < right ? -1 : 1;
  }

  private static collatorOrNull(): intl.Collator | null {
    if (BookSortMode.collator !== null || BookSortMode.collatorBroken) {
      return BookSortMode.collator;
    }
    try {
      // numeric: 「第2卷」排在「第10卷」前
      BookSortMode.collator = new intl.Collator('zh-Hans-CN', { usage: 'sort', numeric: true });
    } catch (_error) {
      BookSortMode.collatorBroken = true;
      BookSortMode.collator = null;
    }
    return BookSortMode.collator;
  }
}
