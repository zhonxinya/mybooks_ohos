import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';

/** 百科单通道检索结果。ok=false 时 error 说明原因（供工具层如实回传）。 */
export interface EncyclopediaHit {
  source: string;
  ok: boolean;
  title: string;
  abstract: string;
  url: string;
  error: string;
}

/** 通用网页搜索单条结果。summary 可能为空（纯标题卡片）。 */
export interface WebSearchHit {
  source: string;
  title: string;
  url: string;
  summary: string;
}

/** 通用网页搜索整体结果：ok=false 时 error 说明原因（同百科通道容错风格）。 */
export interface WebSearchResult {
  ok: boolean;
  items: WebSearchHit[];
  error: string;
}

/** 百度主搜 UA：百科卡走 SERP 内嵌 JSON（baike item 页被安全验证挡，SERP 是唯一可用公开入口）。 */
const BAIDU_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';
/** 摘要截断长度：够模型引用背景，又不吃掉对话上下文。 */
const ABSTRACT_MAX: number = 600;

export class EncyclopediaService {
  /** GET 文本响应；非 2xx 抛错（通道层捕获转 ok=false）。 */
  private static async fetchText(url: string, ua: string): Promise<string> {
    const headers: rcp.RequestHeaders = {
      'User-Agent': ua,
      'Accept-Language': 'zh-CN,zh;q=0.9',
    };
    // 连接超时压到 10s：zh.wikipedia 在局域网常被 DNS 污染到不可达 IP，
    // 默认 60s 会 TCP 挂等，拖死整个工具调用。
    const session: rcp.Session = rcp.createSession({
      requestConfiguration: { transfer: { timeout: { connectMs: 10000, transferMs: 20000 } } },
    });
    try {
      const request: rcp.Request = new rcp.Request(url, 'GET', headers);
      const response: rcp.Response = await session.fetch(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw new Error(`HTTP ${response.statusCode}`);
      }
      const body: ArrayBuffer | undefined = response.body;
      if (body === undefined) {
        return '';
      }
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      return decoder.decodeToString(new Uint8Array(body));
    } finally {
      session.close();
    }
  }

  /** JSON 字符串字面量反转义（SERP 内嵌 JSON 里的 \" \\ \u 序列）。 */
  private static unescapeJsonString(raw: string): string {
    try {
      return JSON.parse(`"${raw}"`) as string;
    } catch (_error) {
      return raw;
    }
  }

  private static stripHtml(text: string): string {
    return text.replace(/<[^>]*>/g, '').replace(/&[a-z]+;|&#\d+;/g, ' ').replace(/\s+/g, ' ').trim();
  }

  /** 百度百科：抓百度主搜结果页里的百科卡（title/url/abstract 内嵌 JSON）。 */
  static async searchBaike(query: string): Promise<EncyclopediaHit> {
    const hit: EncyclopediaHit = { source: '百度百科', ok: false, title: '', abstract: '', url: '', error: '' };
    try {
      const html: string = await EncyclopediaService.fetchText(
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
      hit.title = EncyclopediaService.unescapeJsonString(title);
      hit.url = url;
      hit.abstract = EncyclopediaService.unescapeJsonString(rawAbstract);
      if (hit.abstract.length > ABSTRACT_MAX) {
        hit.abstract = `${hit.abstract.substring(0, ABSTRACT_MAX)}…`;
      }
      return hit;
    } catch (error) {
      hit.error = error instanceof Error ? error.message : `${error}`;
      return hit;
    }
  }

  /** 维基百科中文：MediaWiki 检索 API（snippet 即摘要，一次请求）。局域网 DNS 污染时连接失败走 error。 */
  static async searchWikipedia(query: string): Promise<EncyclopediaHit> {
    const hit: EncyclopediaHit = { source: '维基百科', ok: false, title: '', abstract: '', url: '', error: '' };
    try {
      const text: string = await EncyclopediaService.fetchText(
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
      hit.abstract = EncyclopediaService.stripHtml(snippet);
      if (hit.abstract.length > ABSTRACT_MAX) {
        hit.abstract = `${hit.abstract.substring(0, ABSTRACT_MAX)}…`;
      }
      hit.url = `https://zh.wikipedia.org/wiki/${encodeURIComponent(title.replace(/ /g, '_'))}`;
      return hit;
    } catch (error) {
      hit.error = error instanceof Error ? error.message : `${error}`;
      return hit;
    }
  }

  /** organic 容器切段：按引擎锚点返回各容器起始下标（最多扫 30 个）。 */
  private static containerStarts(html: string, anchorRe: RegExp): number[] {
    const starts: number[] = [];
    let pos: RegExpExecArray | null = anchorRe.exec(html);
    while (pos !== null && starts.length < 30) {
      starts.push(pos.index);
      pos = anchorRe.exec(html);
    }
    return starts;
  }

  /** 摘要统一截断。 */
  private static trimSummary(text: string): string {
    return text.length > ABSTRACT_MAX ? `${text.substring(0, ABSTRACT_MAX)}…` : text;
  }

  /**
   * 百度 organic：容器 `class="result c-container"`。
   * mu=属性为原站直链（比 link 跳转可靠；recommend_list 榜单推广排除）、
   * <!--s-text--> 标记标题（含 <em> 高亮，h3 兜底）、summary-text_* 为摘要（CSS Modules 哈希后缀会变）。
   */
  private static parseWebBaidu(html: string, limit: number): WebSearchHit[] {
    const items: WebSearchHit[] = [];
    const starts: number[] = EncyclopediaService.containerStarts(html, /class="result c-container/g);
    for (let i = 0; i < starts.length && items.length < limit; i++) {
      const from: number = starts[i];
      const to: number = i + 1 < starts.length ? starts[i + 1] : Math.min(html.length, from + 9000);
      const seg: string = html.substring(from, to);
      const mu: RegExpExecArray | null = /mu="(https?:\/\/[^"]{1,300})"/.exec(seg.substring(0, 900));
      if (mu === null || mu[1].indexOf('recommend_list') >= 0) {
        continue;
      }
      let rawTitle: string = '';
      const stext: RegExpExecArray | null = /<!--s-text-->([\s\S]{1,300}?)<!--\/s-text-->/.exec(seg);
      if (stext !== null) {
        rawTitle = stext[1];
      } else {
        const h3: RegExpExecArray | null = /<h3[^>]*>([\s\S]{1,300}?)<\/h3>/.exec(seg);
        if (h3 !== null) {
          rawTitle = h3[1];
        }
      }
      const title: string = EncyclopediaService.stripHtml(rawTitle);
      if (title.length === 0) {
        continue;
      }
      let summary: string = '';
      const sum: RegExpExecArray | null = /class="[^"]*summary-text_[^"]*">([\s\S]{1,600}?)<\/span>/.exec(seg);
      if (sum !== null) {
        summary = EncyclopediaService.stripHtml(sum[1]);
      }
      items.push({ source: '百度', title: title, url: mu[1], summary: EncyclopediaService.trimSummary(summary) });
    }
    return items;
  }

  /** Bing organic：`<li class="b_algo">` 容器，h2>a href 即原站直链，b_lineclamp_* 为摘要（尾部「阅读更多」去掉）。 */
  private static parseWebBing(html: string, limit: number): WebSearchHit[] {
    const items: WebSearchHit[] = [];
    const starts: number[] = EncyclopediaService.containerStarts(html, /<li class="b_algo"/g);
    for (let i = 0; i < starts.length && items.length < limit; i++) {
      const from: number = starts[i];
      const to: number = i + 1 < starts.length ? starts[i + 1] : Math.min(html.length, from + 6000);
      const seg: string = html.substring(from, to);
      const a: RegExpExecArray | null =
        /<h2[^>]*><a[^>]*href="(https?:\/\/[^"]{1,300})"[^>]*>([\s\S]{1,300}?)<\/a>/.exec(seg);
      if (a === null) {
        continue;
      }
      const title: string = EncyclopediaService.stripHtml(a[2]);
      if (title.length === 0) {
        continue;
      }
      let summary: string = '';
      const cap: RegExpExecArray | null = /class="b[^"]*lineclamp[^"]*"[^>]*>([\s\S]{1,600}?)<\/p>/.exec(seg);
      if (cap !== null) {
        summary = EncyclopediaService.stripHtml(cap[1]);
        // 页脚「阅读更多」链接文本与句尾重复出现，循环剥离
        while (summary.endsWith('阅读更多')) {
          summary = summary.substring(0, summary.length - 4);
        }
      }
      items.push({ source: 'Bing', title: title, url: a[1], summary: EncyclopediaService.trimSummary(summary) });
    }
    return items;
  }

  /** 360 organic：`<li class="res-list">` 容器，h3>a 链接（书站卡是 so.com/link 跳转，仍可点开），res-list-summary 为摘要。 */
  private static parseWeb360(html: string, limit: number): WebSearchHit[] {
    const items: WebSearchHit[] = [];
    const starts: number[] = EncyclopediaService.containerStarts(html, /<li class="res-list"/g);
    for (let i = 0; i < starts.length && items.length < limit; i++) {
      const from: number = starts[i];
      const to: number = i + 1 < starts.length ? starts[i + 1] : Math.min(html.length, from + 6000);
      const seg: string = html.substring(from, to);
      const a: RegExpExecArray | null =
        /<h3[^>]*><a[^>]*href="(https?:\/\/[^"]{1,300})"[^>]*>([\s\S]{1,300}?)<\/a>/.exec(seg);
      if (a === null) {
        continue;
      }
      const title: string = EncyclopediaService.stripHtml(a[2]);
      if (title.length === 0) {
        continue;
      }
      let summary: string = '';
      const cap: RegExpExecArray | null = /class="res-list-summary"[^>]*>([\s\S]{1,600}?)<\/span>/.exec(seg);
      if (cap !== null) {
        summary = EncyclopediaService.stripHtml(cap[1]);
      }
      items.push({ source: '360', title: title, url: a[1], summary: EncyclopediaService.trimSummary(summary) });
    }
    return items;
  }

  /**
   * 通用网页搜索：百度/Bing/360 三引擎并行取普通结果（桌面 UA 三通道实测可达；
   * 搜狗 302 反爬、DuckDuckGo 网络不可达，均不引入）。单通道失败静默跳过，
   * 合并按标题去重（三引擎百科/书站命中高度重叠），最多 limit 条；三通道全空才回错。
   */
  static async searchWeb(query: string, limit: number = 8): Promise<WebSearchResult> {
    const result: WebSearchResult = { ok: false, items: [], error: '' };
    const enc: string = encodeURIComponent(query);
    // 三引擎共用同一桌面 UA（百度/必应/360 实测均可用；BAIDU_UA 即通用 Chrome 串）
    const rounds: WebSearchHit[][] = await Promise.all([
      EncyclopediaService.fetchText(`https://www.baidu.com/s?wd=${enc}`, BAIDU_UA)
        .then((h: string): WebSearchHit[] => EncyclopediaService.parseWebBaidu(h, 5))
        .catch((): WebSearchHit[] => []),
      EncyclopediaService.fetchText(`https://cn.bing.com/search?q=${enc}&setlang=zh-hans`, BAIDU_UA)
        .then((h: string): WebSearchHit[] => EncyclopediaService.parseWebBing(h, 5))
        .catch((): WebSearchHit[] => []),
      EncyclopediaService.fetchText(`https://www.so.com/s?q=${enc}`, BAIDU_UA)
        .then((h: string): WebSearchHit[] => EncyclopediaService.parseWeb360(h, 5))
        .catch((): WebSearchHit[] => []),
    ]);
    const seen: Set<string> = new Set();
    for (const hits of rounds) {
      for (const hit of hits) {
        if (result.items.length >= limit) {
          break;
        }
        if (seen.has(hit.title)) {
          continue;
        }
        seen.add(hit.title);
        result.items.push(hit);
      }
    }
    if (result.items.length === 0) {
      result.error = '百度/Bing/360 均无结果（可能被反爬拦截或无命中）';
      return result;
    }
    result.ok = true;
    return result;
  }
}
