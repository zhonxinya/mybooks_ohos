import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';

/**
 * 客户端直连的书籍元数据搜索（当前唯一站点：豆瓣读书）。
 *
 * 调研结论（2026-11-19 实测）：起点 www 有云盾 JS 挑战、m.qidian 是 CSR 壳带风控签名，
 * 纯 rcp 无法接入；豆瓣的 suggest 老接口与 subject 页对 UA 友好的请求不设卡。
 * 服务端 refer 通道（searchRefer）已覆盖豆瓣/百度/亚马逊/新华的候选与封面，
 * 本服务补的是 refer 拿不到的：按书名/ISBN 的即时检索 + 评分/出版社/ISBN/页数等详情。
 */

/** 豆瓣对空 UA/移动 UA 时会偶发 403，桌面 UA 实测稳定。 */
const DOUBAN_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';
const SUGGEST_LIMIT: number = 8;
const INTRO_MAX: number = 300;

/** suggest 接口的一条命中。 */
export interface DoubanHit {
  title: string;
  author: string;
  year: string;
  cover: string;
  url: string;
  subjectId: string;
}

/** subject 详情页解析结果；ok=false 时 error 说明原因。 */
export interface DoubanDetail {
  ok: boolean;
  error: string;
  title: string;
  rating: string;
  publisher: string;
  publishYear: string;
  isbn: string;
  pages: string;
  binding: string;
  price: string;
  author: string;
  intro: string;
}

export class MetaSearchService {
  /** GET 文本响应；非 2xx 抛错（调用方转成用户可读文本）。 */
  private static async fetchText(url: string): Promise<string> {
    const headers: rcp.RequestHeaders = {
      'User-Agent': DOUBAN_UA,
      'Accept-Language': 'zh-CN,zh;q=0.9',
    };
    const session: rcp.Session = rcp.createSession();
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

  /** 书名/ISBN 关键词联想检索（无鉴权的公开老接口）。 */
  static async suggest(query: string): Promise<DoubanHit[]> {
    const trimmed: string = query.trim();
    if (trimmed.length === 0) {
      return [];
    }
    const url = `https://book.douban.com/j/subject_suggest?q=${encodeURIComponent(trimmed)}`;
    const text: string = await MetaSearchService.fetchText(url);
    const hits: DoubanHit[] = [];
    const root = JSON.parse(text) as Object[];
    for (let i = 0; i < root.length && hits.length < SUGGEST_LIMIT; i++) {
      const item = root[i] as Record<string, string>;
      // type=b 才是图书（还有 t=影视、u=用户）
      if (item['type'] !== 'b') {
        continue;
      }
      hits.push({
        title: item['title'] ?? '',
        author: item['author_name'] ?? '',
        year: item['year'] ?? '',
        cover: item['pic'] ?? '',
        url: item['url'] ?? '',
        subjectId: item['id'] ?? '',
      });
    }
    return hits;
  }

  /** 抓 subject 页并解析评分/出版社/ISBN 等（页面结构 2026-11 实测）。 */
  static async detail(subjectId: string): Promise<DoubanDetail> {
    const empty: DoubanDetail = { ok: false, error: '', title: '', rating: '', publisher: '',
      publishYear: '', isbn: '', pages: '', binding: '', price: '', author: '', intro: '' };
    const id: string = subjectId.trim();
    if (!/^\d+$/.test(id)) {
      empty.error = 'subject_id 需为纯数字（来自 suggest 结果）';
      return empty;
    }
    let html: string = '';
    try {
      html = await MetaSearchService.fetchText(`https://book.douban.com/subject/${id}/`);
    } catch (error) {
      empty.error = `详情页获取失败：${error instanceof Error ? error.message : String(error)}`;
      return empty;
    }
    const titleMatch = html.match(/property="v:itemreviewed">([^<]+)</);
    const ratingMatch = html.match(/property="v:average">([0-9. ]+)</);
    const infoMatch = html.match(/id="info">([\s\S]*?)<\/div>/);
    const info: string = infoMatch !== null ? MetaSearchService.stripTags(infoMatch[1]) : '';
    const intros: RegExpMatchArray | null = html.match(/<div class="intro[^"]*">([\s\S]*?)<\/div>/g);
    let intro: string = '';
    if (intros !== null) {
      for (let i = 0; i < intros.length; i++) {
        const one: string = MetaSearchService.stripTags(intros[i])
          .replace(/^简介[:：]?\s*/, '').replace(/^\s*.*?本书简介\s*[:：]?\s*/, '').trim();
        if (one.length > intro.length && one.length > 20) {
          intro = one;
        }
      }
    }
    if (intro.length > INTRO_MAX) {
      intro = `${intro.substring(0, INTRO_MAX)}…`;
    }
    const author: string = MetaSearchService.pickLabel(info, '作者');
    return {
      ok: true,
      error: '',
      title: titleMatch !== null ? titleMatch[1].trim() : '',
      rating: ratingMatch !== null ? ratingMatch[1].trim() : '',
      publisher: MetaSearchService.pickLabel(info, '出版社'),
      publishYear: MetaSearchService.pickLabel(info, '出版时间'),
      isbn: MetaSearchService.pickLabel(info, 'ISBN'),
      pages: MetaSearchService.pickLabel(info, '页数'),
      binding: MetaSearchService.pickLabel(info, '装帧'),
      price: MetaSearchService.pickLabel(info, '定价'),
      author: author.split(/[\/\s]+/)[0],
      intro,
    };
  }

  /** HTML 去标签并压平空白，供 label:value 文本检索。 */
  private static stripTags(html: string): string {
    return html.replace(/<[^>]+>/g, ' ')
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&quot;/g, '"')
      .replace(/\s+/g, ' ')
      .trim();
  }

  /** 从去标签的 info 文本取「label: value」；value 截到下一个常见标签名或结尾。 */
  private static pickLabel(info: string, label: string): string {
    const pattern = new RegExp(`${label}\\s*[:：]\\s*([^<]*?)(?=\\s(?:作者|出版社|出品方|副标题|译者|丛书|出版年|出版时间|页数|原作名|装帧|定价|ISBN|评分人数)|$)`);
    const m = info.match(pattern);
    return m !== null ? m[1].trim() : '';
  }
}
