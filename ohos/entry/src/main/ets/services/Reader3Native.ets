import entry from 'libentry.so';
import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * reader_core 书源引擎桥（预编译 libreader3_native.so，见 cpp/reader3_meta.cpp）。
 * 范围（用户确认）：只接 book_info 详情元数据；search/toc/content 不接。
 *
 * 分工：引擎在 native 线程同步跑规则求值（CSS/JSONPath/Regex + QuickJS），
 * 每个 http 请求经 threadsafe_function 投递回这里，用 rcp 抓取（重定向、
 * charset→UTF-8 解码归宿主——native 无可靠 GBK 转换），再 reader3Deliver 回填。
 * 书源库 bookmeta_sources.json（legado 语料清洗版，只留 book_info 字段；
 * canReName/checkKeyWord 已删）**不随包分发**——属用户数据，放应用沙箱
 * files 目录（hdc file send 或后续应用内导入）；缺失即视为无书源，走 parse 兜底。
 * url→书源匹配是宿主责任（引擎不做）：bookUrlPattern 正则优先，
 * 再退 bookSourceUrl（legado「源名@baseUrl」约定，取 @ 右侧）部分匹配。
 */

const SOURCE_FILE: string = 'bookmeta_sources.json';
const DEFAULT_UA: string =
  'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

interface BookSource {
  bookSourceUrl: string;
  bookSourceName: string;
  bookUrlPattern?: string;
  enabled?: boolean;
}

interface HttpReq {
  kind: string;
  method: string;
  url: string;
  headers?: Record<string, string>;
  body?: string;
  charset?: string;
  timeout_ms?: number;
}

/** book_info 结果；ok=false 时 error 说明原因。字段名沿用引擎输出（legado 语义）。 */
export interface Reader3Meta {
  ok: boolean;
  error: string;
  /** 命中书源名，给用户交代来源。 */
  rule: string;
  name: string;
  author: string;
  kind: string;
  intro: string;
  coverUrl: string;
  tocUrl: string;
  lastChapter: string;
}

export class Reader3Native {
  // ArkTS 无 null 收窄：缓存用「数组+loaded 标志」而非可空引用
  private static sources: BookSource[] = [];
  private static loaded: boolean = false;
  private static callbackReady: boolean = false;
  private static matchLogged: boolean = false;

  /** 本 ABI 是否链入了引擎产物（Android/缺预编译时为 false，调用方走 parse 兜底）。 */
  static available(): boolean {
    try {
      return entry.reader3Available() as boolean;
    } catch (error) {
      return false;
    }
  }

  /**
   * 详情页 url → 书源规则引擎元数据。返回 null 表示不适用（引擎不可用或
   * 书源库无匹配），调用方应走原有解析兜底；非 null 时 ok 反映提取成败。
   */
  static async meta(bookUrl: string): Promise<Reader3Meta | null> {
    if (!Reader3Native.available()) {
      return null;
    }
    const sources: BookSource[] = await Reader3Native.ensureLoaded();
    const source: BookSource | null = Reader3Native.matchSource(sources, bookUrl);
    if (source === null) {
      // 未命中不算失败：语料没这个站属常态，静默走站点规则兜底。装载量变化时打一条便于排查导入问题
      if (!Reader3Native.matchLogged) {
        Reader3Native.matchLogged = true;
        hilog.info(0x0000, 'Reader3Native', 'no source for %{public}s (sources=%{public}d)',
          bookUrl, Reader3Native.sources.length);
      }
      return null;
    }
    if (!Reader3Native.ensureCallback()) {
      hilog.error(0x0000, 'Reader3Native', 'http bridge unavailable');
      return null;
    }
    let payload: string = '';
    try {
      payload = await entry.reader3BookInfo(JSON.stringify(source), bookUrl) as string;
    } catch (error) {
      return Reader3Native.fail(source.bookSourceName, `引擎调用异常：${String(error)}`);
    }
    const meta: Reader3Meta = Reader3Native.parsePayload(source.bookSourceName, payload);
    // 一行讲清 命中源/成败/原因，上板排查不必再抓引擎日志
    hilog.info(0x0000, 'Reader3Native', '%{public}s -> %{public}s: %{public}s',
      source.bookSourceName, meta.ok ? 'ok' : 'fail', meta.ok ? meta.name : meta.error);
    return meta;
  }

  // ---- 书源库 ----

  /** 装载缓存（首次读文件放微任务之后，不卡调用帧）。 */
  private static async ensureLoaded(): Promise<BookSource[]> {
    if (!Reader3Native.loaded) {
      Reader3Native.sources = await Promise.resolve().then((): BookSource[] => Reader3Native.readSourceFile());
      Reader3Native.loaded = true;
      hilog.info(0x0000, 'Reader3Native', 'loaded %{public}d book sources', Reader3Native.sources.length);
    }
    return Reader3Native.sources;
  }

  /** 已导入书源数（导入页状态显示用）。 */
  static async count(): Promise<number> {
    return (await Reader3Native.ensureLoaded()).length;
  }

  /** 校验 Legado 书源 JSON 文本：数组、逐条须有 bookSourceUrl；无效条目过滤，全无效抛错。 */
  private static parseSources(text: string): BookSource[] {
    const trimmed: string = text.trim();
    if (trimmed.length === 0) {
      throw new Error('内容为空');
    }
    let data: Object;
    try {
      data = JSON.parse(trimmed) as Object;
    } catch (error) {
      throw new Error('不是有效的 JSON');
    }
    if (!Array.isArray(data)) {
      throw new Error('书源须为 JSON 数组（Legado 导出格式）');
    }
    const valid: BookSource[] = [];
    for (const s of data as BookSource[]) {
      if (s !== null && s !== undefined && typeof s.bookSourceUrl === 'string' && s.bookSourceUrl.length > 0) {
        valid.push(s);
      }
    }
    if (valid.length === 0) {
      throw new Error('未解析到有效书源（每条须含 bookSourceUrl）');
    }
    return valid;
  }

  /**
   * 导入书源库：校验后**覆盖**沙箱 files 目录的 bookmeta_sources.json 并刷新缓存。
   * 全量 Legado 字段原样保留（引擎只读 ruleBookInfo，多余字段无害）。
   */
  static async importFromText(jsonText: string): Promise<number> {
    const valid: BookSource[] = Reader3Native.parseSources(jsonText);
    const text: string = JSON.stringify(valid);
    const path: string = `${Reader3Native.writeDir()}/${SOURCE_FILE}`;
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
    Reader3Native.sources = valid;
    Reader3Native.loaded = true;
    hilog.info(0x0000, 'Reader3Native', 'imported %{public}d sources -> %{public}s', valid.length, path);
    return valid.length;
  }

  /** URL 导入（书源或订阅直链）：rcp 抓文本再走 importFromText。 */
  static async importFromUrl(url: string): Promise<number> {
    const headers: rcp.RequestHeaders = { 'User-Agent': DEFAULT_UA };
    const request: rcp.Request = new rcp.Request(url, 'GET', headers);
    const session: rcp.Session = rcp.createSession();
    try {
      const response: rcp.Response = await session.fetch(request);
      if (response.statusCode !== 200) {
        throw new Error(`HTTP ${response.statusCode}`);
      }
      const bytes: ArrayBuffer = response.body ?? new ArrayBuffer(0);
      return Reader3Native.importFromText(Reader3Native.decode(bytes, '', response.headers));
    } finally {
      session.close();
    }
  }

  /** 写入目录：UIAbility filesDir 优先，异步续体拿不到 context 时用模块沙箱固定视图。 */
  private static writeDir(): string {
    try {
      return getContext().filesDir;
    } catch (error) {
      return '/data/storage/el2/base/haps/entry/files';
    }
  }

  /** 候选目录：UIAbility 语义的 filesDir 优先，再列模块/独立两个沙箱固定视图
   *  （异步续体里 getContext() 可能拿不到 context），最后 /data/local/tmp
   *  （仅 root/开发者调试机存在；app 域 SELinux 通常不可读，留着无害）。 */
  private static sourceDirs(): string[] {
    const dirs: string[] = [];
    try {
      dirs.push(getContext().filesDir);
    } catch (error) {
      hilog.warn(0x0000, 'Reader3Native', 'getContext unavailable: %{public}s', String(error));
    }
    dirs.push('/data/storage/el2/base/haps/entry/files');
    dirs.push('/data/storage/el2/base/files');
    dirs.push('/data/local/tmp');
    return dirs;
  }

  /** 读书源库；所有候选都没有即返回空数组（全部 url 走 parse 兜底）。 */
  private static readSourceFile(): BookSource[] {
    // 开发者通道：hdc file send -b <bundle> <本地> <沙箱视图路径> 即可更新（正式导入走应用内入口）
    const candidates: string[] = Reader3Native.sourceDirs().map((d: string): string => `${d}/${SOURCE_FILE}`);
    for (const path of candidates) {
      try {
        if (!fs.accessSync(path)) {
          continue;
        }
        const size: number = Number(fs.statSync(path).size);
        const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
        let text: string = '';
        try {
          const buf = new ArrayBuffer(size);
          fs.readSync(file.fd, buf);
          text = util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(new Uint8Array(buf));
        } finally {
          fs.closeSync(file);
        }
        // 首次一次性解析 ~800KB（约百毫秒，在网请求前的异步路径，非帧边界）
        return JSON.parse(text) as BookSource[];
      } catch (error) {
        hilog.warn(0x0000, 'Reader3Native', 'read %{public}s failed: %{public}s', path, String(error));
        continue;
      }
    }
    return [];
  }

  private static regexTest(pattern: string, value: string): boolean {
    if (pattern.length === 0) {
      return false;
    }
    try {
      return new RegExp(pattern).test(value);
    } catch (error) {
      // Java 特有语法（如 (?i)）编译失败时退化为字面子串匹配
      return pattern.indexOf('\\\\') < 0 && value.indexOf(pattern) >= 0;
    }
  }

  /** 宿主侧 url→书源匹配：bookUrlPattern 精确声明优先，再按 bookSourceUrl 部分匹配。 */
  static matchSource(sources: BookSource[], url: string): BookSource | null {
    for (const s of sources) {
      if (s.enabled === false) {
        continue;
      }
      const pattern: string = s.bookUrlPattern ?? '';
      if (pattern.length > 0 && Reader3Native.regexTest(pattern, url)) {
        return s;
      }
    }
    for (const s of sources) {
      if (s.enabled === false) {
        continue;
      }
      // legado bookSourceUrl 约定「源名@baseUrl」：取 @ 右侧站点地址部分匹配（无 @ 用整串）
      const at: number = s.bookSourceUrl.indexOf('@');
      const base: string = at >= 0 ? s.bookSourceUrl.substring(at + 1) : s.bookSourceUrl;
      if (base.length > 0 && Reader3Native.regexTest(base, url)) {
        return s;
      }
    }
    return null;
  }

  // ---- http 宿主桥 ----

  private static ensureCallback(): boolean {
    if (Reader3Native.callbackReady) {
      return true;
    }
    Reader3Native.callbackReady = entry.reader3SetHttpCallback(
      (reqJson: string): void => {
        // 引擎线程在 native 侧等 deliver；这里必须 fire-and-forget 且最终必达
        Reader3Native.handleHttp(reqJson);
      }) as boolean;
    return Reader3Native.callbackReady;
  }

  private static async handleHttp(reqJson: string): Promise<void> {
    let respJson: string;
    try {
      const req: HttpReq = JSON.parse(reqJson) as HttpReq;
      respJson = await Reader3Native.doFetch(req);
    } catch (error) {
      respJson = `{"status_code":0,"headers":{},"body_b64":"","transport_error":${JSON.stringify(String(error))}}`;
    }
    try {
      entry.reader3Deliver(respJson);
    } catch (error) {
      // 桥已断开（引擎线程早已超时自弃），无需再处理
    }
  }

  private static async doFetch(req: HttpReq): Promise<string> {
    const headers: rcp.RequestHeaders = {};
    const srcHeaders: Record<string, string> = req.headers ?? {};
    for (const key of Object.keys(srcHeaders)) {
      headers[key] = srcHeaders[key];
    }
    if (headers['User-Agent'] === undefined && headers['user-agent'] === undefined) {
      headers['User-Agent'] = DEFAULT_UA;
    }
    const method: string = req.method === 'POST' ? 'POST' : 'GET';
    const request: rcp.Request = method === 'POST'
      ? new rcp.Request(req.url, method, headers, req.body ?? '')
      : new rcp.Request(req.url, method, headers);
    const session: rcp.Session = rcp.createSession();
    try {
      const response: rcp.Response = await session.fetch(request);
      const bytes: ArrayBuffer = response.body ?? new ArrayBuffer(0);
      const text: string = Reader3Native.decode(bytes, req.charset ?? '', response.headers);
      const utf8: Uint8Array = new util.TextEncoder().encodeInto(text);
      const b64: string = new util.Base64Helper().encodeToStringSync(utf8);
      const finalUrl: string = response.effectiveUrl !== undefined ? String(response.effectiveUrl) : req.url;
      // headerJson 自身已是 JSON 对象文本，直接内插（再 stringify 会被双重包成字符串）
      return `{"status_code":${response.statusCode},"url":${JSON.stringify(finalUrl)},` +
        `"headers":${Reader3Native.headerJson(response.headers)},` +
        `"body_b64":${JSON.stringify(b64)}}`;
    } catch (error) {
      const message: string = error instanceof Error ? error.message : String(error);
      return `{"status_code":0,"headers":{},"body_b64":"","transport_error":${JSON.stringify(message)}}`;
    } finally {
      session.close();
    }
  }

  /** 响应头转协议要求的 {小写名:[值]}；rcp 的 header 值是字符串或字符串数组。
   *  ResponseHeaders 走 Record 视图访问（ArkTS 禁接口/联合的方括号索引）。 */
  private static headerJson(header: rcp.ResponseHeaders): string {
    const src: Record<string, string | string[] | undefined> =
      header as Record<string, string | string[] | undefined>;
    const out: Record<string, string[]> = {};
    for (const key of Object.keys(src)) {
      const value: string | string[] | undefined = src[key];
      if (value === undefined) {
        continue;
      }
      out[key.toLowerCase()] = Array.isArray(value) ? value : [String(value)];
    }
    return JSON.stringify(out);
  }

  /** 字节→文本：请求声明 charset > Content-Type charset > 页头嗅探（同 NovelMetaService 窗口 4KB）。 */
  private static decode(bytes: ArrayBuffer, reqCharset: string,
    header: rcp.ResponseHeaders): string {
    let cs: string = reqCharset.toLowerCase();
    if (cs.length === 0) {
      const src: Record<string, string | string[] | undefined> =
        header as Record<string, string | string[] | undefined>;
      // 数组值 String() 后逗号连接，charset= 仍命中首个分段，语义不变
      const ct: string = String(src['content-type'] ?? '');
      const m = ct.match(/charset=([\w-]+)/i);
      if (m !== null) {
        cs = m[1].toLowerCase();
      }
    }
    if (!Reader3Native.isCjkCharset(cs)) {
      const probe: string = util.TextDecoder.create('utf-8', { ignoreBOM: true })
        .decodeToString(new Uint8Array(bytes.slice(0, 4096)));
      const sniff = probe.match(/charset=["']?(gbk|gb2312|gb18030|big5)/i);
      if (sniff !== null) {
        cs = sniff[1].toLowerCase();
      }
    }
    if (Reader3Native.isCjkCharset(cs)) {
      try {
        return util.TextDecoder.create(cs, { ignoreBOM: true }).decodeToString(new Uint8Array(bytes));
      } catch (error) {
        // 编码名不被支持时退回 utf-8
      }
    }
    return util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(new Uint8Array(bytes));
  }

  private static isCjkCharset(cs: string): boolean {
    return cs === 'gbk' || cs === 'gb2312' || cs === 'gb18030' || cs === 'big5';
  }

  // ---- 结果解析 ----

  private static fail(rule: string, error: string): Reader3Meta {
    return { ok: false, error: error, rule: rule, name: '', author: '', kind: '',
      intro: '', coverUrl: '', tocUrl: '', lastChapter: '' };
  }

  /** 引擎外层协议 {"status":"ok","result":{"field":"ruleBookInfo","data":"<JSON串>"}}。 */
  private static parsePayload(rule: string, payload: string): Reader3Meta {
    let outer: Record<string, Object>;
    try {
      outer = JSON.parse(payload) as Record<string, Object>;
    } catch (error) {
      return Reader3Native.fail(rule, `引擎返回不是 JSON：${payload.substring(0, 120)}`);
    }
    if (String(outer['status'] ?? '') !== 'ok') {
      return Reader3Native.fail(rule, String(outer['message'] ?? '引擎错误'));
    }
    const result = outer['result'] as Record<string, string> | undefined;
    const dataText: string = result !== undefined ? result['data'] ?? '' : '';
    if (dataText.length === 0) {
      return Reader3Native.fail(rule, '书源规则未提到任何字段（站点改版或规则失效）');
    }
    let data: Record<string, string>;
    try {
      data = JSON.parse(dataText) as Record<string, string>;
    } catch (error) {
      return Reader3Native.fail(rule, `书源 data 字段不是 JSON：${dataText.substring(0, 120)}`);
    }
    const meta: Reader3Meta = { ok: false, error: '', rule: rule,
      name: data['name'] ?? '', author: data['author'] ?? '', kind: data['kind'] ?? '',
      intro: data['intro'] ?? '', coverUrl: data['coverUrl'] ?? '', tocUrl: data['tocUrl'] ?? '',
      lastChapter: data['lastChapter'] ?? '' };
    meta.ok = meta.name.length > 0 || meta.intro.length > 0 || meta.coverUrl.length > 0;
    if (!meta.ok) {
      meta.error = '书源规则未提取到书名/简介/封面';
    }
    return meta;
  }
}
