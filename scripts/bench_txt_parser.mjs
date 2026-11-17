#!/usr/bin/env node
/**
 * TXT 首次开书（无 .idx 缓存）的离线基准：不需要设备。
 *
 * 与 check_mobi_parser.mjs 同套路：把 TxtParser.ets / TextCodec.ets 源文件复制成 .ts
 * 到临时目录做类型擦除，BookFile 换成 Node fs 垫片，然后在合成小说上跑 `TxtParser.index`。
 *
 * 用法：node scripts/bench_txt_parser.mjs [章节数=300] [每章段落=30]
 */
import { mkdtempSync, readFileSync, writeFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ENGINE_DIR = process.env.TXT_ENGINE_DIR ??
  join(dirname(fileURLToPath(import.meta.url)), '..',
    'ohos', 'feature', 'reader', 'src', 'main', 'ets', 'engine');
const MODULES = ['TxtParser', 'TextCodec', 'GbkTable'];

const KIT_SHIM = `export const util = {
  TextDecoder: {
    create(encoding, options) {
      const decoder = new TextDecoder(encoding === 'gbk' ? 'gb18030' : encoding,
        options && options.fatal ? { fatal: true } : undefined);
      return { decodeToString: (bytes) => decoder.decode(bytes) };
    },
  },
  Base64Helper: class { decodeSync(s) { return new Uint8Array(Buffer.from(s, 'base64')); } },
};
`;
const HILOG_SHIM = `export const hilog = { warn: () => {}, info: () => {}, error: () => {} };
export const BusinessError = class extends Error {};
`;
const BOOKFILE_SHIM = `import * as fs from 'node:fs';
export class BookFile {
  static exists(p) { try { fs.statSync(p); return true; } catch { return false; } }
  static size(p) { try { return fs.statSync(p).size; } catch { return 0; } }
  static modifiedTime(p) { try { return Math.floor(Number(fs.statSync(p).mtime)); } catch { return 0; } }
  static readRange(p, offset, length) {
    const total = BookFile.size(p);
    const start = Math.max(0, Math.min(offset, total));
    const end = Math.max(start, Math.min(offset + length, total));
    const buffer = new ArrayBuffer(Math.max(0, end - start));
    if (end > start) {
      const fd = fs.openSync(p, 'r');
      fs.readSync(fd, new Uint8Array(buffer), 0, end - start, start);
      fs.closeSync(fd);
    }
    return buffer;
  }
  static readText(p) { return new TextDecoder().decode(fs.readFileSync(p)); }
  static writeBytes(p, data) { fs.writeFileSync(p, new Uint8Array(data)); }
  static ensureDir(p) { fs.mkdirSync(p, { recursive: true }); }
  static dirName(p) { const i = p.lastIndexOf('/'); return i < 0 ? '' : p.substring(0, i); }
}
`;

function stageModules() {
  const dir = mkdtempSync(join(tmpdir(), 'txt-bench-'));
  const typeNames = new Set();
  const sources = new Map();
  for (const name of MODULES) {
    const source = readFileSync(join(ENGINE_DIR, `${name}.ets`), 'utf8');
    sources.set(name, source);
    for (const m of source.matchAll(/export interface\s+([A-Za-z0-9_]+)/g)) typeNames.add(m[1]);
  }
  for (const name of MODULES) {
    let source = sources.get(name)
      .replace(/from '\.\/([A-Za-z0-9]+)'/g, "from './$1.ts'")
      .replace(/from '@kit\.ArkTS'/g, "from './kit_shim.ts'")
      .replace(/from '@kit\.PerformanceAnalysisKit'/g, "from './hilog_shim.ts'");
    source = source.replace(/import\s*\{([^}]*)\}\s*from\s*('[^']+');/g, (whole, clause, spec) => {
      const names = clause.split(',').map((s) => s.trim()).filter(Boolean);
      const types = names.filter((n) => typeNames.has(n));
      const values = names.filter((n) => !typeNames.has(n));
      const lines = [];
      if (values.length) lines.push(`import { ${values.join(', ')} } from ${spec};`);
      if (types.length) lines.push(`import type { ${types.join(', ')} } from ${spec};`);
      return lines.length ? lines.join('\n') : whole;
    });
    writeFileSync(join(dir, `${name}.ts`), source);
  }
  writeFileSync(join(dir, 'kit_shim.ts'), KIT_SHIM);
  writeFileSync(join(dir, 'hilog_shim.ts'), HILOG_SHIM);
  writeFileSync(join(dir, 'BookFile.ts'), BOOKFILE_SHIM);
  return dir;
}

const POOL = '的一是了我不人在他有这个上们来到时大地为子中你说生国年着就那和要她出也得里后自以会家可下而过天去能对小多然于心学么之都好看起发当没成只如事把还用第样道想作种开美总从无情己面最女但现前些所同日手又行意动方期它头经长儿回位分爱老因很给名法间斯知世什两次使身者被高已亲其进此话常与活正感';
const CJK = Array.from(POOL);
/** 固定种子：两次运行（改前/改后）必须切出完全相同的章界，才能对比哈希。 */
let seed = 20261026;
function rand(n) {
  seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
  return seed % n;
}
function sentence(len) { let s = ''; for (let i = 0; i < len; i++) s += CJK[rand(CJK.length)]; return s; }

function makeBook(chapters, perChapter, crlf) {
  const nl = crlf ? '\r\n' : '\n';
  let out = '';
  out += `书名：测试小说${nl}作者：无名${nl}${nl}`;
  for (let c = 1; c <= chapters; c++) {
    out += `第${c}章 ${sentence(6)}${nl}${nl}`;
    for (let p = 0; p < perChapter; p++) out += `　　${sentence(38)}。${nl}`;
    out += nl;
  }
  return out;
}

/** GBK 兜底解码（Android 路径）基准：内置表编码 → decodeGbk vs ICU(gb18030) 对照。 */
function benchGbk(TextCodec, chapters, perChapter) {
  const table = TextCodec.gbkTable();
  const reverse = new Map();
  for (let lead = 0x81; lead <= 0xFE; lead++) {
    for (let trail = 0x40; trail <= 0xFE; trail++) {
      if (trail === 0x7F) continue;
      const index = 1 + (lead - 0x81) * 190 + (trail < 0x7F ? trail - 0x40 : trail - 0x41);
      const code = table[index * 2] | (table[index * 2 + 1] << 8);
      if (code !== 0 && !reverse.has(code)) reverse.set(code, [lead, trail]);
    }
  }
  const text = makeBook(chapters, perChapter, false);
  const bytes = [];
  let missing = 0;
  for (const ch of text) {
    const code = ch.codePointAt(0);
    if (code < 0x80) { bytes.push(code); continue; }
    const pair = reverse.get(code);
    if (pair === undefined) { missing++; bytes.push(0x3F); continue; }
    bytes.push(pair[0], pair[1]);
  }
  const buf = Uint8Array.from(bytes);
  console.log(`GBK 样本 ${(buf.length / 1048576).toFixed(1)} MB，缺字 ${missing}`);
  const icu = new TextDecoder('gb18030');
  let t = performance.now();
  const expect = icu.decode(buf);
  console.log(`  ICU(gb18030) ${(performance.now() - t).toFixed(0)}ms`);
  t = performance.now();
  const got = TextCodec.decodeGbk(buf);
  console.log(`  decodeGbk(内置表) ${(performance.now() - t).toFixed(0)}ms`);
  console.log(`  与 ICU 一致：${got === expect}${got === expect ? '' : `（首个差异 @${firstDiff(got, expect)}）`}`);
}

function firstDiff(a, b) {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) if (a.charCodeAt(i) !== b.charCodeAt(i)) return i;
  return n;
}

async function main() {
  const gbkMode = process.argv[2] === 'gbk';
  const chapters = Number(gbkMode ? 1000 : (process.argv[2] ?? 300));
  const perChapter = Number(process.argv[3] ?? 30);
  const dir = stageModules();
  const { TxtParser } = await import(pathToFileURL(join(dir, 'TxtParser.ts')).href);
  const { TextCodec } = await import(pathToFileURL(join(dir, 'TextCodec.ts')).href);

  if (process.argv[2] === 'gbk') return benchGbk(TextCodec, chapters, perChapter);

  const work = mkdtempSync(join(tmpdir(), 'txt-bench-book-'));
  const src = join(work, 'book.txt');
  const cache = join(work, 'book.utf8');
  const text0 = makeBook(chapters, perChapter, true);
  writeFileSync(src, text0);
  const sizeMB = (statSync(src).size / 1048576).toFixed(1);
  console.log(`源文件 ${sizeMB} MB，${chapters} 章（CRLF）`);
  try {
    const t0 = performance.now();
    const index = TxtParser.index(src, cache);
    const total = performance.now() - t0;
    console.log(`index 总耗时 ${total.toFixed(0)} ms，章数 ${index.chapters.length}`);
    // 分阶段（私有方法在运行时仍可访问）
    const bytes = (await import('node:fs')).readFileSync(src);
    const t1 = performance.now();
    let text = TextCodec.decode(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length));
    const tDecode = performance.now() - t1;
    const t2 = performance.now();
    text = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    const tCR = performance.now() - t2;
    const t3 = performance.now();
    const sections = TxtParser.splitChapters(text);
    const tSplit = performance.now() - t3;
    const t4 = performance.now();
    const spans = TxtParser.writeCache(cache, text, sections);
    const tWrite = performance.now() - t4;
    console.log(`  decode ${tDecode.toFixed(0)}ms | CRLF ${tCR.toFixed(0)}ms | split ${tSplit.toFixed(0)}ms | write ${tWrite.toFixed(0)}ms`);
    const u8 = new Uint8Array(bytes);
    let t = performance.now();
    TextCodec.isUtf8(u8);
    const tUtf8Check = performance.now() - t;
    t = performance.now();
    TextCodec.decodeAs(u8, 'utf-8');
    const tIcu = performance.now() - t;
    console.log(`  ├ isUtf8 ${tUtf8Check.toFixed(0)}ms | ICU utf-8 ${tIcu.toFixed(0)}ms`);
    console.log(`  spans ${spans.length}，首章「${spans[0].title}」 末章「${spans[spans.length - 1].title}」`);
    console.log(`  章界哈希 ${spans.map((s) => s.byteEnd).reduce((a, b) => (a * 31 + b) % 1000000007, 0)}`);
    const cacheBytes = (await import('node:fs')).readFileSync(cache);
    let cacheHash = 0;
    for (let i = 0; i < cacheBytes.length; i++) cacheHash = (cacheHash * 31 + cacheBytes[i]) % 1000000007;
    console.log(`  缓存字节 ${cacheBytes.length}，内容哈希 ${cacheHash}`);
    // 二次打开走 .idx
    const t5 = performance.now();
    const again = TxtParser.index(src, cache);
    console.log(`二次 index（命中缓存）${(performance.now() - t5).toFixed(1)} ms，章数 ${again.chapters.length}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(work, { recursive: true, force: true });
  }
}

main();
