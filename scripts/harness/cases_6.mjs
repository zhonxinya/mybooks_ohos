// 用例组 6：Reader3 导入与 http 桥/get_novel_meta/search_meta/百科/search_web/ai_search（拆分自 check_ai_assistant.mjs，用例体原样）
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { test, state, settingsDefaults, enc, rtB64, deferred, tick, flush } from './base.mjs';
import { dir, read, ETS, ROOT } from './paths.mjs';
import { DOUBAN_PAGE, K17_PAGE, KUJIANG_PAGE, CIWEIMAO_PAGE, ZONGHENG_PAGE, QIDIAN_M_PAGE, WTZW_PAGE, WXSCS_PAGE, UJXSW_PAGE, MH_PAGE, FQ_INFO_B64, XXSY_PAGE, ZY_PAGE, QX_PAGE, YE_PAGE, SF_PAGE, DD_PAGE, YQ_DETAIL, R3_SOURCES } from './fixtures.mjs';

export function register(ctx) {
  const { load, deps, RealAiService, RealAiTools, parseToolBookLines, toolsState, mdParseBlocks, mdParseInline, AI_SKILLS, AiAssistantPage, AiBookPanelPage, AiRecommendPage, AiSettingsPage, AiPersonaPage, AiPersona, DEFAULT_SOUL, AiChatStore, personaState, MetaSearchService, NovelMetaService, resetSettings, settingsPage, chat, reappear } = ctx;
  test('Reader3 http 桥：抓取异常也必须 deliver transport_error（引擎线程不能挂等）', async () => {
    const { Reader3Native } = await load('RealReader3');
    deps.state.rcpError = new Error('connection reset');
    globalThis.__r3Delivered = null;
    globalThis.__r3Cb(JSON.stringify({ kind: 'http', method: 'GET', url: 'https://x.example/', headers: {} }));
    await flush();
    const d = JSON.parse(globalThis.__r3Delivered);
    assert.strictEqual(d.status_code, 0);
    assert.strictEqual(d.transport_error, 'connection reset');
    deps.state.rcpError = null;
  });

  test('Reader3 书源库不随包分发：两处候选路径都无文件时 meta 返回 null（全走兜底）', async () => {
    const { Reader3Native } = await load('RealReader3');
    Reader3Native.loaded = false; // 清类缓存（strip-types 擦除 private，测试可重置）
    deps.state.sourceJson = null;
    assert.strictEqual(await Reader3Native.meta('https://pat.example/book/123.html'), null,
      '未导入书源时不得误接管 url');
  });

  test('Reader3 书源导入通道：沙箱 files 读不到时从 /data/local/tmp 候选位装载', async () => {
    const { Reader3Native } = await load('RealReader3');
    Reader3Native.loaded = false;
    deps.state.sourceJson = R3_SOURCES;
    globalThis.__r3Ctx = { filesDir: '/no/such/dir' }; // 模拟 SELinux 挡住的沙箱位
    globalThis.__r3Payload = '{"status":"ok","result":{"data":"{\\"name\\":\\"tmp书\\"}"}}';
    const m = await Reader3Native.meta('https://pat.example/book/123.html');
    assert.strictEqual(m !== null && m.ok, true, 'tmp 候选位命中即接管');
    assert.strictEqual(m.name, 'tmp书');
  });

  test('Reader3 导入：Legado 数组校验（无效条目过滤）→ 写沙箱并即时刷新缓存', async () => {
    const { Reader3Native } = await load('RealReader3');
    Reader3Native.loaded = false;
    deps.state.sourceJson = null;
    globalThis.__r3Ctx = { filesDir: '/data/app' };
    globalThis.__r3Available = true;
    const text = JSON.stringify([
      { bookSourceUrl: '全本小说9@https://imp.example', bookSourceName: '导入源', ruleBookInfo: { name: 'h1@text' } },
      { bookSourceName: '无URL条目' },
    ]);
    const n = await Reader3Native.importFromText(text);
    assert.strictEqual(n, 1, '无 bookSourceUrl 的条目被过滤');
    assert.strictEqual(JSON.parse(deps.state.written[deps.state.written.length - 1]).length, 1,
      '落盘文本必须也是过滤后的');
    assert.strictEqual(await Reader3Native.count(), 1);
    // 导入后 meta() 立即用新缓存（无需重读文件）
    globalThis.__r3Payload = '{"status":"ok","result":{"data":"{\\"name\\":\\"导入书\\"}"}}';
    const m = await Reader3Native.meta('https://imp.example/book/1.html');
    assert.strictEqual(m.rule, '导入源');
    assert.strictEqual(m.name, '导入书');
  });

  test('Reader3 导入校验：坏 JSON 带开头片段 / 无 bookSourceUrl 对象 / 全无效 → 抛错不落盘；单书源对象可导入', async () => {
    const { Reader3Native } = await load('RealReader3');
    const before = deps.state.written.length;
    await assert.rejects(() => Reader3Native.importFromText('这不是JSON'), /不是有效的 JSON（开头：这不是JSON/);
    // URL 指到网页（书源站常见坑）：报错须能看出拿到的是 HTML
    await assert.rejects(() => Reader3Native.importFromText('<html><body>404</body></html>'), /开头：<html/);
    await assert.rejects(() => Reader3Native.importFromText('{"foo":1}'), /格式不支持/);
    await assert.rejects(() => Reader3Native.importFromText('[]'), /未解析到有效书源/);
    assert.strictEqual(deps.state.written.length, before, '失败导入不得写盘');
    // 单个书源对象（Legado 单本分享形态）= 1 条导入成功
    Reader3Native.loaded = false;
    assert.strictEqual(await Reader3Native.importFromText('{"bookSourceUrl":"https://one.example","bookSourceName":"单源"}'), 1);
  });

  test('Reader3 导入：URL 通道 rcp 抓取（非 200 报错）走同一校验落盘', async () => {
    const { Reader3Native } = await load('RealReader3');
    Reader3Native.loaded = false;
    const good = JSON.stringify([{ bookSourceUrl: 'https://u.example', bookSourceName: 'URL源' }]);
    deps.state.rcpResponse = { statusCode: 200, headers: { 'content-type': 'application/json' }, body: enc(good) };
    assert.strictEqual(await Reader3Native.importFromUrl('https://host/bookmeta_sources.json'), 1);
    deps.state.rcpResponse = { statusCode: 404, headers: {}, body: enc('') };
    await assert.rejects(() => Reader3Native.importFromUrl('https://host/none.json'), /HTTP 404/);
    deps.state.rcpResponse = null;
  });

  test('get_novel_meta：17K url 走工具输出简介/封面，读工具不过闸门，行模板带类别/状态/字数', async () => {
    deps.state.rcpResponse = { statusCode: 200, body: enc(K17_PAGE) };
    const s = await RealAiTools.execute('get_novel_meta', '{"url":"https://www.17k.com/book/1018082.html"}');
    assert.ok(s.includes('书名：武逆焚天') && s.includes('作者：疯橘子') &&
      s.includes('类别：东方玄幻') && s.includes('状态：连载中') &&
      s.includes('简介：') && s.includes('神奇的大陆'));
    assert.equal(RealAiTools.needsConfirm('get_novel_meta'), false);
    const empty = await RealAiTools.execute('get_novel_meta', '{}');
    assert.ok(empty.includes('url 必填'));
    deps.state.rcpResponse = { statusCode: 200, body: enc(KUJIANG_PAGE) };
    const kj = await RealAiTools.execute('get_novel_meta', '{"url":"https://m.kujiang.com/book/91737"}');
    assert.ok(kj.includes('规则：og:novel') && kj.includes('书名：灯下黑') && kj.includes('状态：已完本'));
    deps.state.rcpResponse = null;
    // search_sonovel 行模板增强：JSON 里已有的类别/状态/字数要上屏，并提示 get_novel_meta
    toolsState.sonovelEnvelope = { status: 200, error: '', body: { code: 200, message: '', data: [
      { sourceId: 4, sourceName: '全本小说网', url: 'http://www.quanben.io/n/gmzz/list.html',
        bookName: '诡秘之主', author: '爱潜水的乌贼', category: '玄幻', status: '已完结',
        wordCount: '956万字', latestChapter: '12月1日新番外' },
    ] } };
    const row = await RealAiTools.execute('search_sonovel', '{"query":"诡秘之主"}');
    assert.ok(row.includes('类别：玄幻') && row.includes('已完结') && row.includes('字数：956万字') &&
      row.includes('get_novel_meta'));
    toolsState.sonovelEnvelope = null;
  });

  test('search_meta：query/book_id 三通道聚合、subject_id 详情模式、读工具不过闸门', async () => {
    deps.state.rcpResponse = { statusCode: 200, body: enc(JSON.stringify([
      { title: '三体', author_name: '刘慈欣', year: '2008', type: 'b', id: '2567698',
        pic: 'https://img/x.jpg', url: 'https://book.douban.com/subject/2567698/' },
    ])) };
    toolsState.referBooks = [{ title: '三体全集', authors: ['刘慈欣'], publisher: '科幻世界',
      isbn: '9787536692930', source: '豆瓣', cover_url: 'https://img/cover.jpg' }];
    toolsState.sonovelEnvelope = { status: 200, error: '', body: { data: [
      { bookName: '三体', author: '刘慈欣', sourceName: '全本小说网', sourceId: 7,
        url: 'http://www.quanben.io/n/santi/', latestChapter: '第二百六十三章 尾声' },
    ] } };
    const out = await RealAiTools.execute('search_meta', JSON.stringify({ query: '三体', book_id: 1481 }));
    assert.ok(out.includes('subject_id=2567698'));
    assert.ok(out.includes('服务端多源候选'));
    assert.ok(out.includes('书源：全本小说网(id=7)'));
    assert.equal(RealAiTools.needsConfirm('search_meta'), false);
    // subject_id 详情模式（不触发 refer/sonovel）
    deps.state.rcpResponse = { statusCode: 200, body: enc(DOUBAN_PAGE) };
    const d2 = await RealAiTools.execute('search_meta', '{"subject_id":"2567698"}');
    assert.ok(d2.includes('豆瓣评分：8.9'));
    assert.ok(d2.includes('ISBN：9787536692930'));
    assert.ok(!d2.includes('服务端多源候选'));
    // 空参数引导
    const d3 = await RealAiTools.execute('search_meta', '{}');
    assert.ok(d3.includes('至少提供'));
    deps.state.rcpResponse = null;
  });

  test('百科工具：SERP 百科卡解析、维基 snippet 去标签、通道独立容错与聚合文案', async () => {
    const { EncyclopediaService } = await load('RealEncyclopedia');
    deps.state.rcpThrowQueue.length = 0;
    deps.state.rcpError = null;
    const serp = '<html><body><script>x</script>' +
      '{"tools":{"title":"刘慈欣","url":"https://baike.baidu.com/item/%E5%88%98%E6%85%88%E6%AC%A3/142084"},' +
      '"source":"百度百科","baikeid":"142084","abstract":"刘慈欣,男,汉族,1963年生,高级工程师、科幻作家。"}' +
      '</body></html>';
    const wikiJson = JSON.stringify({ query: { search: [
      { title: '刘慈欣', snippet: '<b>刘慈欣</b>，1963年生中国科幻作家' }] } });
    // 1 百度百科卡
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(serp) }];
    let bk = await EncyclopediaService.searchBaike('刘慈欣');
    assert.ok(bk.ok && bk.title === '刘慈欣' && bk.abstract.includes('汉族') && bk.url.includes('baike.baidu.com'), JSON.stringify(bk));
    // 2 无百科卡 → 明确文案
    deps.state.rcpResponses = [{ statusCode: 200, body: enc('<html>no card</html>') }];
    bk = await EncyclopediaService.searchBaike('不存在的词');
    assert.ok(!bk.ok && bk.error.includes('没有百科词条'), bk.error);
    // 3 item 级拦截（403）转 ok=false 不外抛
    deps.state.rcpResponses = [{ statusCode: 403, body: enc('verify') }];
    bk = await EncyclopediaService.searchBaike('x');
    assert.ok(!bk.ok && bk.error.includes('403'), bk.error);
    // 4 维基 snippet 去标签 + 词条链接
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(wikiJson) }];
    const wk = await EncyclopediaService.searchWikipedia('刘慈欣');
    assert.ok(wk.ok && !wk.abstract.includes('<b>') && wk.abstract.includes('科幻作家'), JSON.stringify(wk));
    assert.equal(wk.url, 'https://zh.wikipedia.org/wiki/%E5%88%98%E6%85%88%E6%AC%A3');
    // 5 工具聚合：双通道都有
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(serp) }, { statusCode: 200, body: enc(wikiJson) }];
    let out = await RealAiTools.execute('search_encyclopedia', '{"query":"刘慈欣"}');
    assert.ok(out.includes('【百度百科】刘慈欣') && out.includes('【维基百科】刘慈欣') && out.includes('链接：'), out);
    // 6 维基不可达（被墙 403）仍给百度结果并如实标注
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(serp) }, { statusCode: 403, body: enc('blocked') }];
    out = await RealAiTools.execute('search_encyclopedia', '{"query":"刘慈欣"}');
    assert.ok(out.includes('【百度百科】刘慈欣') && out.includes('【维基百科】未获取到'), out);
    // 7 双通道全挂 → 汇总失败文案（不抛错，不触发无意义重试）
    deps.state.rcpResponses = [{ statusCode: 503, body: enc('down') }, { statusCode: 503, body: enc('down') }];
    out = await RealAiTools.execute('search_encyclopedia', '{"query":"x"}');
    assert.ok(out.includes('百科检索失败') && out.includes('503'), out);
    // 8 无 tools 卡时 fallback：纯词/整句 SERP 的 AI 问答卡引用项形态（板上真实踩坑）
    const serpCite = '<html><script>var x=1;</script>' +
      '{"url_no":2,"url":"https://baike.baidu.com/item/%E5%88%98%E6%85%88%E6%AC%A3/142084",' +
      '"text":"刘慈欣-高级工程师、科幻作家","source":"百度百科","publish_time":0,"icon":"https://i.png",' +
      '"abstract":"刘慈欣,男,汉族,1963年6月23日出生于北京,祖籍河南,高级工程师、科幻作家。"}' +
      '</html>';
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(serpCite) }];
    bk = await EncyclopediaService.searchBaike('刘慈欣是谁');
    assert.ok(bk.ok && bk.title === '刘慈欣-高级工程师、科幻作家' &&
      bk.abstract.includes('1963年') && bk.url.includes('baike.baidu.com'), JSON.stringify(bk));
    // 9 cite 形态但 abstract 距 source 超窗口 → 不误取无关摘要
    const serpFar = '<html>{"url":"https://baike.baidu.com/item/a","text":"词条","source":"百度百科"}' +
      'x'.repeat(1000) + '{"abstract":"太远的摘要不应该被取到内容内容内容。"}</html>';
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(serpFar) }];
    bk = await EncyclopediaService.searchBaike('y');
    assert.ok(!bk.ok && bk.error.includes('没有百科词条'), bk.error);
    deps.state.rcpError = null;
  });

  test('search_web：三引擎聚合（百度/Bing/360 解析、跨引擎去重、单通道失败降级）与容错', async () => {
    const { EncyclopediaService } = await load('RealEncyclopedia');
    deps.state.rcpThrowQueue.length = 0;
    deps.state.rcpError = null;
    deps.state.store.clear();
    // #1616 起引擎可配置：本用例只启用旧三通道，断言其解析/去重/降级行为不变
    for (const id of ['sogou', 'wikipedia']) { EncyclopediaService.setEngineEnabled(id, false); }
    // 百度结构取自 2026-11-21 真实 SERP 样本（c-container/mu/s-text/summary-text_<hash>）；
    // Bing=b_algo+h2 直链+b_lineclamp；360=res-list+h3 直链+res-list-summary
    const baiduHtml = '<html><body>' +
      '<div class="result c-container" mu="http://28616.recommend_list.baidu.com"' +
      '><h3><a><!--s-text-->榜单推广位<!--/s-text--></a></h3></div>' +
      '<div class="result c-container xpath-log new-pmd" mu="https://www.qidian.com/book/123">' +
      '<h3 class="cosc-title"><a><!--s-text--><em>三体</em>全集在线阅读-起点中文网<!--/s-text--></a></h3>' +
      '<span class="    summary-text_15QGa">《三体》表达了对宇宙的<em>敬畏</em>与想象。</span></div>' +
      '<div class="result c-container" mu="https://fanqienovel.com/page/698">' +
      '<h3><a><!--s-text-->三体全集免费阅读_番茄小说官网<!--/s-text--></a></h3></div>' +
      '<div class="result c-container" mu="https://baike.baidu.com/item/三体">' +
      '<h3><a>三体（长篇小说）</a></h3>' +
      '<span class="summary-text_9AbCd">《三体》是刘慈欣创作的长篇科幻小说。</span></div>' +
      '</body></html>';
    const bingHtml = '<ol id="b_results">' +
      '<li class="b_algo"><h2><a href="https://weread.qq.com/web/reader/ce03">三体全集免费阅读_番茄小说官网</a></h2>' +
      '<div class="b_caption"><p class="b_lineclamp2">2021年10月16日&#183;《三体》系列长篇。</p></div></li>' +
      '<li class="b_algo"><h2><a href="https://baike.baidu.com/item/%E4%B8%89%E4%BD%93/5739303">三体（刘慈欣创作的系列小说）_百度百科</a></h2>' +
      '<div class="b_caption"><p class="b_lineclamp2">雨果奖获奖作品。<a href="#">阅读更多</a>阅读更多</p></div></li>' +
      '</ol>';
    const so360Html = '<ul>' +
      '<li class="res-list"><h3><a href="https://www.so.com/link?m=abc">三体txt下载-青果书库</a></h3>' +
      '<p class="res-desc"><span class="res-list-summary" data-result-summary>《三体》<em>系列</em>作品介绍。</span></p></li>' +
      '<li class="res-list"><h3><a href="https://baike.so.com/doc/5330779">三体_360百科</a></h3></li>' +
      '</ul>';
    // 并发发起顺序 baidu→bing→360，rcpResponses 按序消费
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc(baiduHtml) },
      { statusCode: 200, body: enc(bingHtml) },
      { statusCode: 200, body: enc(so360Html) },
    ];
    const r = await EncyclopediaService.searchWeb('三体 小说');
    assert.ok(r.ok, r.error);
    // #1616 去重键改为「标题+域名」：同标题不同站视为不同结果（旧逻辑按标题会误合并）
    assert.equal(r.items.length, 7, '百度 3 + Bing 2 + 360 2，无同站同名冲突');
    const byTitle = (t) => r.items.find((x) => x.title === t);
    assert.ok(byTitle('三体全集在线阅读-起点中文网'), '百度起点条目在');
    const qidian = byTitle('三体全集在线阅读-起点中文网');
    assert.equal(qidian.url, 'https://www.qidian.com/book/123');
    assert.ok(qidian.summary.includes('敬畏') && !qidian.summary.includes('<em>'), qidian.summary);
    assert.ok(byTitle('三体全集免费阅读_番茄小说官网'), '纯标题卡片保留');
    assert.equal(byTitle('三体（长篇小说）') !== undefined, true, '无 s-text 时 h3 兜底');
    // 重排序：来源权重高的（百度/维基=2-3）排在 360（1）之前；有摘要的优先
    const first360 = r.items.findIndex((x) => x.source === '360');
    const firstBaidu = r.items.findIndex((x) => x.source === '百度');
    assert.ok(firstBaidu < first360, '百度权重高于 360，排在前面');
    const bing = byTitle('三体（刘慈欣创作的系列小说）_百度百科');
    assert.ok(bing !== undefined && bing.summary.includes('雨果奖') &&
      !bing.summary.endsWith('阅读更多'), 'Bing 摘要清洗');
    // 单通道非 2xx：跳过该引擎，其余照常
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc(baiduHtml) },
      { statusCode: 567, body: enc('rate limit') },
      { statusCode: 200, body: enc(so360Html) },
    ];
    const partial = await EncyclopediaService.searchWeb('三体');
    assert.ok(partial.ok && partial.items.every((x) => x.source !== 'Bing'), 'Bing 失败不影响整体');
    // 三通道全空 → 统一失败文案，不抛错
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc('<html>waf</html>') },
      { statusCode: 200, body: enc('<html>waf</html>') },
      { statusCode: 200, body: enc('<html>waf</html>') },
    ];
    const empty = await EncyclopediaService.searchWeb('不存在的东西');
    assert.ok(!empty.ok && empty.error.includes('均无结果'), empty.error);
    // 工具层：编号文案带来源标签，摘要缺省不占行
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc(baiduHtml) },
      { statusCode: 200, body: enc(bingHtml) },
      { statusCode: 200, body: enc(so360Html) },
    ];
    const out = await RealAiTools.execute('search_web', '{"query":"三体"}');
    // #1632 相关性排序后：标题+摘要双命中者并列，百度首位保持；断言内容存在与格式（编号+来源标签+链接行）
    assert.ok(out.includes('1. [百度] 三体全集在线阅读-起点中文网'), out);
    assert.ok(out.includes('链接：https://www.qidian.com/book/123'), out);
    assert.ok(out.includes('[百度] 三体全集免费阅读_番茄小说官网'), out);
    assert.ok(out.includes('[Bing] 三体（刘慈欣创作的系列小说）_百度百科'), out);
    // #1633：工具文案尾部附逐引擎通道统计
    assert.ok(out.includes('[通道统计] 百度 3 | Bing 2 | 360 搜索 2'), out);
    // 无摘要条目：链接行后紧跟空行（不占摘要行）
    assert.ok(/链接：https:\/\/fanqienovel\.com\/page\/698\n\n/.test(out), out);
    // 空 query 直接回文案
    const none = await RealAiTools.execute('search_web', '{"query":"  "}');
    assert.ok(none.includes('query 为空'), none);
    deps.state.rcpError = null;
  });

  test('搜索引擎可配置（#1616）：引擎启停/至少留一/条数夹取/维基 API 通道/重排序', async () => {
    const { EncyclopediaService, SEARCH_ENGINES } = await load('RealEncyclopedia');
    deps.state.store.clear();
    deps.state.rcpResponses = [];
    // 默认：全部启用、条数 8
    assert.equal(EncyclopediaService.enabledEngines().length, SEARCH_ENGINES.length, '默认全开');
    assert.equal(EncyclopediaService.searchLimit(), 8, '默认 8 条');
    // 停用后清单收敛；至少保留一个（全关被拒）
    assert.equal(EncyclopediaService.setEngineEnabled('sogou', false), true);
    assert.equal(EncyclopediaService.isEngineEnabled('sogou'), false);
    assert.equal(EncyclopediaService.enabledEngines().indexOf('sogou') < 0, true);
    for (const e of SEARCH_ENGINES) {
      if (e.id !== 'baidu') { EncyclopediaService.setEngineEnabled(e.id, false); }
    }
    assert.equal(EncyclopediaService.setEngineEnabled('baidu', false), false, '最后一个不能停用');
    assert.deepEqual(EncyclopediaService.enabledEngines(), ['baidu'], '只剩百度');
    // 条数夹取 3–20
    EncyclopediaService.setSearchLimit(1);
    assert.equal(EncyclopediaService.searchLimit(), 3, '下限 3');
    EncyclopediaService.setSearchLimit(99);
    assert.equal(EncyclopediaService.searchLimit(), 20, '上限 20');
    EncyclopediaService.setSearchLimit(5);
    assert.equal(EncyclopediaService.searchLimit(), 5);
    // 全关（人为清空配置）→ 明确错误文案，不发请求
    deps.state.store.set('p:ai_search_engines', '[]');
    deps.state.rcpResponses = [];
    const none = await EncyclopediaService.searchWeb('三体');
    assert.ok(!none.ok && none.error.includes('没有启用任何搜索引擎'), none.error);
    // 维基百科走官方 API：JSON 直出解析（source=维基百科，url 拼条目页）
    deps.state.store.clear();
    for (const e of SEARCH_ENGINES) {
      if (e.id !== 'wikipedia') { EncyclopediaService.setEngineEnabled(e.id, false); }
    }
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(JSON.stringify({
      query: { search: [
        { title: '三体', snippet: '<span class="searchmatch">三体</span>是刘慈欣的科幻小说' },
        { title: '刘慈欣', snippet: '中国科幻作家' },
      ] } })) }];
    const wk = await EncyclopediaService.searchWeb('三体');
    assert.ok(wk.ok, wk.error);
    assert.equal(wk.items.length, 2);
    assert.equal(wk.items[0].source, '维基百科');
    assert.equal(wk.items[0].title, '三体');
    assert.equal(wk.items[0].url, 'https://zh.wikipedia.org/wiki/' + encodeURIComponent('三体'));
    assert.ok(wk.items[0].summary.includes('刘慈欣') && !wk.items[0].summary.includes('<span'), wk.items[0].summary);
    // 重排序：高权重来源在前，有摘要的同类在前
    deps.state.store.clear();
    for (const e of SEARCH_ENGINES) {
      if (e.id !== 'baidu' && e.id !== 'so360') { EncyclopediaService.setEngineEnabled(e.id, false); }
    }
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc('<div class="result c-container" mu="https://a.example/1">' +
        '<h3><a><!--s-text-->无摘要条目<!--/s-text--></a></h3></div>') },
      { statusCode: 200, body: enc('<li class="res-list"><h3><a href="https://b.example/2">' +
        '360 有摘要</a></h3><span class="res-list-summary">这是一段足够长的摘要内容，用于验证相关度加分。</span></li>') },
    ];
    const ranked = await EncyclopediaService.searchWeb('x');
    assert.ok(ranked.ok, ranked.error);
    assert.equal(ranked.items[0].source, '百度', '百度权重高于 360，即便其条目无摘要');
    // 清理
    deps.state.store.clear();
    deps.state.rcpResponses = [];
  });

  test('fetch_url：正文提取纯函数、抓取请求形态、非法 URL/非 2xx/截断与工具文案', async () => {
    const { WebFetchService } = await load('RealWebFetch');
    deps.state.rcpError = null;
    deps.state.rcpResponses = [];
    // 纯函数：剥 script/style/注释/head，块级边界换行，实体解码，压空白
    const html = '<html><head><title>三体 &#183; 刘慈欣</title><style>.x{}</style></head>' +
      '<body><script>var a=1;</script><!--注释-->' +
      '<h1>第一章</h1><p>这是&nbsp;正文&lt;第一段&gt;。</p>' +
      '<div>第二段&#39;引号&#39;。</div><footer>页脚噪声</footer></body></html>';
    const body = WebFetchService.extractBody(html);
    assert.ok(body.includes('第一章') && body.includes('这是 正文<第一段>'), body);
    assert.ok(body.includes('第二段\'引号\''), body);
    assert.ok(!body.includes('var a') && !body.includes('.x{}') && !body.includes('注释'), '脚本/样式/注释须剥离');
    assert.ok(!body.includes('\n\n\n'), '连续空行须压缩');
    // URL 校验：仅 http(s)，挡 javascript:/file:/短串
    assert.ok(WebFetchService.validUrl('https://www.baidu.com/'));
    assert.ok(!WebFetchService.validUrl('javascript:alert(1)'));
    assert.ok(!WebFetchService.validUrl('ftp://x.example/a'));
    assert.ok(!WebFetchService.validUrl(''));
    // 抓取成功：GET 形态 + 标题 + 正文文案
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(html) }];
    const ok = await WebFetchService.fetch('https://example.com/book');
    assert.ok(ok.ok && ok.title === '三体 · 刘慈欣', JSON.stringify(ok));
    assert.equal(deps.state.lastRequest.method, 'GET');
    assert.equal(deps.state.lastRequest.url, 'https://example.com/book');
    // 工具层文案：《标题》+ 来源 + 正文
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(html) }];
    const out = await RealAiTools.execute('fetch_url', '{"url":"https://example.com/book"}');
    assert.ok(out.includes('《三体 · 刘慈欣》') && out.includes('来源：https://example.com/book') &&
      out.includes('正文'), out);
    // 非法 URL：不发请求，直接回文案
    const before = deps.state.requests.length;
    const bad = await RealAiTools.execute('fetch_url', '{"url":"javascript:alert(1)"}');
    assert.ok(bad.includes('URL 无效'), bad);
    assert.equal(deps.state.requests.length, before, '非法 URL 不应发起网络请求');
    // 非 2xx：失败文案不抛错
    deps.state.rcpResponses = [{ statusCode: 404, body: enc('not found') }];
    assert.ok((await RealAiTools.execute('fetch_url', '{"url":"https://example.com/x"}')).includes('404'));
    // 纯脚本页（剥完无正文）：明确提示
    deps.state.rcpResponses = [{ statusCode: 200, body: enc('<html><head><title>SPA</title></head><body><script>render()</script><div id="app"></div></body></html>') }];
    assert.ok((await RealAiTools.execute('fetch_url', '{"url":"https://example.com/spa"}')).includes('未能提取'));
    // 超长截断：>6000 字符正文带截断标记
    const long = '<html><head><title>长文</title></head><body><p>' + '字'.repeat(7000) + '</p></body></html>';
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(long) }];
    const trunc = await WebFetchService.fetch('https://example.com/long');
    assert.ok(trunc.ok && trunc.text.includes('正文过长已截断') && trunc.text.length < 6100, `${trunc.text.length}`);
    // 空 url 参数
    assert.ok((await RealAiTools.execute('fetch_url', '{"url":"  "}')).includes('url 为空'));
    deps.state.rcpResponses = [];
    deps.state.rcpError = null;
  });

  test('fetch_url 类浏览器降级：needsRender 判定 + hint 标记 + 渲染器就绪时走渲染文案', async () => {
    const { WebFetchService } = await load('RealWebFetch');
    const Brs = await load('BrowserRenderStub');
    deps.state.rcpError = null;
    // 纯函数判定
    assert.equal(WebFetchService.needsRender(403, ''), true, '403 反爬值得渲染');
    assert.equal(WebFetchService.needsRender(404, ''), false, '404 渲染也没用');
    const spa = '<html><head><title>SPA</title></head><body><script>render()</script><div id="app"></div></body></html>';
    assert.equal(WebFetchService.needsRender(200, spa), true, 'JS 空壳须渲染');
    assert.equal(WebFetchService.needsRender(200, '<html><body><p>' + '字'.repeat(300) + '</p></body></html>'),
      false, '正文充足不渲染');
    assert.equal(WebFetchService.needsRender(200, '<html><body><p>短但没脚本</p></body></html>'), false,
      '短静态页不值得重开销');
    // hint 标记：SPA 页与 403 均带 render 提示
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(spa) }];
    const r1 = await WebFetchService.fetch('https://example.com/spa');
    assert.equal(r1.hint, 'render', JSON.stringify(r1));
    deps.state.rcpResponses = [{ statusCode: 403, body: enc('blocked') }];
    const r2 = await WebFetchService.fetch('https://example.com/x');
    assert.equal(r2.hint, 'render');
    // 正常页 hint 为空
    deps.state.rcpResponses = [{ statusCode: 200, body: enc('<html><body><p>' + '字'.repeat(300) + '</p></body></html>') }];
    assert.equal((await WebFetchService.fetch('https://example.com/ok')).hint, '');
    // 渲染器未就绪（默认）：维持原失败文案
    Brs.BrowserRenderService.ready = false;
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(spa) }];
    const out1 = await RealAiTools.execute('fetch_url', '{"url":"https://example.com/spa"}');
    assert.ok(out1.includes('未能提取') && !out1.includes('浏览器渲染'), out1);
    // 就绪但渲染空（页面失效）：明确说明已尝试
    Brs.BrowserRenderService.ready = true;
    Brs.BrowserRenderService.text = '';
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(spa) }];
    const out2 = await RealAiTools.execute('fetch_url', '{"url":"https://example.com/spa"}');
    assert.ok(out2.includes('已尝试浏览器渲染'), out2);
    // 就绪且有正文：走渲染提取文案，并确认 loadUrl 收到原 url
    Brs.BrowserRenderService.text = '渲染出来的正文内容，足够长以通过判定阈值。'.repeat(10);
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(spa) }];
    const out3 = await RealAiTools.execute('fetch_url', '{"url":"https://example.com/spa"}');
    assert.ok(out3.includes('浏览器渲染提取') && out3.includes('渲染出来的正文'), out3);
    assert.ok(Brs.BrowserRenderService.calls.includes('https://example.com/spa'));
    // 收尾复位，避免污染其他用例
    Brs.BrowserRenderService.ready = false;
    Brs.BrowserRenderService.text = '';
    Brs.BrowserRenderService.calls = [];
    deps.state.rcpResponses = [];
    deps.state.rcpError = null;
  });

  test('ai_search：通义 enable_search 请求形态、引用文案与非通义服务商回落', async () => {
    // RealAiService 存储桩直配通义服务商（p:/s: 前缀=TalebookService pref/secure）
    deps.state.store.set('p:ai_provider', 'qianwen');
    deps.state.store.set('s:ai_base_url', 'https://dashscope.aliyuncs.com/compatible-mode/v1');
    deps.state.store.set('p:ai_model', 'qwen-plus');
    deps.state.store.set('s:ai_api_key_qianwen', 'sk-test');
    try {
      const body = {
        choices: [{ message: { content: '2026 年雨果奖最佳小说为《地球大炮》。' } }],
        search_info: { search_results: [
          { title: '雨果奖官网', url: 'https://www.thehugoawards.org/' },
          { title: '新闻报道', url: 'https://example.com/news' },
          { title: '', url: 'https://no-title.com' },
        ] },
      };
      deps.state.rcpResponses = [{ statusCode: 200, body: enc(JSON.stringify(body)) }];
      const out = await RealAiTools.execute('ai_search', '{"query":"2026年雨果奖最佳小说"}');
      const req = deps.state.lastRequest;
      assert.equal(req.method, 'POST');
      assert.ok(req.url === 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions', req.url);
      const sent = JSON.parse(req.content);
      assert.equal(sent.enable_search, true, '须带 enable_search');
      assert.equal(sent.search_options.forced_search, true, '强制联网防凭记忆作答');
      assert.equal(sent.stream, false);
      assert.equal(sent.model, 'qwen-plus');
      assert.ok(out.includes('2026 年雨果奖最佳小说为《地球大炮》。') && out.includes('引用来源：')
        && out.includes('1. 雨果奖官网 https://www.thehugoawards.org/') && !out.includes('no-title'), out);
      // 无引用：纯答案
      deps.state.rcpResponses = [{ statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '只有答案' } }] })) }];
      assert.equal(await RealAiTools.execute('ai_search', '{"query":"x"}'), '只有答案');
      // 空答案 → 失败文案不抛错
      deps.state.rcpResponses = [{ statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '   ' } }] })) }];
      assert.ok((await RealAiTools.execute('ai_search', '{"query":"x"}')).includes('空答案'));
      // 非 2xx → 失败文案
      deps.state.rcpResponses = [{ statusCode: 401, body: enc('bad key') }];
      assert.ok((await RealAiTools.execute('ai_search', '{"query":"x"}')).includes('失败'));
      // 非通义服务商：提示改用 search_web，且不发请求
      deps.state.store.set('s:ai_base_url', 'https://api.deepseek.com/v1');
      const before = deps.state.requests.length;
      const unsupported = await RealAiTools.execute('ai_search', '{"query":"x"}');
      assert.ok(unsupported.includes('改用 search_web'), unsupported);
      assert.equal(deps.state.requests.length, before, '不支持时零请求');
      // 空 query
      assert.ok((await RealAiTools.execute('ai_search', '{"query":" "}')).includes('query 为空'));
    } finally {
      for (const k of ['p:ai_provider', 's:ai_base_url', 'p:ai_model', 's:ai_api_key_qianwen']) {
        deps.state.store.delete(k);
      }
    }
  });

  test('对话页模型快切：徽标跟配置、菜单勾选+刷新、部分保存只动 model、失败退化重试', async () => {
    resetSettings(); // 前序语音用例把 config 改到 glm-4v，这里从默认配置起算
    const page = chat();
    state.settings.models = ['glm-4', 'glm-4-plus', 'deepseek-chat'];
    state.settings.fetchError = '';
    page.modelChoices = [];
    page.onPageShow();
    await flush();
    assert.equal(page.currentModel, 'deepseek-chat', '徽标跟随全局配置');
    assert.equal(page.modelChipLabel(), 'deepseek-chat');
    assert.deepEqual(page.modelChoices, ['glm-4', 'glm-4-plus', 'deepseek-chat']);
    const items = page.modelMenuItems();
    assert.equal(items.length, 4, '3 模型 + 刷新项');
    assert.ok(items[2].symbolIcon !== undefined, '当前模型带勾');
    assert.ok(items[0].symbolIcon === undefined);
    // 切换：部分保存原样回填 model 之外字段，apiKey 传空不覆盖已存 Key
    page.pickModel('glm-4-plus');
    const saved = state.settings.saved;
    assert.equal(saved.model, 'glm-4-plus');
    assert.equal(saved.apiKey, '', '部分保存不带 Key');
    assert.equal(saved.baseUrl, 'https://api.deepseek.com/v1');
    assert.equal(saved.contextLength, 8, '上下文档位等其他字段透传');
    assert.equal(page.currentModel, 'glm-4-plus');
    assert.equal(state.settings.config.model, 'glm-4-plus', '下一条消息即生效（配置已更新）');
    // 再点当前项不重复保存
    const savedBefore = state.settings.saved;
    page.pickModel('glm-4-plus');
    assert.equal(state.settings.saved, savedBefore, '同模型点击为 no-op');
    // 长名截断：切换后徽标 14 字 + 省略号
    page.pickModel('very-long-model-name-for-truncation-xyz');
    assert.equal(page.modelChipLabel(), 'very-long-mode…', '14 字 + 省略号');
    // 拉取失败：列表空、菜单退化为单个获取项，徽标仍显当前模型
    state.settings.fetchError = '服务商不支持模型列表';
    page.modelChoices = [];
    page.onPageShow();
    await flush();
    assert.deepEqual(page.modelChoices, []);
    const retry = page.modelMenuItems();
    assert.equal(retry.length, 1);
    assert.ok(retry[0].value.includes('获取模型列表'), retry[0].value);
    assert.equal(page.modelChipLabel(), 'very-long-mode…');
    state.settings.fetchError = '';
  });

  test('#1626 写确认批量授权：本轮全部允许后不再弹窗；回路结束复位', async () => {
    const page = chat();
    const store = AiChatStore.instance();
    const dialogs = [];
    let confirmIndex = 2;
    page.getUIContext = () => ({
      getPromptAction: () => ({
        showDialog: (opt) => { dialogs.push(opt); return Promise.resolve({ index: confirmIndex }); },
      }),
    });
    // 单笔允许（index 2）：放行但不启用批量
    assert.equal(await page.requestConfirm('加入书架', '{}'), true);
    assert.equal(dialogs[0].buttons.length, 3, '三键弹窗：拒绝/本轮全部允许/允许');
    assert.equal(page.allowAllRound, false);
    // 本轮全部允许（index 1）：放行并启用批量
    confirmIndex = 1;
    assert.equal(await page.requestConfirm('加入书架', '{}'), true);
    assert.equal(page.allowAllRound, true);
    const n = dialogs.length;
    assert.equal(await page.requestConfirm('创建书单', '{}'), true);
    assert.equal(dialogs.length, n, '已批量授权不再弹窗');
    // 回路结束（thinking=false）经 syncFromStore 复位后恢复弹窗
    store.thinking = false;
    page.syncFromStore();
    assert.equal(page.allowAllRound, false);
    confirmIndex = 0;
    assert.equal(await page.requestConfirm('加入书架', '{}'), false, '拒绝仍弹窗且为 false');
    assert.equal(dialogs.length, n + 1);
  });

  test('搜索引擎优化（#1632-#1635）：相关性排序/通道超时诊断/候选联动/URL 归一去重', async () => {
    const { EncyclopediaService } = await load('RealEncyclopedia');
    deps.state.rcpThrowQueue.length = 0;
    deps.state.rcpError = null;
    deps.state.store.clear();
    deps.state.rcpResponses = [];
    for (const id of ['sogou', 'wikipedia']) { EncyclopediaService.setEngineEnabled(id, false); }
    // #1632 相关性：满命中低权重源 排在 零命中高权重源前（旧公式权重×10 会霸排）
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc('<div class="result c-container" mu="https://a.example/1">' +
        '<h3><a><!--s-text-->完全不相关的百科内容<!--/s-text--></a></h3>' +
        '<span class="summary-text_1">这是一段与查询毫无关联的长摘要文本，用来验证来源权重不再压过相关性信号。</span></div>') },
      { statusCode: 200, body: enc('<ol></ol>') },
      { statusCode: 200, body: enc('<li class="res-list"><h3><a href="https://b.example/2">' +
        '球状闪电_刘慈欣著 完整介绍</a></h3><span class="res-list-summary">刘慈欣创作的科幻小说《球状闪电》讲述球状闪电之谜与主人公的执着追寻，篇幅足够长以验证完整度加分。</span></li>') },
    ];
    const rel = await EncyclopediaService.searchWeb('球状闪电');
    assert.ok(rel.ok, rel.error);
    assert.equal(rel.items[0].source, '360', '查询词满命中胜过来源权重差');
    // #1633 超时：Bing 通道永挂 → 8s 硬超时收敛（用例调小句柄），其余照常，诊断标注超时
    const savedTimeout = EncyclopediaService.engineTimeoutMs;
    try {
      EncyclopediaService.engineTimeoutMs = 30;
      deps.state.rcpResponses = [
        { statusCode: 200, body: enc('<div class="result c-container" mu="https://a.example/1">' +
          '<h3><a><!--s-text-->三体阅读<!--/s-text--></a></h3></div>') },
        { hang: true },
        { statusCode: 200, body: enc('<li class="res-list"><h3><a href="https://b.example/2">三体百科</a></h3></li>') },
      ];
      const to = await EncyclopediaService.searchWeb('三体');
      assert.ok(to.ok, to.error);
      assert.ok(to.stats.includes('Bing 0(超时)'), to.stats);
      assert.ok(to.stats.includes('百度 1') && to.stats.includes('360 搜索 1'), to.stats);
    } finally {
      EncyclopediaService.engineTimeoutMs = savedTimeout;
    }
    // #1634 候选联动：limit 放大后单引擎候选不再被钉死 8 条
    let manyHtml = '<html><body>';
    for (let i = 0; i < 12; i++) {
      manyHtml += `<div class="result c-container" mu="https://c.example/${i}">` +
        `<h3><a><!--s-text-->三体结果编号${i}<!--/s-text--></a></h3></div>`;
    }
    manyHtml += '</body></html>';
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc(manyHtml) }, { statusCode: 200, body: enc('<ol></ol>') },
      { statusCode: 200, body: enc('<ul></ul>') },
    ];
    const many = await EncyclopediaService.searchWeb('三体', 12);
    assert.equal(many.items.length, 12, 'perEngine=max(8,limit+4) 生效，12 条候选全进结果');
    // #1635 URL 归一去重：跟踪参数/大小写/尾斜杠变体视为同一文章（标题不同也合并）
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc('<div class="result c-container" mu="https://WWW.x.com/a/?utm_source=1">' +
        '<h3><a><!--s-text-->转载标题甲<!--/s-text--></a></h3></div>' +
        '<div class="result c-container" mu="https://www.x.com/a?spm=2">' +
        '<h3><a><!--s-text-->原文链接乙<!--/s-text--></a></h3></div>') },
      { statusCode: 200, body: enc('<ol></ol>') },
      { statusCode: 200, body: enc('<ul></ul>') },
    ];
    const dd = await EncyclopediaService.searchWeb('标题');
    assert.equal(dd.items.length, 1, 'utm/spm 变体经归一化后同 URL 合并');
    deps.state.store.clear();
    deps.state.rcpResponses = [];
  });

  test('DeepSeek 官方搜索通道（#1636）：无 Key 不发请求、POST 结构、summary 优先解析', async () => {
    const { EncyclopediaService, SEARCH_ENGINES } = await load('RealEncyclopedia');
    deps.state.rcpThrowQueue.length = 0;
    deps.state.rcpError = null;
    deps.state.store.clear();
    deps.state.rcpResponses = [];
    deps.state.requests.length = 0;
    for (const e of SEARCH_ENGINES) {
      if (e.id !== 'deepseek') { EncyclopediaService.setEngineEnabled(e.id, false); }
    }
    // ① 无 Key：零请求（不烧配额不占超时），诊断行明标「无Key」
    const noKey = await EncyclopediaService.searchWeb('三体');
    assert.equal(deps.state.requests.length, 0, '无 Key 不发 HTTP');
    assert.ok(noKey.stats.includes('DeepSeek 0(无Key)'), noKey.stats);
    assert.ok(!noKey.ok && noKey.error.includes('均无结果'), noKey.error);
    // ② 配 Key：POST /tools/search 结构 + Bearer 头 + 请求体字段
    deps.state.store.set('s:ai_api_key_deepseek', 'sk-test');
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(JSON.stringify({ results: [
      { title: '三体', url: 'https://ds.example/1', summary: '刘慈欣长篇科幻小说，雨果奖作品。', snippet: '短摘要', authority: 4 },
      { title: '球状闪电', url: 'https://ds.example/2', snippet: '同作者早期长篇', rerank_score: 2.1 },
      { title: '', url: 'https://ds.example/skip', snippet: '无标题应被跳过' },
    ] })) }];
    const r = await EncyclopediaService.searchWeb('三体 刘慈欣', 5);
    assert.ok(r.ok, r.error);
    const req = deps.state.requests[deps.state.requests.length - 1];
    assert.equal(req.method, 'POST');
    assert.equal(req.url, 'https://api.deepseek.com/v1/tools/search');
    assert.equal(req.headers['Authorization'], 'Bearer sk-test');
    assert.equal(req.headers['Content-Type'], 'application/json');
    const body = JSON.parse(req.content);
    assert.equal(body.query, '三体 刘慈欣');
    assert.equal(body.count, 9, 'count=perEngine（limit+4 去重余量，#1634 联动）');
    assert.equal(body.need_content, false);
    assert.equal(r.items.length, 2, '无标题条目被跳过');
    assert.equal(r.items[0].source, 'DeepSeek');
    assert.equal(r.items[0].summary, '刘慈欣长篇科幻小说，雨果奖作品。', 'summary 优先于 snippet');
    assert.equal(r.items[1].summary, '同作者早期长篇', '无 summary 回退 snippet');
    assert.ok(r.stats.includes('DeepSeek 2'), r.stats);
    // ③ count 夹取上限 50 + 查询超长截 128（API 硬约束）
    deps.state.rcpResponses = [{ statusCode: 200, body: enc('{"results":[]}') }];
    await EncyclopediaService.searchWeb('长'.repeat(200), 60);
    const req2 = deps.state.requests[deps.state.requests.length - 1];
    const body2 = JSON.parse(req2.content);
    assert.equal(body2.count, 50, 'count 上限 50');
    assert.equal(body2.query.length, 128, 'query 截 128');
    deps.state.store.clear();
    deps.state.rcpResponses = [];
  });

}
