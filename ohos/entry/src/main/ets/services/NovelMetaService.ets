import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';

/**
 * 网文详情页元数据补全：输入书源站详情页 url（来自 so-novel 聚合搜索的 url 字段），
 * 输出简介/封面/类别/连载状态——so-novel 搜索唯一缺的两样就从这里补。
 *
 * 调研结论（2026-11-19 实测）：
 * - search.17k.com 被阿里云 WAF 的 acw_sc__v2 JS 挑战拦住（curl 405、其他指纹 200 挑战页），
 *   纯客户端不可靠，不做站内搜索；17K 书详情页 www.17k.com 无挑战、字段全部服务端渲染。
 * - so-novel 书源站（quanben.io / mcxs / shuhaige / mianhuaks / yeudusk 等）详情页多为
 *   服务端渲染，普遍带 og:description / og:image，作为通用兜底规则。
 * - 官方站 m.kujiang.com / www.ciweimao.com / www.rongshuxia.com 详情页带 og:novel:*
 *   全量结构化元标签（书名/作者/类别/状态，2026-11-20 实测），优先于松散 og 字段。
 * - 站点规则会随对方改版失效，属已知取舍（用户确认「仍尝试硬写几个网文源」）。
 */

const PAGE_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';
const INTRO_MAX: number = 500;

/** 详情页解析结果；ok=false 时 error 说明原因。 */
export interface NovelMeta {
  ok: boolean;
  error: string;
  title: string;
  author: string;
  category: string;
  status: string;
  intro: string;
  cover: string;
  /** 命中的解析规则名（'17K小说网' / '通用og'），给用户交代来源用。 */
  rule: string;
}

export class NovelMetaService {
  /** GET 文本响应；非 2xx 抛错（调用方转成用户可读文本）。 */
  private static async fetchText(url: string): Promise<string> {
    const headers: rcp.RequestHeaders = {
      'User-Agent': PAGE_UA,
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
      return NovelMetaService.decodeBody(body);
    } finally {
      session.close();
    }
  }

  /**
   * 字节级解码：先按 utf-8 嗅探页头 charset（ASCII 字节在 GBK 里透传；窗口必须 4KB——
   * 飞卢实测 charset 声明在字节 2413，2KB 窗口会漏），命中 gbk/gb2312/gb18030/big5
   * 就用对应编码全量解码（SDK @ohos.util.d.ts 声明 TextDecoder 支持这几种）。
   */
  static decodeBody(body: ArrayBuffer): string {
    const bytes: Uint8Array = new Uint8Array(body);
    const probeBytes: Uint8Array = new Uint8Array(body.slice(0, 4096));
    const probe: string = util.TextDecoder.create('utf-8', { ignoreBOM: true })
      .decodeToString(probeBytes);
    const cs: RegExpMatchArray | null = probe.match(/charset=["']?(gbk|gb2312|gb18030|big5)/i);
    if (cs !== null) {
      try {
        return util.TextDecoder.create(cs[1].toLowerCase(), { ignoreBOM: true })
          .decodeToString(bytes);
      } catch (error) {
        // 编码名不被支持时退回 utf-8，不让整条链路挂掉
      }
    }
    return util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(bytes);
  }

  /** 抓详情页并按站点解析；任何失败都以 ok=false + error 返回，不抛错。 */
  static async fetchDetail(url: string): Promise<NovelMeta> {
    const trimmed: string = url.trim();
    const empty: NovelMeta = { ok: false, error: '', title: '', author: '', category: '',
      status: '', intro: '', cover: '', rule: '' };
    if (!/^https?:\/\/\S+/.test(trimmed)) {
      empty.error = 'url 需为 http(s) 详情页地址（来自 search_sonovel 结果）';
      return empty;
    }
    let html: string = '';
    try {
      html = await NovelMetaService.fetchText(trimmed);
    } catch (error) {
      empty.error = `详情页获取失败：${error instanceof Error ? error.message : String(error)}`;
      return empty;
    }
    // WAF/JS 壳识别：拿回来的是挑战页时给出明确原因，避免报「解析不出」误导排查
    if (html.indexOf('acw_sc__v2') >= 0 || html.indexOf('aliyunwaf') >= 0) {
      empty.error = '该书源站有 WAF JS 挑战，客户端无法直接抓取，换一条书源候选';
      return empty;
    }
    const meta: NovelMeta = trimmed.indexOf('17k.com') >= 0
      ? NovelMetaService.parse17k(html)
      : NovelMetaService.parseGeneric(html);
    // 镜像站 og:image 常见相对路径（/files/…），按页面地址补全成可加载的绝对 url
    if (meta.cover.length > 0) {
      meta.cover = NovelMetaService.absolutize(meta.cover, trimmed);
    }
    if (!meta.ok && meta.error.length === 0) {
      meta.error = '详情页结构不认识（未命中 17K/通用规则），换一条书源候选试试';
    }
    return meta;
  }

  /** 17K 书详情页（www.17k.com/book/<id>.html，2026-11 实测结构）。 */
  static parse17k(html: string): NovelMeta {
    const meta: NovelMeta = { ok: false, error: '', title: '', author: '', category: '',
      status: '', intro: '', cover: '', rule: '17K小说网' };
    // 结构化对象：window.$__BOOK = { bookId: 1018082, bookName: '武逆焚天', authorName: '疯橘子', ... }
    const nameMatch = html.match(/bookName:\s*'([^']+)'/);
    if (nameMatch !== null) {
      meta.title = nameMatch[1];
    }
    const authorMatch = html.match(/authorName:\s*'([^']+)'/);
    if (authorMatch !== null) {
      meta.author = authorMatch[1];
    }
    meta.cover = NovelMetaService.pickMeta(html, 'og:image');
    meta.intro = NovelMetaService.clean(NovelMetaService.pickMeta(html, 'og:description'), INTRO_MAX);
    // 连载/完本 状态在书名下的 .label 角标区（不能全站匹配：顶部导航也有「完本小说」链接）
    const labelBlock = html.match(/<div class="label">([\s\S]{0,400}?)<\/div>/);
    if (labelBlock !== null) {
      const statusMatch = labelBlock[1].match(/>(连载|完本)小说</);
      if (statusMatch !== null) {
        meta.status = statusMatch[1] === '连载' ? '连载中' : '已完本';
      }
    }
    // 作品类别在「作品信息」表格：<th>作品类别：</th><td><a …>东方玄幻</a>
    const catMatch = html.match(/作品类别[：:]\s*<\/th>\s*<td[^>]*>\s*(?:<a[^>]*>)?([^<\s][^<>]{1,19})/);
    if (catMatch !== null) {
      meta.category = catMatch[1].trim();
    }
    meta.ok = meta.title.length > 0 || meta.intro.length > 0 || meta.cover.length > 0;
    return meta;
  }

  /** 通用规则：详情页带 og 元信息即入——优先 og:novel:* 结构化字段（2026-11-20 实测
   *  酷匠/刺猬猫/榕树下三家官方站全量直出），否则退回 og:title/description/image 松散兜底。 */
  static parseGeneric(html: string): NovelMeta {
    const meta: NovelMeta = { ok: false, error: '', title: '', author: '', category: '',
      status: '', intro: '', cover: '', rule: '通用og' };
    const bookName = NovelMetaService.pickMeta(html, 'og:novel:book_name');
    if (bookName.length > 0) {
      // og:novel 站：og:title 常带「最新章节-站名」尾巴，书名/作者/类别/状态一律取结构化字段
      meta.rule = 'og:novel';
      meta.title = bookName;
      meta.author = NovelMetaService.pickMeta(html, 'og:novel:author');
      meta.category = NovelMetaService.pickMeta(html, 'og:novel:category');
      const rawStatus = NovelMetaService.pickMeta(html, 'og:novel:status');
      if (rawStatus.indexOf('完结') >= 0 || rawStatus.indexOf('完本') >= 0) {
        meta.status = '已完本';
      } else if (rawStatus.indexOf('连载') >= 0) {
        meta.status = '连载中';
      }
    } else {
      meta.title = NovelMetaService.pickMeta(html, 'og:title');
      // <h1> 常是书名（og:title 缺失时兜底），去掉书名号外的站名尾巴
      if (meta.title.length === 0) {
        const h1 = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/);
        if (h1 !== null) {
          meta.title = NovelMetaService.stripTags(h1[1]);
        }
      }
    }
    meta.cover = NovelMetaService.pickMeta(html, 'og:image');
    meta.intro = NovelMetaService.clean(
      NovelMetaService.pickMeta(html, 'og:description'), INTRO_MAX);
    if (meta.intro.length === 0) {
      meta.intro = NovelMetaService.clean(NovelMetaService.pickMeta(html, 'description'), INTRO_MAX);
    }
    meta.ok = meta.intro.length > 0 || meta.cover.length > 0;
    return meta;
  }

  /** 取 <meta property|name="key" content="…"> 的 content；属性顺序两种都认。 */
  private static pickMeta(html: string, key: string): string {
    const pattern = new RegExp(
      `<meta[^>]+(?:property|name)=["']${key}["'][^>]+content=["']([^"']*)["']` +
        `|<meta[^>]+content=["']([^"']*)["'][^>]+(?:property|name)=["']${key}["']`, 'i');
    const m = html.match(pattern);
    if (m === null) {
      return '';
    }
    return (m[1] ?? m[2] ?? '').trim();
  }

  /** 相对/协议相对封面 url 按页面地址补全；已是 http(s) 的原样返回。 */
  private static absolutize(href: string, pageUrl: string): string {
    if (href.startsWith('http://') || href.startsWith('https://')) {
      return href;
    }
    const origin = pageUrl.match(/^https?:\/\/[^/]+/);
    if (origin === null) {
      return href;
    }
    if (href.startsWith('//')) {
      return `${pageUrl.startsWith('https') ? 'https:' : 'http:'}${href}`;
    }
    return `${origin[0]}${href.startsWith('/') ? '' : '/'}${href}`;
  }

  /** 详情页 meta 里 <br> 常被转义成 &lt;br&gt;：还原实体→换行→去标签→压空白→截断。 */
  private static clean(raw: string, max: number): string {
    if (raw.length === 0) {
      return '';
    }
    let s: string = raw
      .replace(/&lt;br\s*\/?&gt;/gi, '\n')
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/&nbsp;/g, ' ')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&amp;/g, '&');
    s = NovelMetaService.stripTags(s).replace(/\n{2,}/g, '\n').trim();
    if (s.length > max) {
      s = `${s.substring(0, max)}…`;
    }
    return s;
  }

  /** HTML 去标签并压平空白。 */
  private static stripTags(html: string): string {
    return html.replace(/<[^>]+>/g, ' ')
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&quot;/g, '"')
      .replace(/\s+/g, ' ')
      .trim();
  }
}
