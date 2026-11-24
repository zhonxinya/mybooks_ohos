import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { AiServiceConfig } from './AiServiceConfig';

/** 通用网页搜索单条结果。summary 可能为空（纯标题卡片）。 */
export interface WebSearchHit {
  source: string;
  title: string;
  url: string;
  summary: string;
}

/** 百度主搜 UA：百科卡走 SERP 内嵌 JSON（baike item 页被安全验证挡，SERP 是唯一可用公开入口）。 */
export const BAIDU_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';
/** 摘要截断长度：够模型引用背景，又不吃掉对话上下文。 */
export const ABSTRACT_MAX: number = 600;

/**
 * search_web 通道层：8 个引擎的抓取与解析（4 个 SERP HTML 抓取 + 4 个官方 JSON API）。
 * 纯通道逻辑，不碰配置与合并排序（那些在 EncyclopediaService 编排层）。
 */
export class WebSearchChannels {
  /** GET 文本响应；非 2xx 抛错（通道层捕获转 ok=false）。 */
  static async fetchText(url: string, ua: string): Promise<string> {
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

  /** POST JSON 取文本响应（DeepSeek Search API 用）；非 2xx 抛错（通道层收敛）。 */
  static async fetchTextPost(url: string, json: string, bearer: string): Promise<string> {
    const headers: rcp.RequestHeaders = {
      'User-Agent': BAIDU_UA,
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${bearer}`,
    };
    const session: rcp.Session = rcp.createSession({
      requestConfiguration: { transfer: { timeout: { connectMs: 10000, transferMs: 20000 } } },
    });
    try {
      const request: rcp.Request = new rcp.Request(url, 'POST', headers, json);
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
  static unescapeJsonString(raw: string): string {
    try {
      return JSON.parse(`"${raw}"`) as string;
    } catch (_error) {
      return raw;
    }
  }

  static stripHtml(text: string): string {
    // 尾部再剥 icon-font 私有区字形（百度/360 卡片里的装饰字符，肉眼不可见但会让空标题漏判，#1663）
    return text.replace(/<[^>]*>/g, '').replace(/&[a-z]+;|&#\d+;/g, ' ')
      .replace(new RegExp('[\\uE000-\\uF8FF]', 'g'), '').replace(/\s+/g, ' ').trim();
  }

  /** organic 容器切段：按引擎锚点返回各容器起始下标（最多扫 30 个）。 */
  static containerStarts(html: string, anchorRe: RegExp): number[] {
    const starts: number[] = [];
    let pos: RegExpExecArray | null = anchorRe.exec(html);
    while (pos !== null && starts.length < 30) {
      starts.push(pos.index);
      pos = anchorRe.exec(html);
    }
    return starts;
  }

  /** 摘要统一截断。 */
  static trimSummary(text: string): string {
    return text.length > ABSTRACT_MAX ? `${text.substring(0, ABSTRACT_MAX)}…` : text;
  }

  /**
   * 百度结果：容器 `class="result c-container"`（organic）与 `result-op c-container`
   * （百科/文学实体等知识卡，#1663：只扫 organic 会把最权威的正主词条全丢掉，
   * 剩下的多是盗版/SEO 垃圾站）。
   * mu=属性为原站直链（比 link 跳转可靠；recommend_list 榜单推广排除）、
   * <!--s-text--> 标记标题（含 <em> 高亮，h3 兜底；知识卡标题在 <!--s-data:{...}-->
   * JSON 的 "html" 字段）；summary-text_* 为摘要（CSS Modules 哈希后缀会变；
   * 知识卡摘要在 s-data 的 "abstract" 字段）。
   */
  static parseWebBaidu(html: string, limit: number): WebSearchHit[] {
    const items: WebSearchHit[] = [];
    const starts: number[] = WebSearchChannels.containerStarts(html, /class="result(?:-op)? c-container/g);
    for (let i = 0; i < starts.length && items.length < limit; i++) {
      const from: number = starts[i];
      const to: number = i + 1 < starts.length ? starts[i + 1] : Math.min(html.length, from + 9000);
      const seg: string = html.substring(from, to);
      const mu: RegExpExecArray | null = /mu="(https?:\/\/[^"]{1,300})"/.exec(seg.substring(0, 900));
      if (mu === null || mu[1].indexOf('recommend_list') >= 0) {
        continue;
      }
      let rawTitle: string = '';
      const stext: RegExpExecArray | null = /<!--s-text-->([\s\S]{1,300}?)<!--\/s-text-->/
        .exec(seg);
      if (stext !== null) {
        rawTitle = stext[1];
      } else {
        const h3: RegExpExecArray | null = /<h3[^>]*>([\s\S]{1,300}?)<\/h3>/.exec(seg);
        if (h3 !== null) {
          rawTitle = h3[1];
        } else {
          // 知识卡（result-op）无 s-text/h3，标题取 s-data JSON 首个 "html" 字段
          const sd: RegExpExecArray | null = /<!--s-data:[\s\S]{0,1600}?"html":"([^"]{1,150})"/.exec(seg);
          if (sd !== null) {
            rawTitle = sd[1];
          }
        }
      }
      const title: string = WebSearchChannels.stripHtml(rawTitle);
      if (title.length === 0) {
        continue;
      }
      let summary: string = '';
      const sum: RegExpExecArray | null = /class="[^"]*summary-text_[^"]*">([\s\S]{1,600}?)<\/span>/.exec(seg);
      if (sum !== null) {
        summary = WebSearchChannels.stripHtml(sum[1]);
      } else {
        // 知识卡摘要：s-data JSON 的 "abstract" 字段
        const sdAbs: RegExpExecArray | null = /"abstract":"([^"]{1,300})"/.exec(seg);
        if (sdAbs !== null) {
          summary = WebSearchChannels.stripHtml(sdAbs[1]);
        }
      }
      items.push({ source: '百度', title: title, url: mu[1], summary: WebSearchChannels.trimSummary(summary) });
    }
    return items;
  }

  /** Bing organic：`<li class="b_algo">` 容器，h2>a href 即原站直链，b_lineclamp_* 为摘要（尾部「阅读更多」去掉）。 */
  static parseWebBing(html: string, limit: number): WebSearchHit[] {
    const items: WebSearchHit[] = [];
    const starts: number[] = WebSearchChannels.containerStarts(html, /<li class="b_algo"/g);
    for (let i = 0; i < starts.length && items.length < limit; i++) {
      const from: number = starts[i];
      const to: number = i + 1 < starts.length ? starts[i + 1] : Math.min(html.length, from + 6000);
      const seg: string = html.substring(from, to);
      const a: RegExpExecArray | null =
        /<h2[^>]*><a[^>]*href="(https?:\/\/[^"]{1,300})"[^>]*>([\s\S]{1,300}?)<\/a>/.exec(seg);
      if (a === null) {
        continue;
      }
      const title: string = WebSearchChannels.stripHtml(a[2]);
      if (title.length === 0) {
        continue;
      }
      let summary: string = '';
      const cap: RegExpExecArray | null = /class="b[^"]*lineclamp[^"]*"[^>]*>([\s\S]{1,600}?)<\/p>/.exec(seg);
      if (cap !== null) {
        summary = WebSearchChannels.stripHtml(cap[1]);
        // 页脚「阅读更多」链接文本与句尾重复出现，循环剥离
        while (summary.endsWith('阅读更多')) {
          summary = summary.substring(0, summary.length - 4);
        }
      }
      items.push({ source: 'Bing', title: title, url: a[1], summary: WebSearchChannels.trimSummary(summary) });
    }
    return items;
  }

  /** 360 organic：`<li class="res-list">` 容器，h3>a 链接（书站卡是 so.com/link 跳转，仍可点开），res-list-summary 为摘要。 */
  static parseWeb360(html: string, limit: number): WebSearchHit[] {
    const items: WebSearchHit[] = [];
    const starts: number[] = WebSearchChannels.containerStarts(html, /<li class="res-list"/g);
    for (let i = 0; i < starts.length && items.length < limit; i++) {
      const from: number = starts[i];
      const to: number = i + 1 < starts.length ? starts[i + 1] : Math.min(html.length, from + 6000);
      const seg: string = html.substring(from, to);
      const a: RegExpExecArray | null =
        /<h3[^>]*><a[^>]*href="(https?:\/\/[^"]{1,300})"[^>]*>([\s\S]{1,300}?)<\/a>/.exec(seg);
      if (a === null) {
        continue;
      }
      const title: string = WebSearchChannels.stripHtml(a[2]);
      if (title.length === 0) {
        continue;
      }
      let summary: string = '';
      const cap: RegExpExecArray | null = /class="res-list-summary"[^>]*>([\s\S]{1,600}?)<\/span>/.exec(seg);
      if (cap !== null) {
        summary = WebSearchChannels.stripHtml(cap[1]);
      }
      items.push({ source: '360', title: title, url: a[1], summary: WebSearchChannels.trimSummary(summary) });
    }
    return items;
  }

  /** 搜狗 organic：`<div class="vrwrap">` 容器，h3>a 为跳转链，str-text-info 为摘要。 */
  static parseWebSogou(html: string, limit: number): WebSearchHit[] {
    const items: WebSearchHit[] = [];
    const starts: number[] = WebSearchChannels.containerStarts(html, /class="(?:vrwrap|rb)"/g);
    for (let i = 0; i < starts.length && items.length < limit; i++) {
      const from: number = starts[i];
      const to: number = i + 1 < starts.length ? starts[i + 1] : Math.min(html.length, from + 6000);
      const seg: string = html.substring(from, to);
      const a: RegExpExecArray | null =
        /<h3[^>]*>[\s\S]{0,200}?<a[^>]*href="(https?:\/\/[^"]{1,300})"[^>]*>([\s\S]{1,300}?)<\/a>/.exec(seg);
      if (a === null) {
        continue;
      }
      const title: string = WebSearchChannels.stripHtml(a[2]);
      if (title.length === 0) {
        continue;
      }
      let summary: string = '';
      const cap: RegExpExecArray | null =
        /class="[^"]*(?:str-text-info|text-layout)[^"]*"[^>]*>([\s\S]{1,600}?)<\/(?:div|span|p)>/.exec(seg);
      if (cap !== null) {
        summary = WebSearchChannels.stripHtml(cap[1]);
      }
      items.push({ source: '搜狗', title: title, url: a[1], summary: WebSearchChannels.trimSummary(summary) });
    }
    return items;
  }

  /** 维基百科检索 API（中文站）：JSON 直出，比抓 HTML 稳。 */
  static async searchWikipediaWeb(query: string, limit: number): Promise<WebSearchHit[]> {
    const url: string = 'https://zh.wikipedia.org/w/api.php?action=query&list=search&format=json' +
      `&srlimit=${limit}&srsearch=${encodeURIComponent(query)}`;
    const text: string = await WebSearchChannels.fetchText(url, BAIDU_UA);
    const items: WebSearchHit[] = [];
    try {
      const root: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const q: Object | undefined = root['query'];
      if (q === undefined || q === null || typeof q !== 'object') {
        return items;
      }
      const list: Object | undefined = (q as Record<string, Object>)['search'];
      if (!Array.isArray(list)) {
        return items;
      }
      const arr: Object[] = list as Object[];
      for (let i = 0; i < arr.length && items.length < limit; i++) {
        const item: Object = arr[i];
        if (item === null || typeof item !== 'object') {
          continue;
        }
        const rec: Record<string, Object> = item as Record<string, Object>;
        const title: Object | undefined = rec['title'];
        const snippet: Object | undefined = rec['snippet'];
        if (typeof title !== 'string' || title.length === 0) {
          continue;
        }
        items.push({
          source: '维基百科',
          title: title,
          url: `https://zh.wikipedia.org/wiki/${encodeURIComponent(title)}`,
          summary: WebSearchChannels.trimSummary(
            typeof snippet === 'string' ? WebSearchChannels.stripHtml(snippet) : ''),
        });
      }
    } catch (_error) {
      // 解析失败：该通道算空
    }
    return items;
  }

  /**
   * DeepSeek 官方 Search API（#1636）：POST {baseUrl}/tools/search，Bearer=DeepSeek 服务商 Key。
   * 官方接口无 SERP 反爬顾虑，summary（600–800 字）优先、snippet 兜底；query 限 1–128 字符先截。
   */
  static async searchDeepseekWeb(query: string, limit: number): Promise<WebSearchHit[]> {
    const q: string = query.length > 128 ? query.substring(0, 128) : query;
    const count: number = Math.min(50, Math.max(1, limit));
    const url: string = `${AiServiceConfig.baseUrlFor('deepseek')}/tools/search`;
    const text: string = await WebSearchChannels.fetchTextPost(
      url, JSON.stringify({ query: q, count: count, need_content: false }),
      AiServiceConfig.apiKeyFor('deepseek'));
    const items: WebSearchHit[] = [];
    try {
      const root: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const list: Object | undefined = root['results'];
      if (!Array.isArray(list)) {
        return items;
      }
      const arr: Object[] = list as Object[];
      for (let i = 0; i < arr.length && items.length < limit; i++) {
        const item: Object = arr[i];
        if (item === null || typeof item !== 'object') {
          continue;
        }
        const rec: Record<string, Object> = item as Record<string, Object>;
        const title: Object | undefined = rec['title'];
        const link: Object | undefined = rec['url'];
        if (typeof title !== 'string' || title.length === 0 || typeof link !== 'string') {
          continue;
        }
        const summary: Object | undefined = rec['summary'];
        const snippet: Object | undefined = rec['snippet'];
        const rawSum: string = typeof summary === 'string' && summary.length > 0 ? summary :
          typeof snippet === 'string' ? snippet : '';
        items.push({
          source: 'DeepSeek',
          title: title,
          url: link,
          summary: WebSearchChannels.trimSummary(rawSum),
        });
      }
    } catch (_error) {
      // 解析失败：该通道算空（同维基 API 风格）
    }
    return items;
  }

  /**
   * 摘要倒排重建（OpenAlex 特有）：abstract_inverted_index 是 词→位置数组，
   * 按最大位置铺回空格分隔的正文。无摘要回空串。
   */
  static invertAbstract(inv: Record<string, Object> | undefined): string {
    if (inv === undefined || inv === null) {
      return '';
    }
    const words: string[] = Object.keys(inv);
    let maxPos: number = -1;
    for (let i = 0; i < words.length; i++) {
      const pos: Object | undefined = inv[words[i]];
      if (Array.isArray(pos)) {
        const arr: Object[] = pos as Object[];
        for (let k = 0; k < arr.length; k++) {
          const v: number = Number(arr[k]);
          if (v > maxPos) {
            maxPos = v;
          }
        }
      }
    }
    if (maxPos < 0) {
      return '';
    }
    const slots: string[] = new Array<string>(maxPos + 1).fill('');
    for (let i = 0; i < words.length; i++) {
      const pos: Object | undefined = inv[words[i]];
      if (Array.isArray(pos)) {
        const arr: Object[] = pos as Object[];
        for (let k = 0; k < arr.length; k++) {
          const v: number = Number(arr[k]);
          if (v >= 0 && v <= maxPos) {
            slots[v] = words[i];
          }
        }
      }
    }
    return slots.join(' ');
  }

  /**
   * OpenAlex 学术库检索（#1637）：免费无 Key 官方 JSON API，2.5 亿文献含中文条目。
   * URL 取 primary_location.landing_page_url，缺则回 DOI 解析链接；两者皆无跳过。
   */
  static async searchOpenalexWeb(query: string, limit: number): Promise<WebSearchHit[]> {
    const url: string = `https://api.openalex.org/works?search=${encodeURIComponent(query)}&per-page=${limit}`;
    const text: string = await WebSearchChannels.fetchText(url, BAIDU_UA);
    const items: WebSearchHit[] = [];
    try {
      const root: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const list: Object | undefined = root['results'];
      if (!Array.isArray(list)) {
        return items;
      }
      const arr: Object[] = list as Object[];
      for (let i = 0; i < arr.length && items.length < limit; i++) {
        const item: Object = arr[i];
        if (item === null || typeof item !== 'object') {
          continue;
        }
        const rec: Record<string, Object> = item as Record<string, Object>;
        const title: Object | undefined = rec['display_name'];
        if (typeof title !== 'string' || title.length === 0) {
          continue;
        }
        const doi: Object | undefined = rec['doi'];
        const loc: Object | undefined = rec['primary_location'];
        let link: string = typeof doi === 'string' ? doi : '';
        if (loc !== undefined && loc !== null && typeof loc === 'object') {
          const land: Object | undefined = (loc as Record<string, Object>)['landing_page_url'];
          if (typeof land === 'string' && land.length > 0) {
            link = land;
          }
        }
        if (link.length === 0) {
          continue;
        }
        const abstract: string = WebSearchChannels.invertAbstract(
          rec['abstract_inverted_index'] as Record<string, Object> | undefined);
        let summary: string = abstract;
        if (summary.length === 0) {
          // 无摘要（OpenAlex 约四成）：退化为 第一作者 (年份) 出处标注
          const authors: Object | undefined = rec['authorships'];
          let first: string = '';
          if (Array.isArray(authors) && (authors as Object[]).length > 0) {
            const a0: Object = (authors as Object[])[0];
            if (a0 !== null && typeof a0 === 'object') {
              const au: Object | undefined = (a0 as Record<string, Object>)['author'];
              if (au !== undefined && typeof au === 'object') {
                const nm: Object | undefined = (au as Record<string, Object>)['display_name'];
                if (typeof nm === 'string') {
                  first = nm;
                }
              }
            }
          }
          const year: Object | undefined = rec['publication_year'];
          summary = `${first}${typeof year === 'number' ? ` (${year})` : ''}`;
        }
        items.push({ source: 'OpenAlex', title: title, url: link, summary: WebSearchChannels.trimSummary(summary) });
      }
    } catch (_error) {
      // 解析失败：该通道算空（同维基 API 风格）
    }
    return items;
  }

  /**
   * Crossref 出版物检索（#1637）：免费无 Key 官方 JSON API，1.5 亿条 DOI 记录（论文/书/报告）。
   * abstract 常带 JATS XML 标签走 stripHtml；缺摘要退化为 作者 (年份) · 类型。
   */
  static async searchCrossrefWeb(query: string, limit: number): Promise<WebSearchHit[]> {
    const url: string = 'https://api.crossref.org/works?query=' + encodeURIComponent(query) +
      `&rows=${limit}&select=title,DOI,URL,author,issued,type,abstract`;
    const text: string = await WebSearchChannels.fetchText(url, BAIDU_UA);
    const items: WebSearchHit[] = [];
    try {
      const root: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const msg: Object | undefined = root['message'];
      if (msg === undefined || msg === null || typeof msg !== 'object') {
        return items;
      }
      const list: Object | undefined = (msg as Record<string, Object>)['items'];
      if (!Array.isArray(list)) {
        return items;
      }
      const arr: Object[] = list as Object[];
      for (let i = 0; i < arr.length && items.length < limit; i++) {
        const item: Object = arr[i];
        if (item === null || typeof item !== 'object') {
          continue;
        }
        const rec: Record<string, Object> = item as Record<string, Object>;
        const titles: Object | undefined = rec['title'];
        if (!Array.isArray(titles) || (titles as Object[]).length === 0 ||
          typeof (titles as Object[])[0] !== 'string' || ((titles as Object[])[0] as string).length === 0) {
          continue;
        }
        const title: string = (titles as Object[])[0] as string;
        const doi: Object | undefined = rec['DOI'];
        let link: string = typeof rec['URL'] === 'string' ? rec['URL'] as string : '';
        if (link.length === 0 && typeof doi === 'string') {
          link = `https://doi.org/${doi}`;
        }
        if (link.length === 0) {
          continue;
        }
        const abs: Object | undefined = rec['abstract'];
        let summary: string = typeof abs === 'string' ? WebSearchChannels.stripHtml(abs) : '';
        if (summary.length === 0) {
          const authors: Object | undefined = rec['author'];
          let first: string = '';
          if (Array.isArray(authors) && (authors as Object[]).length > 0) {
            const a0: Object = (authors as Object[])[0];
            if (a0 !== null && typeof a0 === 'object') {
              const nm: Object | undefined = (a0 as Record<string, Object>)['name'];
              if (typeof nm === 'string') {
                first = nm;
              }
            }
          }
          let year: string = '';
          const issued: Object | undefined = rec['issued'];
          if (issued !== undefined && typeof issued === 'object') {
            const dp: Object | undefined = (issued as Record<string, Object>)['date-parts'];
            if (Array.isArray(dp) && (dp as Object[]).length > 0 && Array.isArray((dp as Object[])[0]) &&
              ((dp as Object[])[0] as Object[]).length > 0) {
              year = String(((dp as Object[])[0] as Object[])[0]);
            }
          }
          const type: Object | undefined = rec['type'];
          summary = `${first}${year.length > 0 ? ` (${year})` : ''}` +
            `${typeof type === 'string' && type.length > 0 ? ` · ${type}` : ''}`;
        }
        items.push({ source: 'Crossref', title: title, url: link, summary: WebSearchChannels.trimSummary(summary) });
      }
    } catch (_error) {
      // 解析失败：该通道算空
    }
    return items;
  }
}
