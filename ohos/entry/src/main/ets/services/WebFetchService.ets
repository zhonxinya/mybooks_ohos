import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';

/**
 * AI 内置网页抓取（fetch_url 工具）：直连 GET 任意 http(s) 页面，
 * 剥离脚本/样式后提取标题与正文纯文本。全服务商可用——
 * 百炼 MCP WebFetch（mcp_wf_*）仅 Token Plan 动态挂载，不能覆盖 DeepSeek/OpenCode 等。
 */

export interface WebFetchResult {
  ok: boolean;
  title: string;
  /** 正文纯文本（已截断）；失败为空。 */
  text: string;
  error: string;
  /** 'render'=HTTP 通道拿不到正文（JS 空壳/反爬拦截），调用方可改用 ArkWeb 渲染重试。 */
  hint: string;
}

/** 抓取字节上限：超出部分不进入解码，防大文件/二进制拖死工具调用。 */
const FETCH_MAX_BYTES: number = 512 * 1024;
/** 正文返回上限（字符）：控制进模型上下文的预算。 */
const FETCH_TEXT_MAX: number = 6000;

export class WebFetchService {
  /** URL 校验：仅 http(s) 完整地址；挡 javascript:/data:/file: 与超长输入。 */
  static validUrl(url: string): boolean {
    const t: string = url.trim();
    return (t.startsWith('http://') || t.startsWith('https://')) && t.length > 10 && t.length <= 500;
  }

  /** 抓页面提取正文；一切失败收敛到 result.error，不抛异常（工具层直接回给模型）。 */
  static async fetch(rawUrl: string): Promise<WebFetchResult> {
    const url: string = rawUrl.trim();
    if (!WebFetchService.validUrl(url)) {
      return { ok: false, title: '', text: '', error: 'URL 无效：需以 http:// 或 https:// 开头的完整地址', hint: '' };
    }
    // 类浏览器指纹：真实 Chrome/Android UA（OpenHarmony 原生 UA 常被 WAF 直接拦 403）
    const headers: rcp.RequestHeaders = {
      'User-Agent': 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 ' +
        '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.6',
    };
    // 超时同搜索引擎通道（EncyclopediaService.fetchText）：连不上 10s 内放弃，别挂死回路
    const session: rcp.Session = rcp.createSession({
      requestConfiguration: { transfer: { timeout: { connectMs: 10000, transferMs: 20000 } } },
    });
    try {
      const request: rcp.Request = new rcp.Request(url, 'GET', headers);
      const response: rcp.Response = await session.fetch(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return {
          ok: false, title: '', text: '',
          error: `HTTP ${response.statusCode}`,
          hint: WebFetchService.needsRender(response.statusCode, '') ? 'render' : '',
        };
      }
      const body: ArrayBuffer | undefined = response.body;
      if (body === undefined || body.byteLength === 0) {
        return { ok: false, title: '', text: '', error: '页面为空', hint: 'render' };
      }
      const bytes: Uint8Array = new Uint8Array(body);
      const capped: Uint8Array = bytes.byteLength > FETCH_MAX_BYTES ?
        bytes.subarray(0, FETCH_MAX_BYTES) : bytes;
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const html: string = decoder.decodeToString(capped);
      const titleMatch: RegExpExecArray | null = /<title[^>]*>([^<]{1,200})<\/title>/i.exec(html);
      const title: string = titleMatch !== null ? WebFetchService.decodeEntities(titleMatch[1]).trim() : '';
      let text: string = WebFetchService.extractBody(html);
      if (text.length === 0 || WebFetchService.needsRender(200, html)) {
        return {
          ok: false, title: title, text: '',
          error: '未能提取可读正文（页面可能由脚本渲染）', hint: 'render',
        };
      }
      if (text.length > FETCH_TEXT_MAX) {
        text = `${text.substring(0, FETCH_TEXT_MAX)}…（正文过长已截断）`;
      }
      return { ok: true, title: title, text: text, error: '', hint: '' };
    } catch (error) {
      return { ok: false, title: '', text: '', error: `${error}`, hint: '' };
    } finally {
      session.close();
    }
  }

  /**
   * 类浏览器判定：HTTP 通道结果不可用、值得真渲染重试吗。
   * status=HTTP 码（html 传 '' 时仅按码判）；html=原始页面。
   */
  static needsRender(status: number, html: string): boolean {
    if (status === 403 || status === 429 || status === 451 || status === 503) {
      return true;
    }
    if (html.length === 0) {
      return false;
    }
    if (WebFetchService.extractBody(html).length >= 200) {
      return false;
    }
    // JS 空壳特征：脚本多而可读文本少 / 「请启用 JavaScript」提示 / SPA 挂载点
    const scripts: number = (html.match(/<script/gi) ?? []).length;
    return scripts >= 2 ||
      /enable\s+javascript|需要启用\s*javascript|请先开启\s*javascript/i.test(html) ||
      /id=["'](app|root)["']/i.test(html);
  }

  /** 去脚本/样式/注释/head，块级边界转换行，去标签，实体解码，压空白。 */
  static extractBody(html: string): string {
    let s: string = html
      .replace(/<script[^>]*>[\s\S]*?<\/script>/gi, ' ')
      .replace(/<style[^>]*>[\s\S]*?<\/style>/gi, ' ')
      .replace(/<noscript[^>]*>[\s\S]*?<\/noscript>/gi, ' ')
      .replace(/<template[^>]*>[\s\S]*?<\/template>/gi, ' ')
      .replace(/<svg[\s\S]*?<\/svg>/gi, ' ')
      .replace(/<!--[\s\S]*?-->/g, ' ')
      .replace(/<head[^>]*>[\s\S]*?<\/head>/gi, ' ')
      .replace(/<(br|\/p|\/div|\/li|\/h[1-6]|\/tr|\/section)[^>]*>/gi, '\n')
      .replace(/<[^>]*>/g, ' ');
    s = WebFetchService.decodeEntities(s);
    s = s.replace(/[ \t\r]+/g, ' ').replace(/ ?\n ?/g, '\n').replace(/\n{3,}/g, '\n\n');
    return s.trim();
  }

  /** 常见命名实体 + 十进制数字实体（先剥标签后解码，无注入风险）。 */
  static decodeEntities(text: string): string {
    let out: string = text
      .replace(/&nbsp;/g, ' ').replace(/&ensp;/g, ' ').replace(/&emsp;/g, ' ')
      .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'")
      .replace(/&mdash;/g, '—').replace(/&ndash;/g, '–')
      .replace(/&hellip;/g, '…');
    out = out.replace(/&#(\d{1,6});/g, (m: string, code: string): string => {
      const n: number = Number(code);
      if (n < 32 || n > 65533) {
        return ' ';
      }
      return String.fromCharCode(n);
    });
    // &amp; 最后解，避免 &amp;lt; 双重解码
    return out.replace(/&amp;/g, '&');
  }
}
