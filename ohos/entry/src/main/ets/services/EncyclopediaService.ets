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
    return text.replace(/<[^>]*>/g, '').replace(/&[a-z]+;/g, ' ').trim();
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
}
