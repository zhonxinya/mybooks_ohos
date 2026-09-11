import { SoNovelSearchResult } from '../common/Models';
import { TalebookCoreService } from './TalebookCoreService';

interface ParsedSearchPayload {
  code?: number;
  message?: string;
  data?: SoNovelSearchResult[];
}

function buildSearchPath(query: string): string {
  return `/search/aggregated?kw=${encodeURIComponent(query)}`;
}

/** SoNovel search via native sonovelGet. */
export class SoNovelApiService {
  private core: TalebookCoreService = TalebookCoreService.getInstance();

  async search(query: string): Promise<SoNovelSearchResult[]> {
    const raw = await this.core.sonovelGet(buildSearchPath(query));
    const data = JSON.parse(raw) as ParsedSearchPayload | SoNovelSearchResult[];
    if (Array.isArray(data)) {
      return data;
    }
    const payload = data as ParsedSearchPayload;
    if (payload.data !== undefined && Array.isArray(payload.data)) {
      if (payload.code !== undefined && payload.code !== 200) {
        throw new Error(String(payload.message ?? '搜索失败'));
      }
      return payload.data;
    }
    return [];
  }

  async fetchBook(_source: SoNovelSearchResult): Promise<void> {
    throw new Error('SoNovel fetchBook SSE not fully wired yet');
  }
}
