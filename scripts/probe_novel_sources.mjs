#!/usr/bin/env node
/**
 * 网文元数据源冒烟矩阵（批U，任务 #1425 维护期）
 *
 * 目的：防书源站「改版静默失效」——解析器锚点失效时应用只会回「未获取到」，
 * 没人知道是哪站哪天挂的。本探针把各规则族的**核心解析锚点**（直接抄
 * NovelMetaService 各 parse 函数的正则）对活样本详情页各打一次：
 *   锚中 = PASS；锚空/请求挂 = FAIL（≈该规则族改版或死域，需排查）。
 *
 * 注意语义边界：
 * - 宿主机 fetch 与设备上 rcp 的 TLS 指纹不同，个别站（WAF 挑战）可能
 *   本机 FAIL 而板上 OK——FAIL 是「排查信号」不是定罪证据；
 * - ujxsw 按 rewriteUrl 同款 https→http 降级（该站 https 证书坏）；
 * - shuhaige/yeudusk 无稳定详情页样本，仅做域名活性级（首页可达）。
 *
 * 用法：node scripts/probe_novel_sources.mjs   // 全 PASS exit 0，任一 FAIL exit 1
 */
const UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
  + '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
const TIMEOUT_MS = 12000;

// anchor 与 NovelMetaService.parseXxx 的同名选择器保持一致（改解析器要同步这里）
const SOURCES = [
  { rule: '17K小说网', url: 'https://www.17k.com/book/1018082.html',
    anchor: /bookName:\s*'[^']+'/ },
  { rule: '悠久书城', url: 'https://www.ujxsw.org/book/90293/', downgrade: true,
    anchor: /class="d_title"[\s\S]{0,120}?<h1>/ },
  // 2026-11-26 宿主实测：mianhuaks(Cloudflare IPv6-only DNS)/quanben/yeudusk 均 000——
  // 疑宿主出口不通，板上 rcp 出口不同可能仍活；FAIL 保留为待板上复核信号
  { rule: '棉花书吧', url: 'https://www.mianhuaks.com/book/94801/',
    anchor: /flex items-start[\s\S]{0,900}?<\/section>/ },
  { rule: '起点→移动(重写+og)', url: 'https://m.qidian.com/book/1050742867/',
    anchor: /og:novel:book_name/ },
  { rule: '番茄(重写→info API)', url: 'https://fanqienovel.com/api/book/info?bookId=7064405896540982309',
    anchor: /"authorName":/ },
  { rule: '云起(重写→detail)', url: 'https://yunqi.qq.com/detail/59718575',
    anchor: /og:novel:book_name/ },
  // mcxs.info 已于 2026-11 实测 301 迁到 mcxs.la，且详情页路径形态从 /book/<id>/
  // 变成 /<a>_<b>/；旧域样本失效，用新域样本（og:novel 全量仍供通用规则命中）
  { rule: '通用og· mcxs', url: 'http://www.mcxs.la/189_189516/',
    anchor: /og:novel:book_name/ },
  { rule: '通用og· quanben', url: 'https://www.quanben.io/n/gmzz/list.html',
    anchor: /og:description|<h1/ },
  { rule: '书海阁(域名活性)', url: 'https://www.shuhaige.net/',
    anchor: /<html/i, liveness: true },
  { rule: 'yeudusk(域名活性)', url: 'https://www.yeudusk.com/',
    anchor: /<html/i, liveness: true },
];

async function probe(s) {
  let url = s.url;
  // NovelMetaService.rewriteUrl 同款：ujxsw https→http（证书坏）
  if (s.downgrade) url = url.replace(/^https:\/\/(\S*ujxsw\.org)/, 'http://$1');
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(url, { headers: { 'User-Agent': UA }, signal: ac.signal });
    const html = await res.text();
    const hit = s.anchor.test(html);
    return { ok: res.ok && hit, note: `HTTP ${res.status}${hit ? '' : ' 锚空'}` };
  } catch (e) {
    return { ok: false, note: (e && e.message ? e.message : String(e)).slice(0, 60) };
  } finally {
    clearTimeout(t);
  }
}

let fails = 0;
for (const s of SOURCES) {
  const r = await probe(s);
  if (!r.ok) fails++;
  console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${s.rule.padEnd(20, ' ')}  ${r.note}`);
}
console.log(fails === 0
  ? `网文源冒烟：${SOURCES.length}/${SOURCES.length} 全通过`
  : `网文源冒烟：${fails} 族失败（改版/死域排查信号）`);
process.exit(fails === 0 ? 0 : 1);
