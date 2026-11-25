#!/usr/bin/env node
/**
 * 错误呈现门禁（#1670）：pages/components 的 catch 作用域内，禁止把异常变量裸插进
 * 面向用户的字符串（`${e}` 直拼 Toast/notice/状态文案会向用户甩出
 * "Error: [object Object]" 之类原始异常串）。统一要求 ErrorFormat.message(e)。
 *
 * 判定形态（与替换器同构）：
 *  - 块式 `catch (X) { …${X}… }`（花括号深度定界，深度自入口后计）
 *  - 链式 `.catch((X: T) => …${X}…)`（单行体=本行；块体=深度定界）
 *  - hilog/console 行豁免（日志面向开发者，保留原始值）
 *  - 三元式（#1827 扩展，全目录含 services/utils）：
 *    `X instanceof Error ? X.message : String(X)|X|`${X}`|`${ErrorFormat.message(X)}``
 *    ——兜底绕过归一化；自定义文案兜底（: '导入失败'）是有意 UX，放行。
 *
 * 用法：node scripts/check_error_toast.mjs --gate   // 违规 exit 1
 *       node scripts/check_error_toast.mjs          // 只报告
 */
import { readdirSync, readFileSync, statSync } from 'fs';
import { join, posix } from 'path';

const GATE = process.argv.includes('--gate');
const ROOT = process.argv.slice(2).find((a) => !a.startsWith('--')) ??
  new URL('..', import.meta.url).pathname;
const ETS = join(ROOT, 'ohos/entry/src/main/ets');
const DIRS = ['pages', 'components'];
const TERNARY_DIRS = ['pages', 'components', 'services', 'utils'];

const RE_BLOCK = /\bcatch\s*\(\s*([A-Za-z_$][\w$]*)\s*(?::[^)]*)?\s*\)\s*\{/;
const RE_ARROW = /\.catch\s*\(\s*\(\s*([A-Za-z_$][\w$]*)\s*(?::[^)]*)?\s*\)\s*=>/;
const RE_TERNARY = /\b([A-Za-z_$][\w$]*)\s+instanceof\s+Error\s*\?\s*\1\.message\s*:\s*(?:String\(\1\)|\1(?![.\w$])|`\$\{\1\}`|`\$\{ErrorFormat\.message\(\1\)\}`)/;

function scanFile(path, ternary) {
  const lines = readFileSync(path, 'utf8').split('\n');
  const hits = [];
  let varName = null, depth = 0, inline = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (ternary && RE_TERNARY.test(line)) {
      hits.push(`${posix.relative(ETS, path)}:${i + 1}: ${line.trim().slice(0, 100)}`);
    }
    let startFrom = 0;
    if (varName === null) {
      const mB = line.match(RE_BLOCK);
      const mA = !mB ? line.match(RE_ARROW) : null;
      if (mB) { varName = mB[1]; depth = 1; startFrom = mB.index + mB[0].length; }
      else if (mA) {
        varName = mA[1];
        const bodyBrace = /\}\s*$/.test(line.slice(mA.index + mA[0].length - 1)) ||
          line.slice(mA.index).includes('=> {') || line.trimEnd().endsWith('{');
        if (bodyBrace) { depth = 1; startFrom = mA.index + mA[0].length; }
        else { inline = true; }
      }
    }
    if (!ternary && varName !== null && !/hilog\.|console\./.test(line)) {
      const re = new RegExp('\\$\\{' + varName + '\\}(?!\\.)', 'g');
      if (re.test(line)) hits.push(`${posix.relative(ETS, path)}:${i + 1}: ${line.trim().slice(0, 100)}`);
    }
    if (varName !== null) {
      if (inline) { varName = null; inline = false; }
      else {
        const tail = line.slice(startFrom);
        for (const ch of tail) { if (ch === '{') depth++; else if (ch === '}') depth--; }
        if (depth <= 0) varName = null;
      }
    }
  }
  return hits;
}

const all = [];
for (const d of DIRS) {
  const dir = join(ETS, d);
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isFile() && name.endsWith('.ets')) all.push(...scanFile(p, false));
  }
}
for (const d of TERNARY_DIRS) {
  const dir = join(ETS, d);
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isFile() && name.endsWith('.ets') && name !== 'ErrorFormat.ets') {
      all.push(...scanFile(p, true));
    }
  }
}
if (all.length === 0) {
  console.log('错误呈现门禁通过：catch 作用域内无裸异常插值');
} else {
  console.log(`错误呈现违规 ${all.length} 处（catch 变量须过 ErrorFormat.message）：`);
  for (const h of all) console.log('  ' + h);
  if (GATE) process.exit(1);
}
