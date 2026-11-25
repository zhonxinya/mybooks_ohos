import { TalebookService } from './TalebookService';
import { AiServiceConfig } from './AiServiceConfig';
import { WebSearchChannels, WebSearchHit, BAIDU_UA, ABSTRACT_MAX } from './WebSearchChannels';
import { ErrorFormat } from '../utils/ErrorFormat';

/** 百科单通道检索结果。ok=false 时 error 说明原因（供工具层如实回传）。 */
export interface EncyclopediaHit {
  source: string;
  ok: boolean;
  title: string;
  abstract: string;
  url: string;
  error: string;
}

/** 通用网页搜索整体结果：ok=false 时 error 说明原因（同百科通道容错风格）。 */
export interface WebSearchResult {
  ok: boolean;
  items: WebSearchHit[];
  error: string;
  /** 逐引擎命中诊断（#1633）：如「百度 8 | Bing 0(超时) | 360 5」，引擎改版静默失效可见化。 */
  stats: string;
}

/** 单引擎抓取诊断项（#1633）：state 空串=正常，否则「超时」/「失败」。 */
interface EngineStat {
  label: string;
  count: number;
  state: string;
}

/** 搜索引擎登记：id 用于配置存储（启用/顺序），label 供 UI 展示。 */
export interface SearchEngine {
  id: string;
  label: string;
  /** 该引擎在合并结果里每条命中的来源标注（用于来源可信度打分）。 */
  source: string;
}

/** 重排序中间项：命中 + 分数 + 原始序（稳定排序用）。 */
interface RankedHit {
  hit: WebSearchHit;
  score: number;
  order: number;
}

/** 内置引擎清单（顺序即默认优先级）。 */
export const SEARCH_ENGINES: SearchEngine[] = [
  { id: 'baidu', label: '百度', source: '百度' },
  { id: 'bing', label: 'Bing', source: 'Bing' },
  { id: 'so360', label: '360 搜索', source: '360' },
  { id: 'sogou', label: '搜狗', source: '搜狗' },
  { id: 'wikipedia', label: '维基百科', source: '维基百科' },
  { id: 'deepseek', label: 'DeepSeek', source: 'DeepSeek' },
  { id: 'openalex', label: 'OpenAlex', source: 'OpenAlex' },
  { id: 'crossref', label: 'Crossref', source: 'Crossref' },
];

/** 启用的引擎 id 列表（JSON 数组）；旧「启用清单」语义，仅作迁移源（#1636）。 */
const ENGINES_KEY: string = 'ai_search_engines';
/** 禁用的引擎 id 列表（反语义）：新注册引擎默认启用，不受历史配置遮蔽。 */
const ENGINES_OFF_KEY: string = 'ai_search_engines_off';
/** 结果条数上限（默认 8）。 */
const SEARCH_LIMIT_KEY: string = 'ai_search_limit';
/** 单引擎抓取条数下限（比最终条数多取，供去重与重排序筛选；#1634 按 limit 动态放大）。 */
const PER_ENGINE_FETCH: number = 8;
/** 单引擎硬超时（#1633）：rcp transferMs 20s 仍会拖慢全局聚合，8s 快失败。 */
const ENGINE_TIMEOUT_MS: number = 8000;
/** 来源可信度权重：百科/主搜高于聚合站，用于重排序。 */
const SOURCE_WEIGHT: Record<string, number> = {
  '百度百科': 3, '维基百科': 3, 'DeepSeek': 3, 'OpenAlex': 3, 'Crossref': 3,
  '百度': 2, 'Bing': 2, '360': 1, '搜狗': 1,
};

export class EncyclopediaService {
  /** 单引擎硬超时毫秒（#1633）；harness 用例临时调小避免真实等待 8s。 */
  static engineTimeoutMs: number = ENGINE_TIMEOUT_MS;
  /** 百度百科：抓百度主搜结果页里的百科卡（title/url/abstract 内嵌 JSON）。 */
  static async searchBaike(query: string): Promise<EncyclopediaHit> {
    const hit: EncyclopediaHit = { source: '百度百科', ok: false, title: '', abstract: '', url: '', error: '' };
    try {
      const html: string = await WebSearchChannels.fetchText(
        `https://www.baidu.com/s?wd=${encodeURIComponent(query)}`, BAIDU_UA);
      // SERP 有两种百科卡形态且随 query 变化：词条卡（"tools"，多见于「词 百科」）、
      // AI 问答卡内引用项（url/text/source+abstract，纯词与整句均有）。先前者，不中则后者。
      const tools: RegExpExecArray | null =
        /"tools":\{"title":"([^"]*)","url":"([^"]*)"([\s\S]{0,3000}?)"abstract":"([^"]*)"/.exec(html);
      let title: string = '';
      let url: string = '';
      let rawAbstract: string = '';
      if (tools !== null && tools[1].length > 0) {
        title = tools[1];
        url = tools[2];
        rawAbstract = tools[4];
      } else {
        const cite: RegExpExecArray | null =
          /"url":"(https:\/\/baike\.baidu\.com\/item\/[^"]{1,300})","text":"([^"]{1,200})","source":"百度百科"([\s\S]{0,800}?)"abstract":"([^"]{10,})"/.exec(html);
        if (cite === null) {
          hit.error = '搜索结果中没有百科词条';
          return hit;
        }
        url = cite[1];
        title = cite[2];
        rawAbstract = cite[4];
      }
      hit.ok = true;
      hit.title = WebSearchChannels.unescapeJsonString(title);
      hit.url = url;
      hit.abstract = WebSearchChannels.unescapeJsonString(rawAbstract);
      if (hit.abstract.length > ABSTRACT_MAX) {
        hit.abstract = `${hit.abstract.substring(0, ABSTRACT_MAX)}…`;
      }
      return hit;
    } catch (error) {
      hit.error = ErrorFormat.message(error);
      return hit;
    }
  }

  /** 维基百科中文：MediaWiki 检索 API（snippet 即摘要，一次请求）。局域网 DNS 污染时连接失败走 error。 */
  static async searchWikipedia(query: string): Promise<EncyclopediaHit> {
    const hit: EncyclopediaHit = { source: '维基百科', ok: false, title: '', abstract: '', url: '', error: '' };
    try {
      const text: string = await WebSearchChannels.fetchText(
        `https://zh.wikipedia.org/w/api.php?action=query&list=search&srlimit=2&format=json&formatversion=2&srsearch=${encodeURIComponent(query)}`,
        BAIDU_UA);
      const root = JSON.parse(text) as Record<string, Object>;
      const queryObj = root['query'] as Record<string, Object> | undefined;
      const search = queryObj !== undefined ? queryObj['search'] as Object[] | undefined : undefined;
      if (search === undefined || search.length === 0) {
        hit.error = '维基百科没有匹配条目';
        return hit;
      }
      const first = search[0] as Record<string, Object>;
      const title: string = typeof first['title'] === 'string' ? first['title'] as string : '';
      const snippet: string = typeof first['snippet'] === 'string' ? first['snippet'] as string : '';
      if (title.length === 0) {
        hit.error = '维基百科条目解析失败';
        return hit;
      }
      hit.ok = true;
      hit.title = title;
      hit.abstract = WebSearchChannels.stripHtml(snippet);
      if (hit.abstract.length > ABSTRACT_MAX) {
        hit.abstract = `${hit.abstract.substring(0, ABSTRACT_MAX)}…`;
      }
      hit.url = `https://zh.wikipedia.org/wiki/${encodeURIComponent(title.replace(/ /g, '_'))}`;
      return hit;
    } catch (error) {
      hit.error = ErrorFormat.message(error);
      return hit;
    }
  }

  // ———— 搜索引擎配置（设置页「搜索引擎」区） ————

  /** pref 存的 id JSON 数组；未设置=null，坏值=空数组。 */
  private static readIdList(raw: string): string[] | null {
    if (raw.length === 0) {
      return null;
    }
    try {
      const list: Object[] = JSON.parse(raw) as Object[];
      const out: string[] = [];
      for (let i = 0; i < list.length; i++) {
        if (typeof list[i] === 'string') {
          out.push(list[i] as string);
        }
      }
      return out;
    } catch (_error) {
      return [];
    }
  }

  /** 禁用 id 清单（内部）：读 off 键；缺省时从旧「启用清单」键迁移（老配置用户的新注册引擎默认启用）。 */
  private static disabledEngines(): string[] {
    const off: string[] | null = EncyclopediaService.readIdList(TalebookService.prefGet(ENGINES_OFF_KEY));
    if (off !== null) {
      return off;
    }
    const legacy: string[] | null = EncyclopediaService.readIdList(TalebookService.prefGet(ENGINES_KEY));
    if (legacy === null) {
      return [];
    }
    // 只在「旧清单时代已知引擎」内推导禁用项；之后新增的引擎（如 deepseek）不在旧清单
    // 是「当时不存在」而非「用户停用」，保持默认启用。新增引擎时勿再动此表。
    const knownBefore: string[] = ['baidu', 'bing', 'so360', 'sogou', 'wikipedia'];
    const migrated: string[] = [];
    for (let i = 0; i < SEARCH_ENGINES.length; i++) {
      const id: string = SEARCH_ENGINES[i].id;
      if (knownBefore.indexOf(id) >= 0 && legacy.indexOf(id) < 0) {
        migrated.push(id);
      }
    }
    TalebookService.prefSet(ENGINES_OFF_KEY, JSON.stringify(migrated));
    return migrated;
  }

  /** 已启用的引擎 id 清单（注册表序）；未设置=全部启用。 */
  static enabledEngines(): string[] {
    const off: string[] = EncyclopediaService.disabledEngines();
    const out: string[] = [];
    for (let i = 0; i < SEARCH_ENGINES.length; i++) {
      if (off.indexOf(SEARCH_ENGINES[i].id) < 0) {
        out.push(SEARCH_ENGINES[i].id);
      }
    }
    return out;
  }

  static isEngineEnabled(id: string): boolean {
    return EncyclopediaService.enabledEngines().indexOf(id) >= 0;
  }

  /** 勾选/取消某引擎；至少保留一个（全关时拒绝并返回 false）。存禁用清单（反语义，#1636）。 */
  static setEngineEnabled(id: string, on: boolean): boolean {
    const cur: string[] = EncyclopediaService.enabledEngines();
    const idx: number = cur.indexOf(id);
    if (on) {
      if (idx < 0) {
        cur.push(id);
      }
    } else {
      if (cur.length <= 1) {
        return false;
      }
      if (idx >= 0) {
        cur.splice(idx, 1);
      }
    }
    const off: string[] = [];
    for (let i = 0; i < SEARCH_ENGINES.length; i++) {
      if (cur.indexOf(SEARCH_ENGINES[i].id) < 0) {
        off.push(SEARCH_ENGINES[i].id);
      }
    }
    TalebookService.prefSet(ENGINES_OFF_KEY, JSON.stringify(off));
    return true;
  }

  /** 结果条数上限（默认 8，夹在 3–20）。 */
  static searchLimit(): number {
    const raw: string = TalebookService.prefGet(SEARCH_LIMIT_KEY);
    const n: number = raw.length > 0 ? Number(raw) : 8;
    if (!Number.isFinite(n)) {
      return 8;
    }
    return Math.min(20, Math.max(3, Math.floor(n)));
  }

  static setSearchLimit(n: number): void {
    TalebookService.prefSet(SEARCH_LIMIT_KEY, `${Math.min(20, Math.max(3, Math.floor(n)))}`);
  }

  /** 词段发射（#1632）：非 CJK 整词需 ≥2 字符；CJK 单字成词、多字切二元组。 */
  private static emitRun(run: string, isCjk: boolean, toks: string[]): void {
    if (!isCjk) {
      if (run.length >= 2) {
        toks.push(run);
      }
    } else if (run.length === 1) {
      toks.push(run);
    } else {
      for (let k = 0; k + 1 < run.length; k++) {
        toks.push(run.substring(k, k + 2));
      }
    }
  }

  /**
   * 查询词切分（#1632）：空白分词后，CJK 连续块切二元组（「三体小说」→ 三体/体小/小说），
   * 非 CJK 词整词保留。无空白中文查询也能算命中率。
   */
  private static queryTokens(query: string): string[] {
    const toks: string[] = [];
    const parts: string[] = query.toLowerCase().split(/\s+/);
    for (let p = 0; p < parts.length; p++) {
      const part: string = parts[p];
      let run: string = '';
      let isCjk: boolean = false;
      for (let i = 0; i < part.length; i++) {
        const ch: string = part.charAt(i);
        const cjk: boolean = /[\u4e00-\u9fff]/.test(ch);
        if (i > 0 && cjk === isCjk) {
          run = `${run}${ch}`;
        } else {
          if (i > 0) {
            EncyclopediaService.emitRun(run, isCjk, toks);
          }
          run = ch;
          isCjk = cjk;
        }
      }
      if (run.length > 0) {
        EncyclopediaService.emitRun(run, isCjk, toks);
      }
    }
    return toks;
  }

  /** 词命中率：toks 中在 text 出现的比例（0–1）；空词表回 0。 */
  private static hitRate(text: string, toks: string[]): number {
    if (toks.length === 0) {
      return 0;
    }
    const lower: string = text.toLowerCase();
    let hit: number = 0;
    for (let i = 0; i < toks.length; i++) {
      if (lower.indexOf(toks[i]) >= 0) {
        hit++;
      }
    }
    return hit / toks.length;
  }

  /**
   * URL 归一化（#1635）：去 fragment、剥跟踪类查询参数（utm 系列/spm/from/ref 等）、
   * host 小写、去尾斜杠。仅用于去重键，不改展示 URL。
   */
  private static normalizeUrl(url: string): string {
    let u: string = url.split('#')[0];
    const qAt: number = u.indexOf('?');
    if (qAt >= 0) {
      const base: string = u.substring(0, qAt);
      const kept: string[] = [];
      const params: string[] = u.substring(qAt + 1).split('&');
      for (let i = 0; i < params.length; i++) {
        const name: string = params[i].split('=')[0].toLowerCase();
        if (name.length > 0 && !/^(utm_|spm|usm|from|scene|share_|track|srcid|ref|ch$|tcfrom)/.test(name)) {
          kept.push(params[i]);
        }
      }
      u = kept.length > 0 ? `${base}?${kept.join('&')}` : base;
    }
    const m: RegExpExecArray | null = /^(https?:\/\/[^/]+)(.*)$/.exec(u);
    if (m !== null) {
      u = `${m[1].toLowerCase()}${m[2]}`;
    }
    if (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  /**
   * 单引擎硬超时包装（#1633）：ms 内未定则以空结果收敛并标注「超时」；
   * 抓取异常收敛为「失败」，绝不让单通道挂死 Promise.all。
   * 定时器在正常/异常路径均清除，不留悬挂句柄。
   */
  private static withTimeout(p: Promise<WebSearchHit[]>, ms: number, stat: EngineStat): Promise<WebSearchHit[]> {
    return new Promise<WebSearchHit[]>((resolve: (v: WebSearchHit[]) => void): void => {
      let done: boolean = false;
      const timer: number = setTimeout((): void => {
        if (!done) {
          done = true;
          stat.state = '超时';
          resolve([]);
        }
      }, ms);
      p.then((hits: WebSearchHit[]): void => {
        if (!done) {
          done = true;
          clearTimeout(timer);
          stat.count = hits.length;
          resolve(hits);
        }
      }).catch((): void => {
        if (!done) {
          done = true;
          clearTimeout(timer);
          stat.state = '失败';
          resolve([]);
        }
      });
    });
  }

  /** 引擎 id → 展示名（诊断行用）。 */
  private static engineLabel(id: string): string {
    for (let i = 0; i < SEARCH_ENGINES.length; i++) {
      if (SEARCH_ENGINES[i].id === id) {
        return SEARCH_ENGINES[i].label;
      }
    }
    return id;
  }

  /**
   * 综合打分（#1632）：查询词命中率为核心信号（标题权重 > 摘要），来源权重仅作次级修正
   * （×4 上限 12，压不过满相关 9.5+完整度——高权重无关源不再霸前排），同分保持引擎内原始序。
   */
  private static rankScore(hit: WebSearchHit, toks: string[]): number {
    const w: number | undefined = SOURCE_WEIGHT[hit.source];
    const weight: number = w === undefined ? 1 : w;
    const titleHit: number = EncyclopediaService.hitRate(hit.title, toks);
    const sumHit: number = EncyclopediaService.hitRate(hit.summary, toks);
    const summaryBonus: number = hit.summary.length > 60 ? 1 : hit.summary.length > 0 ? 0.5 : 0;
    return weight * 4 + titleHit * 6 + sumHit * 2 + summaryBonus;
  }

  /** 去重键：标题归一（去空白/标点）+ 域名，避免同标题不同站被误合。 */
  private static dedupeKey(hit: WebSearchHit): string {
    const t: string = hit.title.replace(/[\s\p{P}]/gu, '').toLowerCase();
    let host: string = '';
    const m: RegExpExecArray | null = /^https?:\/\/([^\/]+)/.exec(hit.url);
    if (m !== null) {
      host = m[1].toLowerCase();
    }
    return `${t}@${host}`;
  }

  /**
   * 通用网页搜索（可配置）：按设置页启用的引擎并行抓取，单通道 8s 硬超时/失败静默跳过，
   * 结果按「标题+域名」与「归一化 URL」双层去重、按来源权重+查询词命中率重排序，取前 limit 条。
   * 逐引擎命中数进 stats（#1633），工具文案尾部回传，引擎改版失效不再静默。
   */
  static async searchWeb(query: string, limit: number = 0): Promise<WebSearchResult> {
    const result: WebSearchResult = { ok: false, items: [], error: '', stats: '' };
    const finalLimit: number = limit > 0 ? limit : EncyclopediaService.searchLimit();
    // #1634：候选量随最终条数联动放大，修「少引擎+高 limit 时候选不足」
    const perEngine: number = Math.max(PER_ENGINE_FETCH, finalLimit + 4);
    const enc: string = encodeURIComponent(query);
    const enabled: string[] = EncyclopediaService.enabledEngines();
    const tasks: Promise<WebSearchHit[]>[] = [];
    const stats: EngineStat[] = [];
    for (let i = 0; i < enabled.length; i++) {
      const id: string = enabled[i];
      const stat: EngineStat = { label: EncyclopediaService.engineLabel(id), count: 0, state: '' };
      stats.push(stat);
      if (id === 'baidu') {
        tasks.push(EncyclopediaService.withTimeout(
          WebSearchChannels.fetchText(`https://www.baidu.com/s?wd=${enc}`, BAIDU_UA)
            .then((h: string): WebSearchHit[] => WebSearchChannels.parseWebBaidu(h, perEngine)),
          EncyclopediaService.engineTimeoutMs, stat));
      } else if (id === 'bing') {
        tasks.push(EncyclopediaService.withTimeout(
          WebSearchChannels.fetchText(`https://cn.bing.com/search?q=${enc}&setlang=zh-hans`, BAIDU_UA)
            .then((h: string): WebSearchHit[] => WebSearchChannels.parseWebBing(h, perEngine)),
          EncyclopediaService.engineTimeoutMs, stat));
      } else if (id === 'so360') {
        tasks.push(EncyclopediaService.withTimeout(
          WebSearchChannels.fetchText(`https://www.so.com/s?q=${enc}`, BAIDU_UA)
            .then((h: string): WebSearchHit[] => WebSearchChannels.parseWeb360(h, perEngine)),
          EncyclopediaService.engineTimeoutMs, stat));
      } else if (id === 'sogou') {
        tasks.push(EncyclopediaService.withTimeout(
          WebSearchChannels.fetchText(`https://www.sogou.com/web?query=${enc}`, BAIDU_UA)
            .then((h: string): WebSearchHit[] => WebSearchChannels.parseWebSogou(h, perEngine)),
          EncyclopediaService.engineTimeoutMs, stat));
      } else if (id === 'wikipedia') {
        tasks.push(EncyclopediaService.withTimeout(
          WebSearchChannels.searchWikipediaWeb(query, perEngine), EncyclopediaService.engineTimeoutMs, stat));
      } else if (id === 'deepseek') {
        // #1636：无 DeepSeek 服务商 Key 就不发请求（不占超时、不烧配额），诊断行明标
        if (AiServiceConfig.apiKeyFor('deepseek').length === 0) {
          stat.state = '无Key';
          tasks.push(Promise.resolve<WebSearchHit[]>([]));
        } else {
          tasks.push(EncyclopediaService.withTimeout(
            WebSearchChannels.searchDeepseekWeb(query, perEngine), EncyclopediaService.engineTimeoutMs, stat));
        }
      } else if (id === 'openalex') {
        tasks.push(EncyclopediaService.withTimeout(
          WebSearchChannels.searchOpenalexWeb(query, perEngine), EncyclopediaService.engineTimeoutMs, stat));
      } else if (id === 'crossref') {
        tasks.push(EncyclopediaService.withTimeout(
          WebSearchChannels.searchCrossrefWeb(query, perEngine), EncyclopediaService.engineTimeoutMs, stat));
      }
    }
    if (tasks.length === 0) {
      result.error = '没有启用任何搜索引擎（请在设置页「搜索引擎」区勾选）';
      return result;
    }
    const rounds: WebSearchHit[][] = await Promise.all(tasks);
    // 必须在全部通道收敛后拼：EngineStat 由 withTimeout 就地回写
    result.stats = stats.map((s: EngineStat): string =>
      s.state.length > 0 ? `${s.label} 0(${s.state})` : `${s.label} ${s.count}`).join(' | ');
    const seen: Set<string> = new Set();
    const seenUrls: Set<string> = new Set();
    const merged: WebSearchHit[] = [];
    for (const hits of rounds) {
      for (const hit of hits) {
        const key: string = EncyclopediaService.dedupeKey(hit);
        if (seen.has(key)) {
          continue;
        }
        // #1635 第二层：归一化 URL 相同即转载/跟踪参数变体，跨标题也合并
        const norm: string = EncyclopediaService.normalizeUrl(hit.url);
        if (norm.length > 0 && seenUrls.has(norm)) {
          continue;
        }
        seen.add(key);
        if (norm.length > 0) {
          seenUrls.add(norm);
        }
        merged.push(hit);
      }
    }
    if (merged.length === 0) {
      result.error = '已启用引擎均无结果（可能被反爬拦截或无命中）';
      return result;
    }
    // 稳定重排序：分数降序，同分保持合并序
    const toks: string[] = EncyclopediaService.queryTokens(query);
    const indexed: RankedHit[] = [];
    for (let i = 0; i < merged.length; i++) {
      const item: RankedHit = { hit: merged[i], score: EncyclopediaService.rankScore(merged[i], toks), order: i };
      indexed.push(item);
    }
    indexed.sort((a, b) => (b.score - a.score) || (a.order - b.order));
    for (let i = 0; i < indexed.length && result.items.length < finalLimit; i++) {
      result.items.push(indexed[i].hit);
    }
    result.ok = true;
    return result;
  }
}
