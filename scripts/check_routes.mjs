#!/usr/bin/env node
/**
 * 路由注册一致性门禁（批M，小时自动化轮3）
 *
 * 校验双向：
 *  A. 源码里出现的 'pages/X' 字面量必须注册在 main_pages.json
 *     （未注册路由 pushUrl 运行时失败；调用方 .catch(()=>{}) 抑制形态会把失败吞成静默）
 *  B. main_pages.json 注册项必须有对应 pages/X.ets 源文件
 *     （死路由=包体膨胀+路由表漂移）
 *
 * 口径：仅静态字面量；'pages/' + 变量 的动态拼接不参与（现状全库无此形态，
 * 若未来引入需同步扩展本脚本）。扫描根=ets 全目录。
 *
 * 用法：node scripts/check_routes.mjs --gate   // 违规 exit 1
 *       node scripts/check_routes.mjs --selftest
 */
import { readdirSync, readFileSync, existsSync, statSync } from 'fs';
import { join, posix } from 'path';

const args = process.argv.slice(2);
const GATE = args.includes('--gate');
const SELFTEST = args.includes('--selftest');
const ROOT = args.find((a) => !a.startsWith('--')) ?? new URL('..', import.meta.url).pathname;
const MAIN = join(ROOT, 'ohos/entry/src/main');
const ETS = join(MAIN, 'ets');
const PAGES_JSON = join(MAIN, 'resources/base/profile/main_pages.json');
const RE = /['"](pages\/[A-Za-z0-9_]+)['"]/g;

function scanText(text) {
  const out = new Set();
  for (const m of text.matchAll(RE)) out.add(m[1]);
  return out;
}

function walk(dir, out) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (name.endsWith('.ets')) out.push(p);
  }
}

if (SELFTEST) {
  // 造夹具：注册表两条（其一有"源文件"），源码引用一条未注册 + 一条死注册
  const registered = ['pages/RealPage', 'pages/DeadPage'];
  const sourceText = `router.pushUrl({ url: 'pages/RealPage' });
    router.pushUrl({ url: 'pages/NotRegistered' });
    const k = "pages/RealPage";`;
  const files = new Set(['pages/RealPage.ets']); // DeadPage 无源文件
  const A = [...sourceText.matchAll(RE)].map((m) => m[1]);
  const unregistered = A.filter((r) => !registered.includes(r));
  const dead = registered.filter((r) => !files.has(`${r}.ets`));
  const pass = unregistered.length === 1 && unregistered[0] === 'pages/NotRegistered' &&
    dead.length === 1 && dead[0] === 'pages/DeadPage';
  console.log(pass ? '路由门禁 selftest 通过（未注册命中+死注册命中+合法项放行）'
    : `路由门禁 selftest 失败：unregistered=${unregistered.join(',')} dead=${dead.join(',')}`);
  process.exit(pass ? 0 : 1);
}

if (!existsSync(PAGES_JSON)) {
  console.error(`错误：未找到 ${PAGES_JSON}`);
  process.exit(1);
}
const registered = new Set(JSON.parse(readFileSync(PAGES_JSON, 'utf8')).src);

const hits = [];
const files = [];
walk(ETS, files);
for (const f of files) {
  for (const r of scanText(readFileSync(f, 'utf8'))) {
    if (!registered.has(r)) {
      hits.push(`未注册路由：${posix.relative(ETS, f)} 引用 '${r}' 不在 main_pages.json`);
    }
  }
}
for (const r of registered) {
  if (!existsSync(join(ETS, `${r}.ets`))) {
    hits.push(`死注册路由：main_pages.json '${r}' 无对应源文件`);
  }
}

console.log(`路由注册一致性门禁：命中 ${hits.length} 处（注册 ${registered.size} 项）`);
for (const h of hits) console.log(`  ${h}`);
if (hits.length > 0 && GATE) {
  console.error('错误：路由字面量必须注册（未注册=pushUrl 静默失败）；注册项必须有源文件（死路由）。');
  process.exit(1);
}
