#!/usr/bin/env node
// 文件有效行数门禁（参考 zcode 仓库 .oxlintrc.json 的 max-lines 语义）：
//   阈值 800，skipBlankLines + skipComments（空行、整行注释、块注释行不计）。
// 扫描范围：ohos/entry/src/main/ets/**/*.ets 与 scripts/**/*.mjs。
// 用法：
//   node scripts/check_file_lines.mjs          报告模式：列出违规清单，恒 exit 0
//   node scripts/check_file_lines.mjs --gate   门禁模式：有违规则 exit 1（供 build-hap.sh / CI 挂载）
//   node scripts/check_file_lines.mjs --all    附带输出全部文件行数排行（排查用）
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const MAX_LINES = 800;
const ROOT = new URL('..', import.meta.url).pathname;
const TARGETS = [
  { dir: join(ROOT, 'ohos/entry/src/main/ets'), ext: '.ets' },
  { dir: join(ROOT, 'scripts'), ext: '.mjs' },
];

function walk(dir, ext, out) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) {
      walk(p, ext, out);
    } else if (name.endsWith(ext)) {
      out.push(p);
    }
  }
  return out;
}

/** 有效行数：跳过空行；块注释跨行状态机；行尾注释不影响该行计数。 */
function effectiveLines(text) {
  const lines = text.split('\n');
  let count = 0;
  let inBlock = false;
  for (const raw of lines) {
    const line = raw.trim();
    if (inBlock) {
      const end = line.indexOf('*/');
      if (end >= 0) {
        inBlock = false;
        const rest = line.slice(end + 2).trim();
        if (rest.length > 0) {
          count++; // 块注释结束后本行仍有代码
        }
      }
      continue;
    }
    if (line.length === 0) {
      continue;
    }
    if (line.startsWith('//')) {
      continue;
    }
    if (line.startsWith('/*')) {
      const end = line.indexOf('*/');
      if (end < 0) {
        inBlock = true;
        continue;
      }
      const head = line.slice(end + 2).trim();
      if (head.length === 0) {
        continue; // 整行块注释
      }
      count++;
      continue;
    }
    count++;
  }
  return count;
}

const args = new Set(process.argv.slice(2));
const rows = [];
for (const t of TARGETS) {
  for (const f of walk(t.dir, t.ext, [])) {
    const text = readFileSync(f, 'utf8');
    rows.push({
      path: relative(ROOT, f),
      eff: effectiveLines(text),
      raw: text.split('\n').length,
    });
  }
}
rows.sort((a, b) => b.eff - a.eff);
const violations = rows.filter((r) => r.eff > MAX_LINES);

if (args.has('--all')) {
  for (const r of rows.slice(0, 40)) {
    console.log(`${String(r.eff).padStart(5)} 有效 / ${String(r.raw).padStart(5)} 原行  ${r.path}`);
  }
  console.log('---');
}
if (violations.length === 0) {
  console.log(`行数门禁通过：${rows.length} 个文件均 ≤${MAX_LINES} 有效行`);
  process.exit(0);
}
console.log(`行数门禁：${violations.length}/${rows.length} 个文件超 ${MAX_LINES} 有效行`);
for (const v of violations) {
  console.log(`  ${String(v.eff).padStart(5)} 有效行  ${v.path}`);
}
process.exit(args.has('--gate') ? 1 : 0);
