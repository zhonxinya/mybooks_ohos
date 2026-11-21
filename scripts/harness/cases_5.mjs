// 用例组 5：网文元数据源语料（MetaSearch/NovelMeta/Reader3 匹配）（拆分自 check_ai_assistant.mjs，用例体原样）
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { test, state, settingsDefaults, enc, rtB64, deferred, tick, flush } from './base.mjs';
import { dir, read, ETS, ROOT } from './paths.mjs';
import { DOUBAN_PAGE, K17_PAGE, KUJIANG_PAGE, CIWEIMAO_PAGE, ZONGHENG_PAGE, QIDIAN_M_PAGE, WTZW_PAGE, WXSCS_PAGE, UJXSW_PAGE, MH_PAGE, FQ_INFO_B64, XXSY_PAGE, ZY_PAGE, QX_PAGE, YE_PAGE, SF_PAGE, DD_PAGE, YQ_DETAIL, R3_SOURCES } from './fixtures.mjs';

export function register(ctx) {
  const { load, deps, RealAiService, RealAiTools, parseToolBookLines, toolsState, mdParseBlocks, mdParseInline, AI_SKILLS, AiAssistantPage, AiBookPanelPage, AiRecommendPage, AiSettingsPage, AiPersonaPage, AiPersona, DEFAULT_SOUL, AiChatStore, personaState, MetaSearchService, NovelMetaService, resetSettings, settingsPage, chat, reappear } = ctx;

  test('MetaSearch：豆瓣 suggest 过滤非图书条目，subject 详情页解析评分/出版社/ISBN', async () => {
    deps.state.rcpResponse = { statusCode: 200, body: enc(JSON.stringify([
      { title: '三体', url: 'https://book.douban.com/subject/2567698/', pic: 'https://img/x.jpg',
        author_name: '刘慈欣', year: '2008', type: 'b', id: '2567698' },
      { title: '三体', type: 't', id: '999', author_name: '', year: '', pic: '', url: '' },
    ])) };
    const hits = await MetaSearchService.suggest('三体');
    assert.equal(hits.length, 1);
    assert.equal(hits[0].subjectId, '2567698');
    assert.equal(hits[0].author, '刘慈欣');
    deps.state.rcpResponse = { statusCode: 200, body: enc(DOUBAN_PAGE) };
    const d = await MetaSearchService.detail('2567698');
    assert.ok(d.ok);
    assert.equal(d.title, '三体');
    assert.equal(d.rating, '8.9');
    assert.equal(d.publisher, '重庆出版社');
    assert.equal(d.isbn, '9787536692930');
    assert.equal(d.pages, '302');
    assert.equal(d.author, '刘慈欣');
    assert.ok(d.intro.includes('红岸工程'));
    // 非数字 id 与 HTTP 错误都走 ok=false 分支
    const bad = await MetaSearchService.detail('abc');
    assert.ok(!bad.ok);
    deps.state.rcpResponse = { statusCode: 403, body: enc('') };
    const blocked = await MetaSearchService.detail('2567698');
    assert.ok(!blocked.ok && blocked.error.includes('403'));
    deps.state.rcpResponse = null;
  });

  // 17K 详情页样本节选（2026-11-19 www.17k.com/book/1018082.html 实测锚点）
  test('NovelMeta：17K 详情页解析全字段（导航「完本小说」不得误判状态）', () => {
    const m = NovelMetaService.parse17k(K17_PAGE);
    assert.ok(m.ok);
    assert.equal(m.title, '武逆焚天');
    assert.equal(m.author, '疯橘子');
    assert.equal(m.status, '连载中'); // 顶部导航也有「完本小说」，必须限定 .label 块
    assert.equal(m.category, '东方玄幻');
    assert.ok(m.cover.startsWith('https://cdn.static.17k.com/'));
    assert.ok(m.intro.includes('神奇的大陆') && m.intro.includes('重宝出世') && !m.intro.includes('&lt;'));
  });

  test('NovelMeta：通用 og 规则、相对封面补全、WAF 挑战页识别、非 http url', async () => {
    const gen = `<html><head><meta property="og:image" content="/files/article/image/2/2402/2402s.jpg">
<meta property="og:description" content="蒸汽与机械的浪潮中，谁能触及非凡？"></head>
<body><h1>诡秘之主</h1></body></html>`;
    deps.state.rcpResponse = { statusCode: 200, body: enc(gen) };
    const m = await NovelMetaService.fetchDetail('http://www.mcxs.info/book/2402/');
    assert.ok(m.ok && m.rule === '通用og');
    assert.equal(m.cover, 'http://www.mcxs.info/files/article/image/2/2402/2402s.jpg');
    assert.ok(m.intro.includes('蒸汽与机械'));
    // WAF 挑战页 → 明确报「换书源」，不能报解析失败
    deps.state.rcpResponse = { statusCode: 200, body: enc("<script>var arg1='AB';reload('acw_sc__v2')</script>") };
    const waf = await NovelMetaService.fetchDetail('https://search.17k.com/search.xhtml?c.q=x');
    assert.ok(!waf.ok && waf.error.includes('WAF'));
    deps.state.rcpResponse = null;
    const bad = await NovelMetaService.fetchDetail('javascript:alert(1)');
    assert.ok(!bad.ok && bad.error.includes('http'));
  });

  // og:novel 结构化样本（2026-11-20 实测 m.kujiang.com/book/91737、ciweimao.com/book/100506842）
  test('NovelMeta：og:novel 结构化规则——书名去站名尾巴、状态归一、缺字段不崩', () => {
    const k = NovelMetaService.parseGeneric(KUJIANG_PAGE);
    assert.ok(k.ok && k.rule === 'og:novel');
    assert.equal(k.title, '灯下黑');
    assert.equal(k.author, '鱼不语');
    assert.equal(k.status, '已完本'); // 「完结」归一
    assert.ok(k.cover.startsWith('https://bs.kjcdn.com/'));
    assert.ok(k.intro.includes('贺录对祝卿安') && k.intro.includes('单韩苼')); // <br/> 转换行不断句
    const c = NovelMetaService.parseGeneric(CIWEIMAO_PAGE);
    assert.ok(c.ok && c.rule === 'og:novel');
    assert.equal(c.title, '型月模拟，雅典娜的头号走狗'); // og:title 带「无弹窗全文阅读-欢乐书客」尾巴，弃用
    assert.equal(c.category, '科幻无限');
    assert.equal(c.status, ''); // 该站无 status 字段，不得瞎猜
  });

  // 纵横 fixture：2026-11-20 www.zongheng.com/book/1435440.html 实测（Nuxt SSR，name= 写法，
  // 且 og:description 值被站点模板二次包壳成 content=&quot;…&quot;）
  test('NovelMeta：纵横 name= 写法命中 og:novel + 站点脏 description 脱壳', () => {
    const m = NovelMetaService.parseGeneric(ZONGHENG_PAGE);
    assert.ok(m.ok && m.rule === 'og:novel');
    assert.equal(m.title, '齐天');
    assert.equal(m.author, '日落红尘');
    assert.equal(m.category, '玄幻奇幻');
    assert.equal(m.status, '连载中');
    assert.ok(m.intro.startsWith('纵横小说网提供'), 'content=&quot; 包壳必须剥掉');
    assert.ok(m.intro.includes('齐麟家祖祠内') && !m.intro.endsWith('&quot;') && !m.intro.endsWith('"'));
  });

  // 起点移动版 fixture：2026-11-20 m.qidian.com/book/1050742867 实测（www 桌面端是 202 probe.js 风控）
  test('起点：www 风控 url 重写到 m.qidian 后 og:novel 命中，协议相对封面补全', async () => {
    assert.equal(NovelMetaService.rewriteUrl('https://www.qidian.com/book/1050742867'),
      'https://m.qidian.com/book/1050742867/');
    assert.equal(NovelMetaService.rewriteUrl('https://book.qidian.com/info/1050742867/'),
      'https://m.qidian.com/book/1050742867/');
    assert.equal(NovelMetaService.rewriteUrl('https://www.ujxsw.org/book/90293/'),
      'http://www.ujxsw.org/book/90293/'); // ujxsw https 端口不通（curl 000），手贴 https 降到 http
    assert.equal(NovelMetaService.rewriteUrl('https://www.wtzw.com/book/224292.html'),
      'https://www.wtzw.com/book/224292.html');
    deps.state.rcpResponse = { statusCode: 200, body: enc(QIDIAN_M_PAGE) };
    const m = await NovelMetaService.fetchDetail('https://www.qidian.com/book/1050742867/');
    assert.ok(m.ok && m.rule === 'og:novel');
    assert.equal(m.title, '美利坚：超凡入圣');
    assert.equal(m.author, '白魔星');
    assert.equal(m.category, '异术超能');
    assert.equal(m.status, '连载中'); // 「连载」归一
    assert.equal(m.cover, 'https://bookcover.yuewen.com/qdbimg/349573/1050742867/180');
    assert.ok(m.intro.includes('超凡复苏'));
    deps.state.rcpResponse = null;
  });

  // 梧桐中文 fixture：2026-11-20 www.wtzw.com/book/224292.html 实测节选（无 og，类名锚点）
  test('NovelMeta：梧桐中文类名锚点——书名取 li_tit 内 a（顶层 h1 是站名）、状态归一、类别缺不猜', () => {
    const m = NovelMetaService.parseWtzw(WTZW_PAGE);
    assert.ok(m.ok && m.rule === '梧桐中文');
    assert.equal(m.title, '我的少年班'); // 顶层 <h1> 是「免费小说就在梧桐中文网」，不得误取
    assert.equal(m.author, '卿殇');
    assert.equal(m.status, '已完本'); // 「已完结」归一
    assert.equal(m.category, '');
    assert.ok(m.intro.includes('空军青少年航空学校'));
    assert.ok(m.cover.startsWith('//cdn.qimao.com/')); // 协议相对，fetchDetail 里统一补全
  });

  // 万相书城 fixture：2026-11-20 www.wxscs.com/book/10212 实测 meta 节选。
  // 该站 Apache 按 UA 放行（桌面 403/移动 200），回归同时盯住 UA 特判不回退
  test('NovelMeta：wxscs 桌面 UA 403 教训——UA 按站点选择，移动 UA+相对封面补全', async () => {
    deps.state.rcpResponse = { statusCode: 200, body: enc(WXSCS_PAGE) };
    const m = await NovelMetaService.fetchDetail('https://www.wxscs.com/book/10212/');
    assert.ok(m.ok && m.rule === 'og:novel');
    assert.equal(m.title, '新月剑');
    assert.equal(m.status, '已完本'); // 「完结」归一
    assert.equal(m.cover, 'https://www.wxscs.com/uploads/cover/pic10212.jpg');
    assert.ok(String(deps.state.lastRequest.headers['User-Agent']).includes('Mobile'),
      'wxscs 必须用移动 UA（桌面 UA 实测 403）');
    deps.state.rcpResponse = { statusCode: 200, body: enc(QIDIAN_M_PAGE) };
    await NovelMetaService.fetchDetail('https://www.qidian.com/book/1050742867/');
    assert.ok(String(deps.state.lastRequest.headers['User-Agent']).includes('Windows NT'),
      '其他站保持桌面 UA');
    deps.state.rcpResponse = null;
  });

  // 晋江模板串：仿 2026-11-20 onebook.php?novelid=10035712 实测结构（schema.org itemprop），
  // 专防两坑：畸形 `_src` 属性（真实页 img 有 _src="…" src="…" 双属性）、简介 div 超 2000 字符
  test('NovelMeta.parseJjwxc：itemprop 锚点——防 _src 误取、长简介、状态归一、类别原样', () => {
    const long = 'A'.repeat(2500);
    const page = `<html><body>
<h1 itemprop="name"><span itemprop="articleSection">测试书名</span> </h1>
<h2>作者：<a href="#"><span style="font-size:12px" itemprop="author">测试作者</span></a></h2>
<li><span>文章类型：</span> <span style="color:#000;float:none" itemprop="genre"> 原创-言情-近代现代-爱情 </span> </li>
<li><span>文章进度：</span><span style="color:#000;float:none" itemprop="updataStatus">已完结</span></li>
<div class="smallreadbody"> <img class="noveldefaultimage" itemprop="image"_src="https://BAD.example/wrong.jpg" src="https://GOOD.example/right.jpg" width="200"><div id="novelintro" itemprop="description">文案开头${long}文案结尾</div>
</body></html>`;
    const m = NovelMetaService.parseJjwxc(page);
    assert.ok(m.ok && m.rule === '晋江');
    assert.equal(m.title, '测试书名');
    assert.equal(m.author, '测试作者');
    assert.equal(m.category, '原创-言情-近代现代-爱情'); // 四段串原样保留
    assert.equal(m.status, '已完本'); // 「已完结」归一
    assert.ok(m.cover.includes('right.jpg') && !m.cover.includes('wrong.jpg'),
      '必须取真实 src 而非畸形 _src');
    assert.ok(m.intro.startsWith('文案开头') && m.intro.length === 501,
      `>2000 字符简介也必须命中并截断，实际 ${m.intro.length}`);
  });

  // 晋江 gb18030 端到端：2026-11-20 onebook.php?novelid=10035712 真页关键区块节选
  test('NovelMeta：晋江 gb18030 页 fetchDetail 端到端——编码嗅探+itemprop 全字段', async () => {
    const JJWXC_B64 = 'PGh0bWw+PGhlYWQ+PG1ldGEgaHR0cC1lcXVpdj0iQ29udGVudC1UeXBlIiBjb250ZW50PSJ0ZXh0L2h0bWw7IGNoYXJzZXQ9Z2IxODAzMCI+PHRpdGxlPng8L3RpdGxlPjwvaGVhZD48Ym9keT4gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxzcGFuIGNsYXNzPSJiaWd0ZXh0Ij48aDEgaXRlbXByb3A9Im5hbWUiPjxzcGFuIGl0ZW1wcm9wPSJhcnRpY2xlU2VjdGlvbiI+uqO1usfzyfqjusn6u+7N5rzS1tbM77bau/U8L3NwYW4+IDwvaDE+PC9zcGFuPg0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8aW5wdXQgdHlwZT0iaGlkZGVuIg0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgdmFsdWU9IiVCQSVBMyVCNSVCQSVDNyVGMyVDOSVGQSVBMyVCQSVDOSVGQSVCQiVFRSVDRCVFNiVCQyVEMiVENiVENiVDQyVFRiVCNiVEQSVCQiVGNSINCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGlkPSJwdWJfcnNfbm92ZWxuYW1lIi8+DQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPGgyPg0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg1/fV36O6PGEgaHJlZj0iaHR0cDovL3d3dy5qand4Yy5uZXQvb25lYXV0aG9yLnBocD9hdXRob3JpZD03MDM5MTY3Ij48c3Bhbg0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgc3R5bGU9ImZvbnQtc2l6ZToxMnB4IiBpdGVtcHJvcD0iYXV0aG9yIj7ns9LEPC9zcGFuPjwvYT4NCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxzcGFuIHN0eWxlPSJjb2xvcjojMDAwO2Zsb2F0Om5vbmUiIGl0ZW1wcm9wPSJnZW5yZSI+DQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgINSttLQttL+wri27w8/rzrTAtC2+58fpICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvc3Bhbj4NCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvbGk+DQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBzdHlsZT0iY29sb3I6IzAwMDtmbG9hdDpub25lIiBpdGVtcHJvcD0idXBkYXRhU3RhdHVzIj7BrNTYPC9zcGFuPg0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9saT4NCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxsaT4NCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPGltZyBjbGFzcz0ibm92ZWxkZWZhdWx0aW1hZ2UiIGl0ZW1wcm9wPSJpbWFnZSJfc3JjPSJodHRwczovL2k5LXN0YXRpYy5qand4Yy5uZXQvbm92ZWxpbWFnZS5waHA/bm92ZWxpZD0xMDAzNTcxMiZjb3ZlcmlkPTE1NiZ2ZXI9ZmYzNjkwMWVhM2Y0ZmQyNmNlMTJiY2Q4MjZlMjVmNGUiIHNyYz0iaHR0cHM6Ly9pOS1zdGF0aWMuamp3eGMubmV0L25vdmVsaW1hZ2UucGhwP25vdmVsaWQ9MTAwMzU3MTImY292ZXJpZD0xNTYmdmVyPWZmMzY5MDFlYTNmNGZkMjZjZTEyYmNkODI2ZTI1ZjRlIiB3aWR0aD0iMjAwIiBoZWlnaHQ9IjI4MCIgYWxpZ249bGVmdCByZWZlcnJlcnBvbGljeT0ibm8tcmVmZXJyZXIiIHN0eWxlPSJtYXJnaW46MCAxMHB4IDAgMDsiIG9uZXJyb3I9ImxvYWREZWZhdWx0Tm92ZWxDb3Zlcih0aGlzKSI+PGRpdiBpZD0ibm92ZWxpbnRybyIgaXRlbXByb3A9ImRlc2NyaXB0aW9uIjxkaXYgaWQ9Im5vdmVsaW50cm8iIGl0ZW1wcm9wPSJkZXNjcmlwdGlvbiI+xM/B976w0ru+9dDRwLSjrL7NtcPWqtfUvLqxu9K7uPa90KG2uqO1usfzyfqht7XE0LC28dPOz7fPtc2zsPPGscHLoaO007TLus3AttDHy7XU2bz7o6y687Dryfq2vLnSv7/U2tK71/m54s26zbq1xNChtbrJz8HLoaM8YnI+yrLDtL3Qv6q+1tK71/m1uqOszu/Xysirv7+4zrChoaM8YnI+w+a21MTxsrvArcq6tcS7xLW6o6zBvcrWv9W/1bXExM/B976wttq79cant7jBy6GjPGJyPrK70NCjrLHY0Ou1w7jOxvDAtKOho6GjoTxicj7L+7jPuqOjrNbWtdijrNH4yrfAs8S3o6zSu9PQv9W+zb+qtKzMvcv318rUtLW6o6y6zdSt16HD8df2vbvS16GjPGJyPtPayse9pb2ltcSjrNCh0KG1xLW60+zSu9TZwKm9qKOsu8S12LHkwbzM76GjxMGzob+qxvDAtMHLo6y357O1vajG8MC0wcujrMTPwfe+sLK7ueLE3NfUuPjX1Nfjo6y7ucTctqjG2sil1K3XocPxtcS1usnPsNrMr8L0xam4sbL6xrejrNeswLS1xMeu16rK1r7NwvLBy7j8tuDKtdPDtcTBtr3wtcC+36GjPGJyPtfUtq+9vcuuxvejv7rDtqvO96OswvLBy6OhPGJyPjMwzOy1xNDCytbG2rn9yKWjrNPOz7fVub+qwcvL/M/VtvG1xNXmw+bEv6GjzOzU1r3T9eC2+NbBo6y8q7quoaK4387CoaKxqdPqoaLTwNK5oa2hrcO/0ru49jMwzOy2vM6qzea80rT4wLTRz77+tcS/vNHpoaM8YnI+xM/B976w08DUtsrH17yxuNfus+TX47XExMfSu8X6oaM8YnI+sam359GpwLTB2aOsxM/B976w1/jU2s7Cxa+1xMWpyeHA76Osv77XxcWvyNrI2rXEsdrCr6Os0rux38P+18W0883Iyc/Lr7PJ0rvNxbXEw6jSu7HfusjXxcjIv8m/yaGjPGJyPrCmo6zQ0rijoaM8YnI+087Pt7K7ysfDu9PQ1b22t9Sqy9ijrLWryfq77s3mvNKyu7CuuOPEx9CptPK08smxybG1xKGjPGJyPrWxyLvBy6OsyOe5+9PQxMS49rK7s6TR27XEtai40sC0tPLIxcv71ta12KOsxM/B976w0rK74brBsru/zcb4tcShraGtsNHL+9bWtb212MDvoaM8YnI+PGJyPtbY0qrLtcP3o7qxvs7Eyei2qMHpuNDAtNfUtuCyv8TBs6HO79Pv087Pt6OsyOfT0MDXzayjrMTH0ru2qMrHztLU2tbCvrSjoTxicj6hqqGqoaqhqjxicj7Qob7ns6Gjujxicj5Bo7q458PHo6zE49XitqvO97K7tO2woaOsxMTC8rXEo788YnI+QqO6srvWqrW6oaM8YnI+QaO6ztLOysTjyse008TEtvnC8rXEo6GjoTxicj5Co7rO0su1wcujobK71qq1urCho6GjoTxicj48YnI+PGJyPqGqoaqhqqGqoaqhqs/Ct73Kx9SkytWjoTxicj6htsrAvee52r78tNPQodPEwem/qsq8obc8YnI+PGJyPqGhoaHV4srH0ru49sjL0+u7w8HpubLJ+rXEysC956GjPGJyPqGhoaHCvdXV0MfS8s6q0ru33c38tPi72LzStcS+7dfTt7W72NGn0KOjrMi01OK1vcHL0rDJ+rvDwem1xM+uu/ejrLK70KHQxLX0vfjBy7vDwem1xMrAveehsLa0v9+hsaOssu6147b5xdzLwNTawO/D5qGjPGJyPqGhoaHQ0rrDzOzO3r74yMvWrsK3o6zU2rG70rDJ+rvDwem89LX0srHX08ewo6zCvdXV0Me6zcbVzai8trvDwenQodPEwenP4NP2wcuhozxicj6hoaGh1NrG1c2ovLa7w8Hp1tDSssrH1+7I9dK7tbW1xNCh08TB6b7Ny+O9+LuvwcvSsrrcyPXQoaOs0/nB6cqmw8e1q7ey09C149e3x/O2vLK7u+HRodTxxvXUvNCh08TB6aOstavU2s6ju/rWrtbQo6zWu9PQy/y21MK91dXQx8nss/bBy8rWoaM8YnI+oaGhocK91dXQx7rBsrvTzNSltdjO1cHLyc/IpaGjPGJyPqGhoaGhsNfuyPXQobXE08TB6c+1u8PB6aGx09bU9dH5o7/CvdXV0MfX1NDFxr696NfUvLq1xNW9yvXWuLvTus3Ep7nt0bXBt6Os1NnF5LrP0KHTxMHps6zHv7XE1b22t9Li1r6jrMv7w8fSu7aoxNzU2se/1d/I59TGtcS7w8HpttTVvdbQybGz9tK7zPXRqsK3wLShozxicj6hoaGhxL+x6srHyKu5+rnavvyjoTxicj48YnI+oaGhoaGqoaqhqqGqPGJyPqGhICAgsb7OxMHpuNDAtNfUoba+q8Hpsaa/ycPOobehoqG2yv3C67GmsbSht7XI0fiz6LbU1b3Tzs+3o6zI59PQwNfNrKOst8ezo9X9s6OjoTxicj6hoaGhsb7OxMTayN2w/MCoo7rG9dS8u8PB6aGiu8PB6dG1wbehosn9vLahora0v9/Mvc/VoaK7w8HpttTVvaOotaXIyy/Nxczlo6k8YnI+oaGhobG+zsTW973Ho7rH7rfowcu1q7bUu8PB6brctPO3vbXE1b22t7/xQmtpbme6zcv7sK62usOotcTE6snPttTP8zxicj4gICAgICAgysC959fux7/Lq7TytO61tSArIM31sru8+831tcS1pbTyvqK10Dxicj6hoaGhyf28tsH3oaK087OkxqqhosTauqzDyLPoo6zH67TzvNLWp7PW0KHTxMHpo6HWp7PWzrTAtLXEysC957navvzQocK9o6E8YnI+PGJyPqGqoaqhqqGqoaqhqjxicj48YnI+oba087q9uqOjurTT0KG3q7Ssv6rKvKG3PGJyPtC7wdbSu9ax0tTAtLa8vvW1w6Os19S8ur7NysfG1crA0uLS5cnPtcS1ucO5tbChozxicj6438vZuavCt8nPMTGztcGsu7fXt86yo6zGq8arvs3Iw8v7uM/Jz8HLo6zGq8arvs3Kx8v7w8e1xLO1v6jU2rWx1tCjrMarxqu+zcrHy/vU2sTHwO/Kp8ilwcvSu8fQoaM8YnI+s7W79sjDy/u1xNK7zPXNyLfby+nQ1LnH1dujrLu509DSu7j5wN+5x7TMxsbBy7fOoaOyu732v+DBt7bgxOq1xPXMyK21wLuv1/fF3dOwo6y7ucjDy/u007TLuOax8NX9s6PIy7XEyfq77qOss8nBy8rAyMvR29bQtcT1y9fTo6yx8Mu1xdzBy6OstuDX38G9sr22vNKqtPO0rcb4oaM8YnI+1NnDu9PQyMuxyMv7uPy1ucO5wcuhozxicj48YnI+tvjSsr7NysfV4tH5tcTL+6Os1Nmxu8CtyOvIq8Pxx/PJ+tPOz7e686Osu/G1w8HLsbvPtc2zx9W2qLXETHVja3kgRG9nzOy4s6GjPGJyPsuto7/O0sLwo788YnI+vLTKub71tcPPtc2ztcTF0LbPxsS+37fttMzS4s62o6zQu8HW0rLDu9PQyM66zrDst6iho8vXu7DLtbjssrLFobK7uf20883Io6zE3LDRyKvAttDHtrzArTwvZGl2PjwvYm9keT48L2h0bWw+';
    const raw = Buffer.from(JJWXC_B64, 'base64');
    deps.state.rcpResponse = { statusCode: 200,
      body: raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) };
    const m = await NovelMetaService.fetchDetail('http://www.jjwxc.net/onebook.php?novelid=10035712');
    assert.ok(m.ok && m.rule === '晋江');
    assert.equal(m.title, '海岛求生：生活玩家种田囤货');
    assert.equal(m.author, '绯夷');
    assert.equal(m.category, '原创-纯爱-幻想未来-剧情');
    assert.equal(m.status, '连载中');
    assert.ok(m.intro.startsWith('南流景一觉醒来') && !m.intro.includes('\uFFFD'),
      'gb18030 解码简介须可读不乱码');
    assert.ok(m.cover.startsWith('https://i9-static.jjwxc.net/novelimage.php'));
    deps.state.rcpResponse = null;
  });

  // 悠久书城 fixture：2026-11-20 www.ujxsw.org/book/90293 实测节选（无 og，正文锚点）
  test('NovelMeta：悠久书城——书名取 d_title 内 h1（顶层 h1 是站名）、无状态留空不猜', () => {
    const m = NovelMetaService.parseUjxsw(UJXSW_PAGE);
    assert.ok(m.ok && m.rule === '悠久书城');
    assert.equal(m.title, '剑仙'); // 顶层 <h1> 是「悠久小说网」站名，不得误取
    assert.equal(m.author, '兵围城下');
    assert.equal(m.category, '仙侠修真');
    assert.equal(m.status, ''); // 页面无状态字段——留空不猜
    assert.equal(m.cover, 'http://www.ujxsw.org/files/article/image/90/90293/90293s.jpg');
    assert.ok(m.intro.startsWith('剑仙最新章节由网友提供'));
  });

  // 棉花书吧 fixture：2026-11-20 www.mianhuaks.com/book/94801+15091 实测节选（无 og:novel，主区锚点）
  test('NovelMeta：棉花书吧——主区锚点+状态归一；默认图/无类别留空，推荐区封面不误取', async () => {
    const m = NovelMetaService.parseMianhua(MH_PAGE);
    assert.ok(m.ok && m.rule === '棉花书吧');
    assert.equal(m.title, '渣受重生');
    assert.equal(m.author, '俺打的去埃及');
    assert.equal(m.status, '连载中');
    assert.equal(NovelMetaService.parseMianhua(MH_PAGE.replace('状态：连载', '状态：完结')).status,
      '已完本', '完结→已完本归一');
    assert.equal(m.category, ''); // 页面无类别字段，导航「分类」是 /tags.html 链接——留空不猜
    assert.equal(m.cover, ''); // 主区封面是站默认图 /asset/default.jpg，不算封面；推荐区 /thumb/ 不误取
    assert.ok(m.intro.includes('混娱乐卖') && m.intro.includes('行，') &&
      !m.intro.includes('45.png'), '防盗图 img 须剥除且前后文连贯');
    deps.state.rcpResponse = { statusCode: 200, body: enc(MH_PAGE) };
    const d = await NovelMetaService.fetchDetail('https://www.mianhuaks.com/book/94801/');
    assert.ok(d.rule === '棉花书吧' && d.title === '渣受重生', 'fetchDetail 分派命中');
    deps.state.rcpResponse = null;
  });

  // 番茄 fixture：2026-11-20 /api/book/info?bookId=7064405896540982309 真实响应（categoryV2 截首元素）
  test('NovelMeta：番茄——rewriteUrl 走 info API 端到端，creationStatus 0/1 归一，categoryV2 首元素', async () => {
    assert.equal(NovelMetaService.rewriteUrl('https://fanqienovel.com/page/7064405896540982309'),
      'https://fanqienovel.com/api/book/info?bookId=7064405896540982309');
    const body = Buffer.from(FQ_INFO_B64, 'base64').toString('utf-8');
    const m = NovelMetaService.parseFanqie(body);
    assert.ok(m.ok && m.rule === '番茄小说');
    assert.equal(m.title, '武碎星河');
    assert.equal(m.author, '妖夜');
    assert.equal(m.category, '传统玄幻'); // categoryV2 首元素（Dim=10 主分类）
    assert.equal(m.status, '已完本'); // creationStatus "0"=完结（终章真页交叉验证）
    assert.ok(m.cover.startsWith('https://p3-novel-sign.byteimg.com/novel-pic/'));
    assert.ok(m.intro.includes('寒门少年持刀') && m.intro.length <= 500);
    assert.equal(NovelMetaService.parseFanqie(body.replace('"creationStatus": "0"',
      '"creationStatus": "1"')).status, '连载中');
    assert.equal(NovelMetaService.parseFanqie('not json').error.includes('不是 JSON'), true);
    const err = NovelMetaService.parseFanqie('{"code":-1,"message":"没有bookId"}');
    assert.ok(!err.ok && err.error.includes('没有bookId'));
    deps.state.rcpResponse = { statusCode: 200, body: enc(body) };
    const d = await NovelMetaService.fetchDetail('https://fanqienovel.com/page/7064405896540982309');
    assert.ok(d.ok && d.rule === '番茄小说' && d.title === '武碎星河', '详情页 url 重写后端到端命中');
    deps.state.rcpResponse = null;
  });

  // 潇湘 fixture：2026-11-20 www.xxsy.net/book/37389130704030609 实测节选（Vue SSR 无 og）
  test('NovelMeta：潇湘书院——title 块内 h1 书名（前有手机阅读链接）、文/作者、sub-cols 跳会员标签、协议相对封面', async () => {
    const m = NovelMetaService.parseXxsy(XXSY_PAGE);
    assert.ok(m.ok && m.rule === '潇湘书院');
    assert.equal(m.title, '星际？不慌，我有万界位面！');
    assert.equal(m.author, '挣脱蛛网的蝴蝶');
    assert.equal(m.status, '连载中'); // sub-cols 首 span 是「会员作品」，状态取 连载|完结
    assert.equal(m.category, '科幻空间');
    assert.equal(m.cover, '//bookcover.yuewen.com/qdbimg/349573/c_37389130704030609/180');
    assert.ok(m.intro.startsWith('唐砚秋穿越星际'));
    deps.state.rcpResponse = { statusCode: 200, body: enc(XXSY_PAGE) };
    const d = await NovelMetaService.fetchDetail('https://www.xxsy.net/book/37389130704030609');
    assert.ok(d.rule === '潇湘书院' && d.cover.startsWith('https://bookcover.yuewen.com'),
      '分派命中+协议相对封面升 https');
    deps.state.rcpResponse = null;
  });

  // 掌阅 fixture：2026-11-20 m.zhangyue.com/detail/10161848 实测节选（无 og，SSR 正文；
  // 含「同类好书」推荐区 li 与 goCategory JS 绑定串两个干扰源）
  test('NovelMeta：掌阅——bookview 块限定主区（推荐区同名 tag/他书信息不干扰），title SEO 模板不当状态', () => {
    const m = NovelMetaService.parseZhangyue(ZY_PAGE);
    assert.ok(m.ok && m.rule === '掌阅小说网');
    assert.equal(m.title, '雪落红炉'); // 不取推荐区《鬼医嫡女》与带[精品]的 keywords
    assert.equal(m.author, '似水无痕'); // 同行前置「春芒文化」是出版方
    assert.equal(m.category, '古代言情');
    assert.equal(m.status, ''); // <title> 的「完结小说」是 SEO 固定模板，主区无状态字段
    assert.ok(m.intro.startsWith('衣香鬓影'), '剥「内容简介：」前缀');
    assert.ok(m.cover.startsWith('https://bookbk.img.zhangyue01.com'));
  });
  test('NovelMeta：掌阅端到端分派 m.zhangyue.com/detail', async () => {
    deps.state.rcpResponse = { statusCode: 200, body: enc(ZY_PAGE) };
    const d = await NovelMetaService.fetchDetail('https://m.zhangyue.com/detail/10161848');
    assert.ok(d.ok && d.rule === '掌阅小说网' && d.title === '雪落红炉');
    deps.state.rcpResponse = null;
  });

  // 群小说/一页书 fixture：2026-11-20 实测节选（qunxs.com/xiaoshuo_<id>、yiyeshu.cc/aibooks/<id>，
  // 均 og:novel 全量=通用零改动；一页书 legado 规则只写简介/封面是偷懒，og 实际齐全）
  test('NovelMeta：群小说/一页书——legado 语料下一批镜像站 og:novel 通用零改动命中（脏 og:title 去尾、双斜杠封面保留）', async () => {
    deps.state.rcpResponse = { statusCode: 200, body: enc(QX_PAGE) };
    const q = await NovelMetaService.fetchDetail('http://www.qunxs.com/xiaoshuo_14014.html');
    assert.ok(q.ok && q.rule === 'og:novel' && q.title === 'COD乙女：被覆面们盯上了'
      && q.author === '小桃是甜妹' && q.category === '都市言情小说' && q.status === '连载中',
      'qunxs 通用命中+双斜杠封面 url 原样');
    assert.ok(q.cover.indexOf('qunxs.com//images/') > 0, '双斜杠封面 GET 实测 200 可加载，不改写');
    deps.state.rcpResponse = { statusCode: 200, body: enc(YE_PAGE) };
    const y = await NovelMetaService.fetchDetail('https://www.yiyeshu.cc/aibooks/14104.html');
    assert.ok(y.ok && y.title === '重生之宠妻手册', '一页书脏 og:title 由 book_name 去尾');
    assert.ok(y.author === '云惘然' && y.status === '连载中' && y.category === '其他类型');
    deps.state.rcpResponse = null;
  });

  // 书坊/顶点 fixture：2026-11-20 实测节选（sfwx.com/\d+/\d+/ 与 dingdians.com/index/<id>/，
  // 均 og:novel 全量；顶点状态值是「全本」；sfwx 封面协议相对；sfwx 语料写 @get 而实页有 og）
  test('NovelMeta：书坊/顶点——消耗期第二批 og:novel 通用命中，顶点「全本」归一已完本、协议相对封面升 https', async () => {
    deps.state.rcpResponse = { statusCode: 200, body: enc(SF_PAGE) };
    const s = await NovelMetaService.fetchDetail('http://www.sfwx.com/10/10202/');
    assert.ok(s.ok && s.rule === 'og:novel' && s.title === '大明第一国舅'
      && s.author === '黑胖的老鼠' && s.category === '历史小说' && s.status === '连载中');
    assert.ok(/^https?:\/\/www\.sfwx\.com\/images\//.test(s.cover), '协议相对封面按页面协议补全为绝对 url');
    deps.state.rcpResponse = { statusCode: 200, body: enc(DD_PAGE) };
    const d = await NovelMetaService.fetchDetail('https://www.dingdians.com/index/104975639/');
    assert.ok(d.ok && d.title === '我真不是邪神走狗' && d.status === '已完本', '「全本」→已完本');
    assert.ok(d.author === '万劫火' && d.category === '奇幻');
    assert.ok(String(deps.state.lastRequest.headers['User-Agent']).includes('Mobile'),
      '顶点按桌面 OS 特征拦 UA（Windows NT 完整串返回身份验证壳），必须移动 UA');
    assert.equal(String(deps.state.lastRequest.headers['User-Agent']).includes('Windows NT'), false,
      '他站不受影响由上方 qidian 用例断言');
    deps.state.rcpResponse = null;
  });

  // 云起/塔读 fixture：2026-11-20 实测（云起 read 壳无 og→detail og:novel；塔读 og 全量含脏 title/双斜杠封面）
  test('NovelMeta：云起 read→detail 重写 + 塔读式脏 og:title 由 book_name 去尾——通用 og:novel 覆盖阅文/掌阅系', async () => {
    assert.equal(NovelMetaService.rewriteUrl('https://yunqi.qq.com/read/59718575/'),
      'https://yunqi.qq.com/detail/59718575');
    assert.equal(NovelMetaService.rewriteUrl('https://www.xxsy.net/book/37389130704030609'),
      'https://www.xxsy.net/book/37389130704030609'); // 他站不受影响
    deps.state.rcpResponse = { statusCode: 200, body: enc(YQ_DETAIL) };
    const d = await NovelMetaService.fetchDetail('https://yunqi.qq.com/read/59718575/');
    assert.ok(d.ok && d.rule === 'og:novel' && d.title === '粟粟' && d.status === '连载中'
      && d.category === '古代言情');
    deps.state.rcpResponse = null;
    const td = NovelMetaService.parseGeneric(`<html><head><meta property="og:title" content="仕途风云小说_阿诸_仕途风云最新章节_仕途风云无弹窗免费阅读_塔读免费小说,塔读"><meta property="og:novel:book_name" content="仕途风云"><meta property="og:novel:author" content="阿诸"><meta property="og:novel:category" content="现代都市"><meta property="og:novel:status" content="连载"><meta property="og:image" content="https://media3.tadu.com//2023/05/18/19/02/353ff3f10ca8409095452f668244e5a5.jpg"><meta property="og:description" content="简介：省督查室副主任荆涛。"></head><body></body></html>`);
    assert.ok(td.rule === 'og:novel' && td.title === '仕途风云' && td.status === '连载中');
  });

  // 飞卢 gb2312 fixture：2026-11-20 b.faloo.com/1484744.html 实测 meta 行，GBK 字节 base64
  test('NovelMeta：charset 嗅探+GBK 解码——飞卢老站不乱码，utf-8 页不受影响', async () => {
    const FALOO_B64 = 'PGh0bWw+PGhlYWQ+PG1ldGEgaHR0cC1lcXVpdj0iQ29udGVudC1UeXBlIiBjb250ZW50PSJ0ZXh0L2h0bWw7IGNoYXJzZXQ9Z2IyMzEyIj4KPG1ldGEgcHJvcGVydHk9Im9nOnRpdGxlIiBjb250ZW50PSLFzLXjzfK959W9waa1yLy2o6zC283iz8XE8tbuzOzX7tDC1cK92ijC283iz8XE8tbuzOwp1NrP39TEtsFft8nCrNChy7XN+CI+CjxtZXRhIHByb3BlcnR5PSJvZzpkZXNjcmlwdGlvbiIgY29udGVudD0iob63ycKs0KHLtc34tsC80sep1LzQocu1o7rFzLXjzfK959W9waa1yLy2o6zC283iz8XE8tbuzOyhv8zsxLu9tcHZ1u7M7KOsv6q+1sXMtePN8r3n1b3BpsG/vLaho7TTsazXqby2o6yxrMe9vLahraGtsazQx7y2o6y649DHvLajrNDHz7W8tqOs0MfPtc3FvLajrLWlzOXT7tbmvLajrLbg1KrT7tbmvLajrM7ez9624NSq0+7W5qGtoa3O3s/eutDX06Os1rjK/cv+o6yzrNa4yv3L/qOssru/ybTvu/nK/aGtoa3V5s/WyrWjrLW9Ij4KPG1ldGEgcHJvcGVydHk9Im9nOmltYWdlIiBjb250ZW50PSJodHRwOi8vaW1nLmZhbG9vLmNvbS9Ob3ZlbC80OTh4NzA1LzEvMTU5NS8wMDE1OTU5NTcuanBnIj4KPC9oZWFkPjxib2R5PjxoMT7FzLXjzfK959W9waa1yLy2o6zC283iz8XE8tbuzOw8L2gxPjwvYm9keT48L2h0bWw+';
    const raw = Buffer.from(FALOO_B64, 'base64');
    deps.state.rcpResponse = { statusCode: 200,
      body: raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) };
    const m = await NovelMetaService.fetchDetail('https://b.faloo.com/1484744.html');
    assert.ok(m.ok && m.rule === '通用og');
    assert.ok(m.intro.includes('飞卢小说网独家签约小说') && m.intro.includes('无限多元宇宙') &&
      !m.intro.includes('\uFFFD'), 'GBK 简介须可读不乱码');
    assert.equal(m.cover, 'http://img.faloo.com/Novel/498x705/1/1595/001595957.jpg');
    deps.state.rcpResponse = null;
    assert.ok(NovelMetaService.decodeBody(enc('<meta charset="utf-8">中文正常'))
      .includes('中文正常'), 'utf-8 页解码不受嗅探影响');
    // 飞卢真实布局：charset 声明在字节 ~2413（2KB 窗口会漏，4KB 才够）
    const late = Buffer.from(FALOO_B64, 'base64');
    const pad = Buffer.concat([Buffer.from('<html><head>' + 'x'.repeat(1000)), late.slice(12)]);
    const padBuf = pad.buffer.slice(pad.byteOffset, pad.byteOffset + pad.byteLength);
    assert.ok(NovelMetaService.decodeBody(padBuf).includes('charset=gb2312'),
      'charset 声明落在 2KB~4KB 窗口也必须被嗅到');
  });

  test('NovelMeta 分派：书源引擎命中即优先，不再走站点规则重抓', async () => {
    const { NovelMetaService } = await load('RealNovelMeta');
    const { Reader3Native } = await load('reader3Stub');
    Reader3Native.result = { ok: true, error: '', rule: '测试书源', name: '引擎书', author: '作者甲',
      kind: '都市·完结', intro: '引擎简介', coverUrl: 'https://cdn.example/c.jpg',
      tocUrl: 'https://s.example/book/1/', lastChapter: '第2章' };
    const prev = deps.state.requests.length;
    const meta = await NovelMetaService.fetchDetail('https://www.17k.com/book/123.html');
    Reader3Native.result = null;
    assert.strictEqual(meta.ok, true);
    assert.strictEqual(meta.rule, '书源:测试书源');
    assert.strictEqual(meta.title, '引擎书');
    assert.strictEqual(meta.status, '已完本', 'kind 里的完结词归一为状态');
    assert.strictEqual(meta.intro, '引擎简介');
    assert.strictEqual(meta.cover, 'https://cdn.example/c.jpg');
    assert.strictEqual(deps.state.requests.length, prev, '引擎命中不得再 rcp 抓页');
  });

  test('NovelMeta 分派：引擎提取失败→现有站点规则兜底（再抓一次）', async () => {
    const { NovelMetaService } = await load('RealNovelMeta');
    const { Reader3Native } = await load('reader3Stub');
    Reader3Native.result = { ok: false, error: '书源规则未提取到书名/简介/封面', rule: '失效源',
      name: '', author: '', kind: '', intro: '', coverUrl: '', tocUrl: '', lastChapter: '' };
    deps.state.rcpResponse = { statusCode: 200,
      body: enc('<meta property="og:description" content="兜底简介"/>') };
    const meta = await NovelMetaService.fetchDetail('https://example.com/book/9/');
    Reader3Native.result = null;
    deps.state.rcpResponse = null;
    assert.strictEqual(meta.ok, true);
    assert.strictEqual(meta.rule, '通用og');
    assert.strictEqual(meta.intro, '兜底简介');
  });


  test('Reader3.matchSource：pattern 优先；@ 约定取右侧 baseUrl 匹配；禁用源跳过', async () => {
    const { Reader3Native } = await load('RealReader3');
    const sources = JSON.parse(R3_SOURCES);
    assert.strictEqual(Reader3Native.matchSource(sources, 'https://pat.example/book/123.html').bookSourceName, '模式源');
    assert.strictEqual(Reader3Native.matchSource(sources, 'https://at.example/xs-1/du-2.html').bookSourceName, 'at源',
      'legado「源名@baseUrl」必须按右侧站点地址匹配（左侧是中文源名，永不命中）');
    assert.strictEqual(Reader3Native.matchSource(sources, '全本小说5@https://at.example').bookSourceName, 'at源');
    assert.strictEqual(Reader3Native.matchSource(sources, 'https://url.example/a/b/x/1').bookSourceName, 'url源');
    assert.strictEqual(Reader3Native.matchSource(sources, 'https://bad.example/book/1'), null,
      'enabled=false 的书源 pattern/url 两条通道都不得命中');
  });

  test('Reader3.meta 全链路：rawfile 装载→匹配书源→引擎外层协议→字段映射', async () => {
    const { Reader3Native } = await load('RealReader3');
    globalThis.__r3Available = true;
    globalThis.__r3Ctx = { filesDir: '/data/app' };
    deps.state.sourceJson = R3_SOURCES;
    globalThis.__r3Payload = '{"status":"ok","result":{"field":"ruleBookInfo","data":' +
      '"{\\"name\\":\\"书甲\\",\\"author\\":\\"作者乙\\",\\"kind\\":\\"连载中\\",\\"intro\\":\\"简介丙\\",' +
      '\\"coverUrl\\":\\"https://pat.example/c.jpg\\"}"}}';
    const m = await Reader3Native.meta('https://pat.example/book/123.html');
    assert.strictEqual(m.ok, true);
    assert.strictEqual(m.name, '书甲');
    assert.strictEqual(m.kind, '连载中');
    assert.strictEqual(m.coverUrl, 'https://pat.example/c.jpg');
    assert.strictEqual(m.rule, '模式源');
    assert.strictEqual(JSON.parse(globalThis.__r3SourceArg).bookSourceName, '模式源',
      '传给引擎的必须是命中的整条书源规则');
  });

  test('Reader3.meta：无匹配书源返回 null（调用方走站点规则）；引擎 error 带原文', async () => {
    const { Reader3Native } = await load('RealReader3');
    assert.strictEqual(await Reader3Native.meta('https://none.example/book/1'), null);
    globalThis.__r3Payload = '{"status":"error","message":"引擎错误 -6"}';
    const m = await Reader3Native.meta('https://pat.example/book/9.html');
    assert.strictEqual(m.ok, false);
    assert.strictEqual(m.error, '引擎错误 -6');
    globalThis.__r3Available = false;
  });

  test('Reader3 http 桥：rcp 抓取→utf-8 base64 按协议回填，书源 headers 透传', async () => {
    const { Reader3Native } = await load('RealReader3');
    globalThis.__r3Available = true;
    globalThis.__r3Payload = '{"status":"ok","result":{"data":"{\\"name\\":\\"x\\"}"}}';
    await Reader3Native.meta('https://pat.example/book/123.html'); // 建立回调注册
    deps.state.rcpResponse = { statusCode: 200,
      headers: { 'content-type': 'text/html; charset=utf-8' }, body: enc('<h1>标题页</h1>') };
    globalThis.__r3Delivered = null;
    globalThis.__r3Cb(JSON.stringify({ kind: 'http', method: 'GET',
      url: 'https://pat.example/book/123.html', headers: { 'User-Agent': 'SrcUA/1.0' } }));
    await flush();
    const d = JSON.parse(globalThis.__r3Delivered);
    assert.strictEqual(d.status_code, 200);
    assert.strictEqual(d.body_b64, Buffer.from('<h1>标题页</h1>', 'utf8').toString('base64'),
      'body_b64 必须是 UTF-8 字节的 base64');
    assert.deepStrictEqual(d.headers['content-type'], ['text/html; charset=utf-8']);
    assert.strictEqual(d.transport_error, undefined);
    assert.strictEqual(deps.state.lastRequest.headers['User-Agent'], 'SrcUA/1.0', '书源自带 UA 必须透传');
    deps.state.rcpResponse = null;
  });

}
