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

  static mergeKey(item: SoNovelSearchItem): string {
    return `${item.bookName.trim()}_${item.author.trim()}`;
  }

  static merge(items: SoNovelSearchItem[]): MergedSoNovelResult[] {
    const groups = new Map<string, SoNovelSearchItem[]>();
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      if (item.bookName.trim().length === 0) {
        continue;
      }
      const key = SoNovelMerge.mergeKey(item);
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
}
