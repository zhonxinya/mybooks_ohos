import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { Reader3Meta, Reader3Native } from './Reader3Native';

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
 * - 万相书城 www.wxscs.com 详情页 og:novel 同样全量，但 Apache 按 UA 拦截：
 *   桌面 UA 403、移动 UA 200（双指纹实测）——UA 按站点选择后现有规则即可覆盖。
 * - 晋江 www.jjwxc.net onebook.php 无 og，带 schema.org Book 微数据
 *   （itemprop=articleSection/author/genre/updataStatus/image/description），
 *   gb18030 编码（charset 声明在字节 240，decodeBody 嗅探窗口内）、SSR 直出无 JS 壳。
 * - 阅文系/掌阅系手贴场景（2026-11-20 双指纹实测）：书旗 t.shuqi.com/book/<id>.html、
 *   塔读 tadu.com/book/<id>/、云起 yunqi.qq.com/detail/<id> 均 og:novel 全量（通用规则即中）；
 *   云起站内导航的 /read/<id>/ 是阅读壳无 og → rewriteUrl 到 detail；潇湘 xxsy.net 无 og，
 *   Vue SSR 正文锚点走 parseXxsy；掌阅 m.zhangyue.com/detail/<id> 无 og，SSR 正文锚点
 *   走 parseZhangyue（主区无状态字段，<title> 的「完结小说」是 SEO 固定模板不可信）。
 * - 番茄小说 fanqienovel.com 详情页是 SPA（1.6MB __INITIAL_STATE__），但同 ID 的
 *   /api/book/info?bookId= 双指纹裸通、字段全量无签名（2026-11-20 实测）——走 rewriteUrl。
 * - legado 语料下一批镜像站审计（2026-11-20 双指纹实测）：群小说 qunxs.com/xiaoshuo_<id>.html
 *   与一页书 yiyeshu.cc/aibooks/<id>.html 均 og:novel 全量（通用规则零改动命中；一页书
 *   legado 规则只写了简介/封面是原作者偷懒，实际 og 齐全；qunxs 双斜杠封面 GET 200 可加载，
 *   HEAD 会 503 属方法差异）。阅友 yueyouxs.com=Vue SPA 且 goway API 需 HMACMD5 签名——不可接。
 *   笔趣阁系变体（biquge55.net/biquge.cc/xbiqu.com/2dingdian.net）已死域或停放（lander 壳）。
 * - 语料消耗期第二批（2026-11-20 批量 GET 存活+枚举 meta）：书坊 sfwx.com/\d+/\d+/ 与
 *   顶点 dingdians.com/index/<id>/ 均 og:novel 全量→通用零改动（顶点状态值「全本」已并入
 *   完本归一，且按桌面 OS 特征拦 UA——含 Windows NT 返回「身份验证」壳，移动 UA 放行，
 *   已并入 fetchText 按站 UA 特判；sfwx 协议相对封面由 absolutize 补全）；八零 txt80.cc
 *   是 TXT 下载站——无 og、
 *   description 为 SEO 拼接文、作者只在 keywords 里，元数据价值低不接。死域再添：
 *   zaohuatu/x23us/bgwxc/qiutiandog/wxmmain/xbiquge 等；sfwx 语料写 @get JS 而实页 og 齐全
 *   （legado 规则≠站点实况，第五次验证枚举铁律）。
 * - so-novel 候选 6 镜像域质量审计（2026-11-20 离线实跑）：mcxs/yeudusk/shuhaige/quanben
 *   实际带 og:novel 全量（通用规则即够）；唯 mianhuaks.com 无 og:novel 且封面多为站默认图
 *   /asset/default.jpg、无类别字段——需专用规则走主区正文锚点（parseMianhua）。
 * - 站点规则会随对方改版失效，属已知取舍（用户确认「仍尝试硬写几个网文源」）。
 */

const PAGE_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';
// 少数站按 UA 放行（wxscs 桌面 UA 403、移动 UA 200），这类站用移动 UA 抓
const MOBILE_UA: string =
  'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';
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
    // wxscs 桌面 UA 403；顶点按桌面 OS 特征拦（完整 Windows/NT UA 返回「身份验证」JS 壳，
    // 移动 UA 直出 og:novel 全量）——两类站同法：移动 UA 放行
    const ua: string = url.indexOf('wxscs.com') >= 0 || url.indexOf('dingdians.com') >= 0
      ? MOBILE_UA : PAGE_UA;
    const headers: rcp.RequestHeaders = {
      'User-Agent': ua,
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
    const trimmed: string = NovelMetaService.rewriteUrl(url.trim());
    const empty: NovelMeta = { ok: false, error: '', title: '', author: '', category: '',
      status: '', intro: '', cover: '', rule: '' };
    if (!/^https?:\/\/\S+/.test(trimmed)) {
      empty.error = 'url 需为 http(s) 详情页地址（来自 search_sonovel 结果）';
      return empty;
    }
    // 书源规则引擎优先（reader_core 预编译库 + legado 语料，url 命中书源即按规则提取）；
    // 引擎不可用/无匹配书源/提取失败时落到下面现有站点规则（会再抓一次，属兜底代价）
    const r3: Reader3Meta | null = await Reader3Native.meta(trimmed);
    if (r3 !== null && r3.ok) {
      const bySource: NovelMeta = { ok: true, error: '', title: r3.name, author: r3.author,
        category: r3.kind, status: NovelMetaService.normalizeStatus(r3.kind),
        intro: NovelMetaService.clean(r3.intro, INTRO_MAX), cover: r3.coverUrl,
        rule: `书源:${r3.rule}` };
      return bySource;
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
    let meta: NovelMeta;
    if (trimmed.indexOf('17k.com') >= 0) {
      meta = NovelMetaService.parse17k(html);
    } else if (trimmed.indexOf('wtzw.com') >= 0) {
      meta = NovelMetaService.parseWtzw(html);
    } else if (trimmed.indexOf('jjwxc.') >= 0 && trimmed.indexOf('onebook.php') >= 0) {
      meta = NovelMetaService.parseJjwxc(html);
    } else if (trimmed.indexOf('ujxsw.org') >= 0) {
      meta = NovelMetaService.parseUjxsw(html);
    } else if (trimmed.indexOf('mianhuaks.com') >= 0) {
      meta = NovelMetaService.parseMianhua(html);
    } else if (trimmed.indexOf('fanqienovel.com') >= 0) {
      meta = NovelMetaService.parseFanqie(html);
    } else if (trimmed.indexOf('xxsy.net') >= 0) {
      meta = NovelMetaService.parseXxsy(html);
    } else if (trimmed.indexOf('m.zhangyue.com/detail') >= 0) {
      meta = NovelMetaService.parseZhangyue(html);
    } else {
      meta = NovelMetaService.parseGeneric(html);
    }
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

  /**
   * 已知风控站的桌面 url 重写到可爬的同构入口（2026-11-20 实测）：
   * 起点 www.qidian.com 全端返回 202 probe.js 指纹挑战（curl/undici 皆拦），
   * 而 m.qidian.com/book/<id>/ 双指纹 200、SSR、og:novel 全量且书籍 id 相同。
   */
  static rewriteUrl(url: string): string {
    const qidian = url.match(/^https?:\/\/(?:www|book)\.qidian\.com\/(?:book|info)\/(\d+)\/?$/);
    if (qidian !== null) {
      return `https://m.qidian.com/book/${qidian[1]}/`;
    }
    // 悠久小说网 https 端口不通（2026-11-20 实测 curl 000），手贴 https 时降到 http
    const ujxsw = url.replace(/^https:\/\/(\S*ujxsw\.org)/, 'http://$1');
    // 番茄详情页是 SPA（1.6MB __INITIAL_STATE__），同 ID 的 info API 双指纹裸通、字段全量
    const fanqie = ujxsw.match(/^https?:\/\/fanqienovel\.com\/page\/(\d{15,20})\/?$/);
    if (fanqie !== null) {
      return `https://fanqienovel.com/api/book/info?bookId=${fanqie[1]}`;
    }
    // 云起书院站内导航链到 /read/<id>/（阅读壳无 og），同 ID 的 /detail/<id> 才带 og:novel 全量
    const yunqi = ujxsw.match(/^https?:\/\/(?:www\.)?yunqi\.qq\.com\/read\/(\d+)\/?$/);
    if (yunqi !== null) {
      return `https://yunqi.qq.com/detail/${yunqi[1]}`;
    }
    return ujxsw;
  }

  /** 连载状态归一（各站点原始词不同）：完结/完本/全本→已完本，连载→连载中，其余留空不猜。 */
  static normalizeStatus(raw: string): string {
    if (raw.indexOf('完结') >= 0 || raw.indexOf('完本') >= 0 || raw.indexOf('全本') >= 0) {
      return '已完本';
    }
    if (raw.indexOf('连载') >= 0) {
      return '连载中';
    }
    return '';
  }

  /**
   * 梧桐中文（www.wtzw.com/book/<id>.html，七猫系，2026-11-20 实测）：无 og 标签，
   * 锚点来自 legado 语料选择器转正则。书名在 li_tit 的 h1>a（顶层 <h1> 是站名宣传语，
   * 不可用 h1 兜底），状态是同块 <i class="tag">，类别页面上没有——留空不猜。
   */
  static parseWtzw(html: string): NovelMeta {
    const meta: NovelMeta = { ok: false, error: '', title: '', author: '', category: '',
      status: '', intro: '', cover: '', rule: '梧桐中文' };
    const tit = html.match(/class="li_tit"[\s\S]{0,200}?<a[^>]*>([^<]{1,60})<\/a>(?:\s*<i[^>]*>([^<]{2,10})<\/i>)?/);
    if (tit !== null) {
      meta.title = tit[1].trim();
      const rawStatus: string = tit[2] ?? '';
      if (rawStatus.indexOf('完结') >= 0 || rawStatus.indexOf('完本') >= 0) {
        meta.status = '已完本';
      } else if (rawStatus.indexOf('连载') >= 0) {
        meta.status = '连载中';
      }
    }
    const au = html.match(/class="sName"[^>]*>([^<]{1,30})/);
    if (au !== null) {
      meta.author = au[1].trim();
    }
    const pic = html.match(/class="w_pic"[\s\S]{0,150}?src="([^"]+)"/);
    if (pic !== null) {
      meta.cover = pic[1]; // 协议相对 //cdn.qimao.com/…，fetchDetail 统一补全
    }
    const intro = html.match(/class="pWorkInformation"[^>]*>([\s\S]{0,800}?)<\/div>/);
    if (intro !== null) {
      meta.intro = NovelMetaService.clean(intro[1], INTRO_MAX);
    }
    meta.ok = meta.title.length > 0 || meta.intro.length > 0 || meta.cover.length > 0;
    return meta;
  }

  /** 晋江（www.jjwxc.net/onebook.php?novelid=<id>，2026-11-20 实测）：无 og，走页面内
   *  schema.org Book 微数据锚点（itemprop）。编码 gb18030，由 decodeBody 嗅探解码；
   *  封面 img 有畸形 `_src` 属性在前，正则用 \ssrc= 只认真实 src。类别原样保留
   *  「原创-纯爱-幻想未来-剧情」四段串——分段语义站点自己也没说明，不猜。 */
  static parseJjwxc(html: string): NovelMeta {
    const meta: NovelMeta = { ok: false, error: '', title: '', author: '', category: '',
      status: '', intro: '', cover: '', rule: '晋江' };
    const name = html.match(/itemprop="articleSection">([^<]{1,80})</);
    if (name !== null) {
      meta.title = name[1].trim();
    }
    const author = html.match(/itemprop="author"[^>]*>([^<]{1,40})</);
    if (author !== null) {
      meta.author = author[1].trim();
    }
    const genre = html.match(/itemprop="genre">\s*([^<]{1,60}?)\s*</);
    if (genre !== null) {
      meta.category = genre[1].trim();
    }
    const rawStatus = html.match(/itemprop="updataStatus">([^<]{2,10})</);
    const status: string = rawStatus !== null ? rawStatus[1] : '';
    if (status.indexOf('完结') >= 0 || status.indexOf('完本') >= 0) {
      meta.status = '已完本';
    } else if (status.indexOf('连载') >= 0) {
      meta.status = '连载中';
    }
    const pic = html.match(/itemprop="image"[\s\S]{0,600}?\ssrc="([^"]+)"/);
    if (pic !== null) {
      meta.cover = pic[1];
    }
    // 上限 8000：实测本书案 4874 字符才到闭合 div（lazy 遇 </div> 即停，clean 再截 500）
    const intro = html.match(/itemprop="description">([\s\S]{0,8000}?)<\/div>/);
    if (intro !== null) {
      meta.intro = NovelMetaService.clean(intro[1], INTRO_MAX);
    }
    meta.ok = meta.title.length > 0 || meta.intro.length > 0 || meta.cover.length > 0;
    return meta;
  }

  /** 悠久书城（www.ujxsw.org/book/<id>/，2026-11-20 实测）：so-novel 候选 6 域里唯一
   *  未覆盖的。无 og/itemprop，锚点全在正文：书名/作者在 bookright 的 d_title h1>em
   *  （**顶层 <h1> 是站名「悠久小说网」，不可 h1 兜底**——同梧桐坑），类别在 id="count"
   *  「分 类：」span，封面 id="bookimg"，简介走 meta description；页面无状态字段——留空不猜。 */
  static parseUjxsw(html: string): NovelMeta {
    const meta: NovelMeta = { ok: false, error: '', title: '', author: '', category: '',
      status: '', intro: '', cover: '', rule: '悠久书城' };
    const tit = html.match(/class="d_title"[\s\S]{0,120}?<h1>([^<]{1,60})<em>/);
    if (tit !== null) {
      meta.title = tit[1].trim();
    }
    const au = html.match(/<em>作者：<a[^>]*>([^<]{1,40})<\/a>/);
    if (au !== null) {
      meta.author = au[1].trim();
    }
    const cat = html.match(/分 类：<span class="pd_r">([^<]{1,30})</);
    if (cat !== null) {
      meta.category = cat[1].trim();
    }
    const pic = html.match(/id="bookimg"[\s\S]{0,300}?src="([^"]+)"/);
    if (pic !== null) {
      meta.cover = pic[1];
    }
    meta.intro = NovelMetaService.clean(NovelMetaService.pickMeta(html, 'description'), INTRO_MAX);
    meta.ok = meta.title.length > 0 || meta.intro.length > 0 || meta.cover.length > 0;
    return meta;
  }

  /** 棉花书吧（www.mianhuaks.com/book/<id>/，2026-11-20 实测）：so-novel 候选 6 域里
   *  唯一无 og:novel 的镜像域，通用兜底只能拿到 SEO 模板句。锚点全在主区 section：
   *  h1 书名（本页唯一 h1 即书名，无站名坑）、作者 a、状态 p；封面在主区 img——多为
   *  站默认图 /asset/default.jpg，视为无封面留空不猜；页面无类别字段（导航「分类」
   *  只是 /tags.html 链接）——留空不猜。简介 id="desc"（内嵌 p/防盗图，clean 剥除）。 */
  static parseMianhua(html: string): NovelMeta {
    const meta: NovelMeta = { ok: false, error: '', title: '', author: '', category: '',
      status: '', intro: '', cover: '', rule: '棉花书吧' };
    const block = html.match(/flex items-start[\s\S]{0,900}?<\/section>/);
    const seg: string = block !== null ? block[0] : '';
    const tit = seg.match(/<h1[^>]*>([^<]{1,60})<\/h1>/);
    if (tit !== null) {
      meta.title = tit[1].trim();
    }
    const au = seg.match(/作者：<a[^>]*>([^<]{1,40})<\/a>/);
    if (au !== null) {
      meta.author = au[1].trim();
    }
    const st = seg.match(/状态：(连载|完结)/);
    if (st !== null) {
      meta.status = st[1] === '连载' ? '连载中' : '已完本';
    }
    const pic = seg.match(/<img[^>]*src="([^"]+)"/);
    if (pic !== null && pic[1].indexOf('default.jpg') < 0) {
      meta.cover = pic[1]; // 相对 /thumb/…，fetchDetail 统一补全；默认图不算封面
    }
    const intro = html.match(/id="desc"[^>]*>([\s\S]{0,4000}?)<\/div>/);
    if (intro !== null) {
      meta.intro = NovelMetaService.clean(intro[1], INTRO_MAX);
    }
    meta.ok = meta.title.length > 0 || meta.intro.length > 0 || meta.author.length > 0;
    return meta;
  }

  /** 番茄小说（fanqienovel.com，2026-11-20 实测）：详情页是 SPA，rewriteUrl 已把
   *  /page/<id> 重写为 /api/book/info?bookId=<id>（双指纹裸通、无签名），入参是其 JSON。
   *  creationStatus 语义经真页交叉验证：0=完结、1=连载；categoryV2 是 JSON 字符串，
   *  首元素恒为主分类（Dim=10，4 本实测）；封面 thumbUrl 为带签名 CDN url（约 30 天过期）。 */
  static parseFanqie(body: string): NovelMeta {
    const meta: NovelMeta = { ok: false, error: '', title: '', author: '', category: '',
      status: '', intro: '', cover: '', rule: '番茄小说' };
    let root: Record<string, Object>;
    try {
      root = JSON.parse(body) as Record<string, Object>;
    } catch (error) {
      meta.error = '番茄接口返回不是 JSON（站点改版或风控）';
      return meta;
    }
    if (String(root['code']) !== '0') {
      meta.error = `番茄接口错误：${String(root['message'] ?? '未知')}`;
      return meta;
    }
    const book = root['data'] as Record<string, string> | undefined;
    if (book === undefined) {
      meta.error = '番茄接口无 data 字段';
      return meta;
    }
    meta.title = book['bookName'] ?? '';
    meta.author = book['authorName'] ?? '';
    const cs: string = String(book['creationStatus'] ?? '');
    if (cs === '0') {
      meta.status = '已完本';
    } else if (cs === '1') {
      meta.status = '连载中';
    }
    try {
      const cats = JSON.parse(book['categoryV2'] ?? '[]') as Record<string, string>[];
      if (cats.length > 0) {
        meta.category = cats[0]['Name'] ?? '';
      }
    } catch (error) {
      // categoryV2 结构变化时类别留空，不连带丢其余字段
    }
    meta.intro = NovelMetaService.clean(book['abstract'] ?? '', INTRO_MAX);
    meta.cover = book['thumbUrl'] ?? '';
    meta.ok = meta.title.length > 0 || meta.intro.length > 0;
    if (!meta.ok && meta.error.length === 0) {
      meta.error = '番茄接口返回缺少书名/简介';
    }
    return meta;
  }

  /** 潇湘书院（www.xxsy.net/book/<id>，阅文系，2026-11-20 实测）：无 og，Vue SSR 正文锚点
   *  （来自 legado 规则 class.title@h1 / sub-cols / book_intro 转正则）。书名在
   *  class="title" 块内 h1（同梧桐坑，不可顶层 h1 兜底），作者同块「文 / 名」，
   *  状态/类别在 sub-cols span（首 span 是「会员作品」标签非状态），封面 bookprofile
   *  协议相对 //bookcover.yuewen.com，简介 id="book_intro" 纯文本 pre-line。 */
  static parseXxsy(html: string): NovelMeta {
    const meta: NovelMeta = { ok: false, error: '', title: '', author: '', category: '',
      status: '', intro: '', cover: '', rule: '潇湘书院' };
    const tit = html.match(/class="title"[\s\S]{0,200}?<h1[^>]*>([^<]{1,60})<\/h1>/);
    if (tit !== null) {
      meta.title = tit[1].trim();
    }
    const au = html.match(/文\s*\/\s*([^<]{1,40})<\/span>/);
    if (au !== null) {
      meta.author = au[1].trim();
    }
    const cols = html.match(/class="sub-cols"[\s\S]{0,400}?<\/p>/);
    if (cols !== null) {
      const st = cols[0].match(/(连载中|完结)/);
      if (st !== null) {
        meta.status = st[1] === '完结' ? '已完本' : '连载中';
      }
      const cat = cols[0].match(/类别：([^<\s][^<]{0,29})/);
      if (cat !== null) {
        meta.category = cat[1].trim();
      }
    }
    const pic = html.match(/class="bookprofile"[\s\S]{0,500}?<img[^>]*src="([^"]+)"/);
    if (pic !== null) {
      meta.cover = pic[1]; // 协议相对 //bookcover.yuewen.com，fetchDetail 统一补全
    }
    const intro = html.match(/id="book_intro"[^>]*>([\s\S]{0,4000}?)<\/div>/);
    if (intro !== null) {
      meta.intro = NovelMetaService.clean(intro[1], INTRO_MAX);
    }
    meta.ok = meta.title.length > 0 || meta.intro.length > 0;
    return meta;
  }

  /** 掌阅小说网（m.zhangyue.com/detail/<id>，2026-11-20 实测）：无 og，SSR 正文。
   *  主信息限定在 class="bookview" 块（推荐区「同类好书/作者其他书籍」也有
   *  「连载中/已完结」tag 与其他书同名信息，全站匹配必误取）；书名 dt.ellipsis2、
   *  作者 span.it red（同行前置的是出版方）、类别 data-js="goCategory"（该串还出现
   *  在 JS 绑定代码里，限定块内即唯一）。封面 img.bookcover 为绝对 https CDN，
   *  简介 brief_intro_txt 带「内容简介：」前缀需剥。主区无状态字段——留空不猜
   *  （<title> 的「完结小说_都市免费小说」是 SEO 固定模板，与真实类别/状态无关）。 */
  static parseZhangyue(html: string): NovelMeta {
    const meta: NovelMeta = { ok: false, error: '', title: '', author: '', category: '',
      status: '', intro: '', cover: '', rule: '掌阅小说网' };
    const block = html.match(/class="bookview"[\s\S]{0,1200}?<\/dl>/);
    if (block !== null) {
      const tit = block[0].match(/<dt class="ellipsis2">([^<]{1,60})<\/dt>/);
      if (tit !== null) {
        meta.title = tit[1].trim();
      }
      const au = block[0].match(/class="it red">([^<]{1,40})<\/span>/);
      if (au !== null) {
        meta.author = au[1].trim();
      }
      const cat = block[0].match(/data-js="goCategory"[^>]*>([^<]{1,30})<\/span>/);
      if (cat !== null) {
        meta.category = cat[1].trim();
      }
    }
    const pic = html.match(/class="bookcover"[^>]*src="([^"]+)"/);
    if (pic !== null) {
      meta.cover = pic[1]; // bookbk.img.zhangyue01.com 绝对 https
    }
    const intro = html.match(/data-js="brief_intro_txt"[^>]*>([\s\S]{0,4000}?)<\/p>/);
    if (intro !== null) {
      meta.intro = NovelMetaService.clean(intro[1].replace(/^内容简介：/, ''), INTRO_MAX);
    }
    meta.ok = meta.title.length > 0 || meta.intro.length > 0;
    return meta;
  }

  /** 通用规则：详情页带 og 元信息即入——优先 og:novel:* 结构化字段（2026-11-20 实测
   *  酷匠/刺猬猫/榕树下/纵横/飞卢官方站全量直出；纵横用 name= 写法、飞卢用 property= 写法，
   *  pickMeta 两种都认），否则退回 og:title/description/image 松散兜底。 */
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
      if (rawStatus.indexOf('完结') >= 0 || rawStatus.indexOf('完本') >= 0
        || rawStatus.indexOf('全本') >= 0) { // 顶点 dingdians.com 状态值是「全本」
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
      NovelMetaService.unwrapBrokenContent(NovelMetaService.pickMeta(html, 'og:description')), INTRO_MAX);
    if (meta.intro.length === 0) {
      meta.intro = NovelMetaService.clean(
        NovelMetaService.unwrapBrokenContent(NovelMetaService.pickMeta(html, 'description')), INTRO_MAX);
    }
    meta.ok = meta.intro.length > 0 || meta.cover.length > 0;
    return meta;
  }

  /**
   * 纵横 SSR 缺陷（2026-11-20 实测）：og:description 的值本身被模板再包了一层
   * `content=&quot;…&quot;`，不脱壳简介就带脏前后缀。其他站未见此问题，防御性剥一次。
   */
  private static unwrapBrokenContent(raw: string): string {
    if (/^content=["']?(?:&quot;)?/i.test(raw)) {
      let s: string = raw.replace(/^content=["']?(?:&quot;)?/i, '');
      s = s.replace(/(?:"|&quot;)$/, '');
      return s;
    }
    return raw;
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
