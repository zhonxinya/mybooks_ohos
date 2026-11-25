#!/usr/bin/env node
/**
 * ForEach keyGenerator 静态审计门禁（批K，建议 #1502/#1504 防回归）
 *
 * 背景：「聊天无反馈」bug 根因=AiAssistantPage ForEach 两参形态（默认 index 作 key），
 * @State 数组换引用后 key 不变→ListItem 复用→UI 永不刷新。离线回归全绿测不到渲染 diff。
 *
 * 判定：ForEach( 两参形态（无第三参 keyGenerator）且第一参为 this.<字段>，
 * 且该字段在本文件带 @State/@Prop/@Link/@ObjectLink 装饰=违规（可渲染态数组无 key）。
 * 常量数组、非状态字段（普通私有属性/方法返回值）、LazyForEach（IDataSource 通知机制）不判。
 *
 * 存量豁免（文件级）：给两参 @State ForEach 补 keyGenerator 属**渲染行为改动**，
 * 按 AGENTS 必须模拟器逐页截图验收，离线不得批量改——存量入列表，门禁只拦新增；
 * 每页上板补完 key 后删除对应行（豁免只减不增，同 check_file_lines.mjs UI_ALLOWLIST 策略）。
 *
 * 用法：node scripts/check_foreach_key.mjs [--gate|--selftest|仓库根]
 */
import { readdirSync, readFileSync, statSync } from 'fs';
import { join, posix } from 'path';

const args = process.argv.slice(2);
const GATE = args.includes('--gate');
const SELFTEST = args.includes('--selftest');
const ROOT = args.find((a) => !a.startsWith('--')) ?? new URL('..', import.meta.url).pathname;
const ETS = join(ROOT, 'ohos/entry/src/main/ets');
const DIRS = ['pages', 'components'];
const STATE_DECORATOR = /@(State|Prop|Link|ObjectLink)\b/;

// 存量豁免文件（相对 pages/components 的路径）。上板补 key 后逐行删除。
// 首跑摸排：全库当前违规=0（早期 grep 的「两参」命中全因 keyGenerator 尾参在后续行造成
// 行级假象，已用括号平衡解析+临时探针文件负向验证）。空清单=只拦新增。
const ALLOWLIST = new Set();

// 从 ForEach( 的开括号位置扫描实参区：按顶层逗号切参数，跳过嵌套括号/引号。
// 返回 { params: number, firstArg: string }；解析失败返回 null（宁漏报不误伤构建）。
function parseArgs(text, openParen) {
  let depth = 0, commas = 0, start = openParen + 1;
  let firstArg = '';
  let quote = null;
  for (let i = openParen; i < text.length; i++) {
    const ch = text[i];
    if (quote) {
      if (ch === '\\' && quote !== '`') i++;
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === "'" || ch === '"' || ch === '`') { quote = ch; continue; }
    if (ch === '(' || ch === '{' || ch === '[') {
      depth++;
      if (depth === 1 && i === openParen) continue;
      continue;
    }
    if (ch === ')' || ch === '}' || ch === ']') {
      depth--;
      if (ch === ')' && depth === 0) {
        const seg = text.slice(start, i);
        if (commas === 0) firstArg = seg;
        return { params: commas + 1, firstArg, tail: depth };
      }
      continue;
    }
    if (ch === ',' && depth === 1) {
      if (commas === 0) firstArg = text.slice(start, i);
      commas++;
      if (commas > 3) return null; // 异常形态，跳过
    }
    if (ch === '\n' && depth <= 1 && commas === 0 && i - start > 800) return null;
  }
  return null; // 未闭合，解析失败
}

function scanText(text) {
  const hits = [];
  let idx = -1;
  while ((idx = text.indexOf('ForEach(', idx + 1)) !== -1) {
    const prev = text[idx - 1];
    if (prev && /[A-Za-z]/.test(prev)) continue; // LazyForEach 不管
    const parsed = parseArgs(text, idx + 'ForEach'.length);
    if (!parsed) continue;
    if (parsed.params >= 3) continue; // 有 keyGenerator，放行
    const arr = parsed.firstArg.trim();
    const m = arr.match(/^this\.([A-Za-z_][A-Za-z0-9_]*)$/);
    if (!m) continue; // 字面量/表达式不在判定范围
    const fieldRe = new RegExp(`@[A-Za-z]+[^\\n]*\\b${m[1]}\\s*[:?!]`);
    const decl = text.split('\n').find(
      (line) => STATE_DECORATOR.test(line) && new RegExp(`\\b${m[1]}\\b`).test(line));
    if (decl) {
      const lineNo = text.slice(0, idx).split('\n').length;
      hits.push({ line: lineNo, field: `this.${m[1]}`, decl: decl.trim().slice(0, 80), fieldRe });
    }
  }
  return hits;
}

if (SELFTEST) {
  const bad = '  @State items: Foo[] = [];\n  build() {\n    ForEach(this.items, (it: Foo) => {\n      Text(it.name)\n    })\n  }\n';
  const okKey = '  @State items: Foo[] = [];\n  build() {\n    ForEach(this.items, (it: Foo) => {\n      Text(it.name)\n    }, (it: Foo) => it.id)\n  }\n';
  const okConst = '  build() {\n    ForEach(["a", "b"], (s: string) => {\n      Text(s)\n    })\n  }\n';
  const okLazy = '  LazyForEach(this.source, (it: Foo) => {\n    Text(it.name)\n  })\n';
  const okPlain = '  private items: Foo[] = [];\n  build() {\n    ForEach(this.items, (it: Foo) => {\n      Text(it.name)\n    })\n  }\n';
  const samples = [
    { text: bad, want: 1, desc: '两参 @State 数组命中' },
    { text: okKey, want: 0, desc: '带 keyGenerator 放行' },
    { text: okConst, want: 0, desc: '字面量数组放行' },
    { text: okLazy, want: 0, desc: 'LazyForEach 不管' },
    { text: okPlain, want: 0, desc: '非状态字段放行' },
  ];
  let fails = 0;
  for (const s of samples) {
    const got = scanText(s.text).length;
    if (got !== s.want) { fails++; console.log(`  [FAIL] ${s.desc}：期望 ${s.want}，实得 ${got}`); }
  }
  console.log(fails === 0 ? `ForEach key 门禁 selftest 通过（${samples.length}/${samples.length}）`
    : `ForEach key 门禁 selftest 失败 ${fails} 项`);
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
    const rel = posix.relative(join(ETS, d), f);
    if (ALLOWLIST.has(rel)) continue;
    for (const h of scanText(readFileSync(f, 'utf8'))) {
      hits.push(`${posix.relative(ETS, f)}:${h.line}: ForEach(this.${h.field.split('.')[1]}) 两参无 keyGenerator（状态数组 ${h.decl}）`);
    }
  }
}

console.log(`ForEach keyGenerator 审计：新增违规 ${hits.length} 处（存量豁免 ${ALLOWLIST.size} 文件）`);
for (const h of hits) console.log(`  ${h}`);
if (hits.length > 0 && GATE) {
  console.error('错误：@State/@Prop/@Link 数组的 ForEach 必须带 keyGenerator（覆盖全部渲染态字段），否则换引用后 ListItem 复用不刷新（#1502 聊天无反馈根因）。存量清单见脚本 ALLOWLIST。');
  process.exit(1);
}
