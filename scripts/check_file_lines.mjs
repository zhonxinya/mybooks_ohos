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
// UI 组件化临时豁免（计划#207，服务层已清零）：每页拆分并上板截图验收后**删除对应行**。
// 豁免理由：UI 组件提取属渲染改动，回归测不到「@Builder 值传递状态不刷新」类问题，
// 必须模拟器在线逐页截图确认（AGENTS.md），不允许盲拆合入。
const UI_ALLOWLIST = new Set([
  'ohos/entry/src/main/ets/pages/AdminPluginsPage.ets', // #1481
  'ohos/entry/src/main/ets/pages/BookDetailPage.ets', // #1482
  'ohos/entry/src/main/ets/pages/AdminScanPage.ets', // #1483
  'ohos/entry/src/main/ets/pages/AdminSettingsPage.ets', // #1483
  'ohos/entry/src/main/ets/pages/ReadKitReader.ets', // #1484
  'ohos/entry/src/main/ets/pages/BookSourceManagePage.ets', // #1484
  'ohos/entry/src/main/ets/pages/BookListDetailPage.ets', // #1484
  'ohos/entry/src/main/ets/pages/AiAssistantPage.ets', // #1480
  'ohos/entry/src/main/ets/pages/AdminOpdsPage.ets', // #1480
  'ohos/entry/src/main/ets/pages/AiSettingsPage.ets', // #1480
  'ohos/entry/src/main/ets/pages/NetworkLibraryPage.ets', // #1480
  'ohos/entry/src/main/ets/pages/BookUploadPage.ets', // #1480
  'ohos/entry/src/main/ets/pages/MimoTtsToolPage.ets', // #1480
  'ohos/entry/src/main/ets/pages/BooksTabPage.ets', // #1480
]);
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

// --selftest（批H，建议 #1836）：有效行口径样例自证（空行/整行注释/块注释跨行/尾随代码）
if (process.argv.includes('--selftest')) {
  const samples = [
    { text: ['', '// c', '/* a', 'b */', 'code'].join('\n'), want: 1, desc: '空行+行注释+块注释全跳过' },
    { text: '/* x */ code', want: 1, desc: '块注释后尾随代码计数' },
    { text: ['a', ' ', '  // b', 'c'].join('\n'), want: 2, desc: '有效代码行计数' },
    { text: ['/* a', 'b', 'c'].join('\n'), want: 0, desc: '未闭合块注释全跳过' },
    { text: 'const s = `// 反引号内 // 不算注释行`;', want: 1, desc: '行尾非注释不误跳' },
  ];
  let fails = 0;
  for (const s of samples) {
    const got = effectiveLines(s.text);
    if (got !== s.want) { fails++; console.log(`  [FAIL] ${s.desc}：期望 ${s.want}，实得 ${got}`); }
  }
  console.log(fails === 0 ? `行数门禁 selftest 通过（${samples.length}/${samples.length}）`
    : `行数门禁 selftest 失败 ${fails} 项`);
  process.exit(fails === 0 ? 0 : 1);
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
const over = rows.filter((r) => r.eff > MAX_LINES);
const violations = over.filter((r) => !UI_ALLOWLIST.has(r.path));
const allowed = over.filter((r) => UI_ALLOWLIST.has(r.path));
const stale = [...UI_ALLOWLIST].filter((p) => !over.some((r) => r.path === p));
if (stale.length > 0) {
  console.log('提示：以下豁免项已合规，请从 UI_ALLOWLIST 删除：');
  for (const p of stale) { console.log(`  ${p}`); }
}

if (args.has('--all')) {
  for (const r of rows.slice(0, 40)) {
    console.log(`${String(r.eff).padStart(5)} 有效 / ${String(r.raw).padStart(5)} 原行  ${r.path}`);
  }
  console.log('---');
}
if (violations.length === 0) {
  console.log(`行数门禁通过：${rows.length} 个文件均 ≤${MAX_LINES} 有效行` +
    (allowed.length > 0 ? `（UI 豁免 ${allowed.length} 项待拆，见 UI_ALLOWLIST 注释）` : ''));
  process.exit(0);
}
console.log(`行数门禁：${violations.length}/${rows.length} 个文件超 ${MAX_LINES} 有效行` +
  (allowed.length > 0 ? `（另有 UI 豁免 ${allowed.length} 项不计）` : ''));
for (const v of violations) {
  console.log(`  ${String(v.eff).padStart(5)} 有效行  ${v.path}`);
}
process.exit(args.has('--gate') ? 1 : 0);
