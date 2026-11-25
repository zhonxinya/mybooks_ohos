#!/usr/bin/env node
/**
 * 状态色硬编码门禁（批G，#1674/#1827 防回归）
 *
 * 禁止在 ets 里直写状态色令牌的浅色字面值（深色模式下对比不足）：
 *   #E84026=error #B26A00=warning #64BB5C=success #007DFF=brand_primary
 * 必须用 $r('app.color.error') 等自适应令牌。
 *
 * 豁免（行级）：系统对话框按钮数组 `{ text: '…', color: '#…' }` ——
 * showActionMenu/showDialog 的 color 参数只收字符串，无法传 Resource（批D 判定项）。
 *
 * 用法：node scripts/check_hardcoded_status_color.mjs --gate   // 违规 exit 1
 */
import { readdirSync, readFileSync, statSync } from 'fs';
import { join, posix } from 'path';

const GATE = process.argv.includes('--gate');
const ROOT = process.argv.slice(2).find((a) => !a.startsWith('--')) ??
  new URL('..', import.meta.url).pathname;
const ETS = join(ROOT, 'ohos/entry/src/main/ets');
const DIRS = ['pages', 'components', 'services', 'utils'];
const RE = /'#(?:E84026|B26A00|64BB5C|007DFF)'/;
// 系统对话框按钮：同行同时出现 text: 与 color:'状态色' 即按钮数组形态（含三元文案与 push 写法）
const RE_SYSTEM_BUTTON = /\btext:\s*.*\bcolor:\s*'#(?:E84026|B26A00|64BB5C|007DFF)'/;

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
    const lines = readFileSync(f, 'utf8').split('\n');
    lines.forEach((line, i) => {
      if (RE.test(line) && !RE_SYSTEM_BUTTON.test(line)) {
        hits.push(`${posix.relative(ETS, f)}:${i + 1}: ${line.trim().slice(0, 90)}`);
      }
    });
  }
}

console.log(`状态色硬编码门禁：命中 ${hits.length} 处`);
for (const h of hits) console.log(`  ${h}`);
if (hits.length > 0 && GATE) {
  console.error('错误：状态色须用 $r(\'app.color.error\') 等自适应令牌（深色下浅色字面值对比不足）；系统对话框按钮字符串参数除外。');
  process.exit(1);
}
