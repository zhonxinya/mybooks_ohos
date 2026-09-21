import { SoNovelBookPayload } from '../services/TalebookService';

export interface SoNovelSearchItem {
  sourceId: number;
  sourceName: string;
  url: string;
  bookName: string;
  author: string;
  category: string;
  latestChapter: string;
  lastUpdateTime: string;
  status: string;
}

export interface MergedSoNovelResult {
  bookName: string;
  author: string;
  category: string;
  latestChapter: string;
  status: string;
  sources: SoNovelSearchItem[];
}

/** 按书源筛选用的一个书源条目。 */
export interface SoNovelSourceOption {
  sourceId: number;
  sourceName: string;
  /** 选中该书源后能看到的**书数**（合并去重后），与筛选结果条保持一致。 */
  count: number;
}

export class SoNovelMerge {
  // 顶点小说 (sourceId=10) 在测试服务器上频繁 502，默认排在书源列表末尾。
  private static readonly UNSTABLE_SOURCE_IDS: number[] = [10];

  static isUnstableSource(sourceId: number): boolean {
    return SoNovelMerge.UNSTABLE_SOURCE_IDS.includes(sourceId);
  }

  static sortSources(sources: SoNovelSearchItem[]): SoNovelSearchItem[] {
    const sorted = sources.slice();
    sorted.sort((left: SoNovelSearchItem, right: SoNovelSearchItem): number => {
      const leftRank = SoNovelMerge.isUnstableSource(left.sourceId) ? 1 : 0;
      const rightRank = SoNovelMerge.isUnstableSource(right.sourceId) ? 1 : 0;
      return leftRank - rightRank;
    });
    return sorted;
  }

  static fromRecord(raw: Record<string, Object>): SoNovelSearchItem {
    return {
      sourceId: Number(raw['sourceId'] ?? 0),
      sourceName: String(raw['sourceName'] ?? ''),
      url: String(raw['url'] ?? ''),
      bookName: String(raw['bookName'] ?? raw['title'] ?? raw['name'] ?? ''),
      author: String(raw['author'] ?? ''),
      category: String(raw['category'] ?? ''),
      latestChapter: String(raw['latestChapter'] ?? ''),
      lastUpdateTime: String(raw['lastUpdateTime'] ?? ''),
      status: String(raw['status'] ?? ''),
    };
  }

  /**
   * 合并键：书名 + 作者。
   *
   * 收两个字符串而不是一个结构化对象：ArkTS 不支持结构化类型（`arkts-no-structural-typing`），
   * 定义一个只有 `bookName`/`author` 的接口并传入 `SoNovelSearchItem` 或
   * `MergedSoNovelResult` 都会被拦下。
   */
  static mergeKey(bookName: string, author: string): string {
    return `${bookName.trim()}_${author.trim()}`;
  }

  static merge(items: SoNovelSearchItem[]): MergedSoNovelResult[] {
    const groups = new Map<string, SoNovelSearchItem[]>();
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      if (item.bookName.trim().length === 0) {
        continue;
      }
      const key = SoNovelMerge.mergeKey(item.bookName, item.author);
      const bucket = groups.get(key) ?? [];
      bucket.push(item);
      groups.set(key, bucket);
    }
    const merged: MergedSoNovelResult[] = [];
    groups.forEach((sources: SoNovelSearchItem[]) => {
      const ordered = SoNovelMerge.sortSources(sources);
      const first = ordered[0];
      merged.push({
        bookName: first.bookName,
        author: first.author,
        category: first.category,
        latestChapter: first.latestChapter,
        status: first.status,
        sources: ordered,
      });
    });
    return merged;
  }

  static toPayload(item: SoNovelSearchItem): SoNovelBookPayload {
    return {
      sourceId: item.sourceId,
      sourceName: item.sourceName,
      url: item.url,
      bookName: item.bookName,
      author: item.author,
      category: item.category,
      latestChapter: item.latestChapter,
      lastUpdateTime: item.lastUpdateTime,
      status: item.status,
      format: 'epub',
      language: 'zh-CN',
    };
  }

  static subtitle(merged: MergedSoNovelResult): string {
    const defaultSource = merged.sources[0];
    const parts: string[] = [];
    if (merged.sources.length > 1) {
      parts.push(`${merged.sources.length} 个书源`);
    }
    if (defaultSource.sourceName.length > 0) {
      parts.push(defaultSource.sourceName);
    }
    if (merged.latestChapter.length > 0) {
      parts.push(merged.latestChapter);
    } else if (merged.status.length > 0) {
      parts.push(merged.status);
    }
    return parts.join(' · ');
  }

  /**
   * 列出合并结果里出现过的书源（按能看到的书数降序）。
   *
   * 书源清单不来自服务端接口：SoNovel 只能整站聚合搜索、没有「列出全部书源」的端点，
   * 且各书源可用性会有波动，列出没命中的书源只会让用户选中后看到空列表。
   * 因此只从本次命中结果里提取，选中的书源一定有内容。
   *
   * 基于**合并后**的结果统计（而不是原始条数）：芯片上的数字要等于点下去看到的条数，
   * 否则「阅读库（21）」点进去只剩 19 本，看起来像丢了结果。
   */
  static sourceOptions(merged: MergedSoNovelResult[]): SoNovelSourceOption[] {
    const buckets = new Map<number, SoNovelSourceOption>();
    for (let i = 0; i < merged.length; i++) {
      const sources = merged[i].sources;
      const seen = new Set<number>();
      for (let j = 0; j < sources.length; j++) {
        const source = sources[j];
        // 同一本书里同一书源可能有多条（同名同作者聚合到了一条），只计一次
        if (seen.has(source.sourceId)) {
          continue;
        }
        seen.add(source.sourceId);
        const existing = buckets.get(source.sourceId);
        if (existing === undefined) {
          buckets.set(source.sourceId, {
            sourceId: source.sourceId,
            sourceName: source.sourceName,
            count: 1,
          });
        } else {
          existing.count++;
        }
      }
    }
    const options: SoNovelSourceOption[] = [];
    buckets.forEach((option: SoNovelSourceOption) => options.push(option));
    options.sort((left: SoNovelSourceOption, right: SoNovelSourceOption): number => {
      if (right.count !== left.count) {
        return right.count - left.count;
      }
      return left.sourceId - right.sourceId;
    });
    return options;
  }

  /**
   * 只保留**包含指定书源**的合并结果；`sourceId <= 0` 表示不筛选（返回原数组）。
   *
   * 筛选后不裁剪结果里的 `sources`：条目上仍显示「N 个书源」并可在详情里切换下载源，
   * 用户筛的只是「哪些书有我要的书源」，不是「只看这一个书源」。
   */
  static filterBySource(merged: MergedSoNovelResult[], sourceId: number): MergedSoNovelResult[] {
    if (sourceId <= 0) {
      return merged;
    }
    return merged.filter((item: MergedSoNovelResult): boolean =>
      item.sources.some((source: SoNovelSearchItem): boolean => source.sourceId === sourceId));
  }

  /** 书源显示名：服务端未给名称时兜底为「书源 N」。 */
  static sourceLabel(sourceId: number, sourceName: string): string {
    return sourceName.length > 0 ? sourceName : `书源 ${sourceId}`;
  }
}
