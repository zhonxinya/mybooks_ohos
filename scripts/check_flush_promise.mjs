#!/usr/bin/env node
/**
 * 裸 Promise flush 门禁（批N，小时自动化轮4）
 *
 * preferences.store.flush() 返回 Promise。若写成裸 `store.flush();`（无 await / 无 .catch/.then /
 * 无 callback 实参），flush 失败=数据未落盘但 put/delete 已"成功"返回，是静默数据丢失通道
 * （批N 实测 SecureStoreAndroid 密码封箱即此形态）。
 *
 * 合规形态：`await store.flush()` / `store.flush().then(...)` / `store.flush().catch(...)` /
 * `store.flush((err) => {...})`（callback 重载，保留同步契约）。
 * 注：业务自定义 flush 方法名（如 flushProgress/flushPersist）不匹配本规则（只判 `.flush()` 无参调用）。
 *
 * 用法：node scripts/check_flush_promise.mjs --gate   // 违规 exit 1
 *       node scripts/check_flush_promise.mjs --selftest
 */
import { readdirSync, readFileSync, statSync } from 'fs';
import { join, posix } from 'path';

const args = process.argv.slice(2);
const GATE = args.includes('--gate');
const SELFTEST = args.includes('--selftest');
const ROOT = args.find((a) => !a.startsWith('--')) ?? new URL('..', import.meta.url).pathname;
const ETS = join(ROOT, 'ohos/entry/src/main/ets');
const DIRS = ['pages', 'components', 'services', 'utils'];

// 匹配 `.flush()` 无实参调用；后置非 .then/.catch。await 用行级前缀判（间隔标识符）。
const RE_BARE = /\.flush\(\s*\)(?!\s*\.(?:then|catch))/;

function scanText(text) {
  const hits = [];
  text.split('\n').forEach((line, i) => {
    const t = line.trim();
    if (t.startsWith('//') || t.startsWith('*')) return;
    const m = line.match(RE_BARE);
    if (!m) return;
    if (/\bawait\b/.test(line.slice(0, m.index))) return; // await store.flush() 放行
    hits.push({ line: i + 1, text: t.slice(0, 90) });
  });
  return hits;
}

if (SELFTEST) {
  const bad = '      store.flush();\n';
  const okAwait = '      await store.flush();\n';
  const okThen = '      store.flush().then(() => {});\n';
  const okCatch = '      store.flush().catch((e) => {});\n';
  const okCallback = '      store.flush((err) => { hilog(e); });\n';
  const okNamed = '      ReadKitSession.flushProgress(true);\n';
  const samples = [
    { text: bad, want: 1, desc: '裸 store.flush() 命中' },
    { text: okAwait, want: 0, desc: 'await 放行' },
    { text: okThen, want: 0, desc: '.then 放行' },
    { text: okCatch, want: 0, desc: '.catch 放行' },
    { text: okCallback, want: 0, desc: 'callback 重载放行' },
    { text: okNamed, want: 0, desc: '自定义 flushXxx 不误伤' },
  ];
  let fails = 0;
  for (const s of samples) {
    const got = scanText(s.text).length;
    if (got !== s.want) { fails++; console.log(`  [FAIL] ${s.desc}：期望 ${s.want}，实得 ${got}`); }
  }
  console.log(fails === 0 ? `裸 flush 门禁 selftest 通过（${samples.length}/${samples.length}）`
    : `裸 flush 门禁 selftest 失败 ${fails} 项`);
  process.exit(fails === 0 ? 0 : 1);
}

function walk(dir, out) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (name.endsWith('.ets')) out.push(p);
  }
}

const hits = [];
for (const d of DIRS) {
  const files = [];
  walk(join(ETS, d), files);
  for (const f of files) {
    for (const h of scanText(readFileSync(f, 'utf8'))) {
      hits.push(`${posix.relative(ETS, f)}:${h.line}: ${h.text}`);
    }
  }
}

console.log(`裸 Promise flush 门禁：命中 ${hits.length} 处`);
for (const h of hits) console.log(`  ${h}`);
if (hits.length > 0 && GATE) {
  console.error('错误：store.flush() 必须 await / .catch / callback 处理，裸调用 flush 失败会静默丢数据。');
  process.exit(1);
}
