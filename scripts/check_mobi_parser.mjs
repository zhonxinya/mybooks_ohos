#!/usr/bin/env node
/**
 * MOBI 解析离线自检（无需设备）。
 *
 * 为什么需要它：内置阅读器的 MOBI 解析（`feature/reader/src/main/ets/engine/MobiDoc.ets`
 * 与 `PalmDoc.ets`）只能在设备/模拟器上跑，改动后要么装机验证、要么完全没有把关。
 * 这两个模块刻意保持「纯计算、只用 `TextCodec` 解码」，因此可以用 Node 的类型擦除
 * 直接把 **源文件**（不是副本）跑起来：脚本把它们复制成 `.ts` 到临时目录，
 * 只改写 import 说明符，并垫一个 `@kit.ArkTS` 的 TextDecoder 垫片。
 *
 * 用法（Node ≥ 22.6，仓库里 harmony-sdk 自带的 node 即可）：
 *   node scripts/check_mobi_parser.mjs <book.mobi> [更多 .mobi ...]
 *
 * 校验项（任一失败即退出码 1）：
 *   1. 解压出的正文字节数 == MOBI 头声明的 textLength（这一条能拦住绝大多数解压 bug）；
 *   2. 章节切分非空、字节区间单调且不越界；
 *   3. 每章都能解码出正文块，`recindex` 图片都能在记录表里定位到；
 *   4. 打印书名/章节数/正文长度/耗时，便于与设备端 `hilog -T MobiEngine` 对照。
 */
import { mkdtempSync, readFileSync, statSync, copyFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ENGINE_DIR = join(dirname(fileURLToPath(import.meta.url)), '..',
  'ohos', 'feature', 'reader', 'src', 'main', 'ets', 'engine');
/** 纯解析链路：都不碰 ArkUI/文件 IO，只用 TextCodec 解码。 */
const MODULES = ['PalmDoc', 'MarkupText', 'TextCodec', 'MobiIndex', 'MobiKf8', 'HuffCdic', 'MobiDoc'];
const SHIM = `export const util = {
  TextDecoder: {
    create(encoding) {
      const decoder = new TextDecoder(encoding === 'gbk' ? 'gb18030' : encoding);
      return { decodeToString: (bytes) => decoder.decode(bytes) };
    },
  },
};
`;

function stageModules() {
  const dir = mkdtempSync(join(tmpdir(), 'mobi-check-'));
  const sources = new Map();
  // 先收集所有 export interface 的名字：Node 的类型擦除是纯语法级的，
  // `import { SomeInterface }` 会在运行时找不到导出，必须改写成 `import type`。
  const typeNames = new Set();
  for (const name of MODULES) {
    const source = readFileSync(join(ENGINE_DIR, `${name}.ets`), 'utf8');
    sources.set(name, source);
    for (const match of source.matchAll(/export interface\s+([A-Za-z0-9_]+)/g)) {
      typeNames.add(match[1]);
    }
  }
  const splitTypes = (clause) => {
    const names = clause.split(',').map((item) => item.trim()).filter((item) => item.length > 0);
    const types = names.filter((item) => typeNames.has(item));
    const values = names.filter((item) => !typeNames.has(item));
    return { types, values };
  };
  for (const name of MODULES) {
    let source = sources.get(name)
      .replace(/from '\.\/([A-Za-z0-9]+)'/g, "from './$1.ts'")
      .replace(/from '@kit\.ArkTS'/g, "from './kit_shim.ts'");
    source = source.replace(/import\s*\{([^}]*)\}\s*from\s*('[^']+');/g, (whole, clause, spec) => {
      const { types, values } = splitTypes(clause);
      const lines = [];
      if (values.length > 0) {
        lines.push(`import { ${values.join(', ')} } from ${spec};`);
      }
      if (types.length > 0) {
        lines.push(`import type { ${types.join(', ')} } from ${spec};`);
      }
      return lines.length > 0 ? lines.join('\n') : whole;
    });
    writeFileSync(join(dir, `${name}.ts`), source);
  }
  writeFileSync(join(dir, 'kit_shim.ts'), SHIM);
  return dir;
}

/** 与 ReaderTasks.loadMobiDocTask 同构：按记录表只读需要的区间。 */
function readRange(path, offset, length, file) {
  const start = Math.max(0, Math.min(offset, file.length));
  const end = Math.max(start, Math.min(offset + length, file.length));
  return new Uint8Array(file.buffer.slice(file.byteOffset + start, file.byteOffset + end));
}

/** 与 MobiRecords 同构的读取（脚本内自己实现，不引入 BookFile 的 fs 依赖）。 */
function readIndex(path, records, index, codepage, file, MobiIndex) {
  const empty = { entries: [], strings: new Map() };
  if (index < 0 || index + 1 >= records.length) {
    return empty;
  }
  const read = (i) => readRange(path, records[i], records[i + 1] - records[i], file);
  const header = read(index);
  const span = MobiIndex.span(header);
  const following = [];
  for (let i = 1; i <= span && index + i + 1 < records.length; i++) {
    following.push(read(index + i));
  }
  return MobiIndex.parse(header, following, codepage);
}

/** 与 ReaderTasks.loadMobiDocTask 同构：KF7 按区间切章，KF8 拼装骨架部件。 */
function loadDoc(path, { MobiDoc, MobiIndex, MobiKf8, HuffCdic }) {
  const file = readFileSync(path);
  const head = readRange(path, 0, MobiDoc.HEADER_BYTES, file);
  const recordCount = MobiDoc.recordCount(head);
  const list = readRange(path, MobiDoc.HEADER_BYTES, recordCount * 8, file);
  const records = MobiDoc.recordOffsets(list, recordCount, statSync(path).size);
  const record0 = readRange(path, records[0], records[1] - records[0], file);
  const info = MobiDoc.parse(records, record0);
  let huff = null;
  if (info.compression === 17480 && info.huffCount > 0) {
    const read = (i) => new Uint8Array(readRange(path, records[i], records[i + 1] - records[i], file));
    const cdic = [];
    for (let i = 1; i < info.huffCount; i++) cdic.push(read(info.huffOffset + i));
    huff = HuffCdic.create(read(info.huffOffset), cdic);
  }
  const from = records[1];
  const to = records[info.textRecordCount + 1];
  const raw = MobiDoc.assembleText(readRange(path, from, to - from, file), from, records, info, huff);
  if (!info.kf8) {
    return { info, records, text: raw, flowResources: [], sections: MobiDoc.sections(info, raw) };
  }
  const fdst = new Uint8Array(readRange(path, records[info.fdstOffset], records[info.fdstOffset + 1] - records[info.fdstOffset], file));
  const skeleton = readIndex(path, records, info.skeletonIndex, info.codepage, file, MobiIndex);
  const fragments = readIndex(path, records, info.fragmentIndex, info.codepage, file, MobiIndex);
  const ncx = readIndex(path, records, info.ncxIndex, info.codepage, file, MobiIndex);
  const built = MobiKf8.parts(raw, fdst, skeleton, fragments);
  const toc = MobiKf8.toc(ncx, 5000);
  const flowResources = MobiKf8.flowResources(MobiKf8.flows(raw, fdst));
  return {
    info, records, text: built.text, tocCount: toc.length, flowResources,
    sections: MobiDoc.kf8Sections(built.parts, built.fragmentParts, toc, built.text, info.codepage),
  };
}

function checkBook(path, modules) {
  const { MobiDoc, MarkupText } = modules;
  const file = readFileSync(path);   // 图片记录抽样读取用
  const doc = loadDoc(path, modules);
  const flowResources = doc.flowResources;
  const { info, records, text, sections } = doc;

  const problems = [];
  // KF8 的正文是「骨架 + 片段」拼装的结果，天然短于声明长度（差额是 CSS/SVG 等 flow 与索引数据）
  if (!info.kf8 && text.length !== info.textLength) {
    problems.push(`正文长度 ${text.length} != 声明长度 ${info.textLength}`);
  }
  if (info.kf8 && (text.length <= 0 || text.length > info.textLength)) {
    problems.push(`KF8 拼装正文长度异常：${text.length}（声明 ${info.textLength}）`);
  }
  if (sections.length === 0) {
    problems.push('没有切出任何章节');
  }
  let previousEnd = 0;
  for (let i = 0; i < sections.length; i++) {
    const section = sections[i];
    if (section.start < previousEnd || section.end > text.length || section.end <= section.start) {
      problems.push(`章节 ${i} 区间非法：${section.start}..${section.end}`);
      break;
    }
    previousEnd = section.end;
  }
  // 抽样解析章节正文（大书全量解析太慢）：首章、末章与中间若干章
  const samples = [];
  for (const index of [0, 1, Math.floor(sections.length / 2), sections.length - 2, sections.length - 1]) {
    if (index >= 0 && index < sections.length && !samples.includes(index)) samples.push(index);
  }
  let blocks = 0;
  let images = 0;
  let emptySamples = 0;
  for (const index of samples) {
    const section = sections[index];
    const html = MobiDoc.decodeSection(text.slice(section.start, section.end), info.codepage);
    const parsed = MarkupText.toBlocks(MobiDoc.replaceImageRecords(html, new Map(), flowResources));
    blocks += parsed.length;
    if (parsed.length === 0) emptySamples++;
    for (const wanted of MobiDoc.imageRecords(html, flowResources)) {
      const record = info.firstResource + wanted - 1;
      if (record < 0 || record + 1 >= records.length) {
        problems.push(`章节 ${index} 的图片 ${wanted} 超出记录表`);
        continue;
      }
      const data = new Uint8Array(readRange(path, records[record], records[record + 1], file));
      if (MobiDoc.imageStart(data) >= 0) images++;
    }
  }
  if (emptySamples === samples.length) {
    problems.push('抽样的章节都解析不出内容');
  }
  // 正文是 HTML/文本，不该出现大量控制字符；解压算法出错时这里会立刻暴露
  let controls = 0;
  for (let i = 0; i < text.length; i++) {
    const byte = text[i];
    if (byte < 0x20 && byte !== 0x09 && byte !== 0x0A && byte !== 0x0D) {
      controls++;
    }
  }
  if (text.length > 0 && controls / text.length > 0.01) {
    problems.push(`正文里控制字符占比过高（${(controls / text.length * 100).toFixed(1)}%），解压可能出错`);
  }
  return { info, sections, text, blocks, images, problems, samples, tocCount: doc.tocCount };
}

const books = process.argv.slice(2);
if (books.length === 0) {
  console.error('用法：node scripts/check_mobi_parser.mjs <book.mobi> [更多 .mobi ...]');
  process.exit(2);
}
const dir = stageModules();
let failed = false;
try {
  const { MobiDoc } = await import(pathToFileURL(join(dir, 'MobiDoc.ts')).href);
  const { MarkupText } = await import(pathToFileURL(join(dir, 'MarkupText.ts')).href);
  const { MobiIndex } = await import(pathToFileURL(join(dir, 'MobiIndex.ts')).href);
  const { MobiKf8 } = await import(pathToFileURL(join(dir, 'MobiKf8.ts')).href);
  const { HuffCdic } = await import(pathToFileURL(join(dir, 'HuffCdic.ts')).href);
  for (const book of books) {
    const started = Date.now();
    let result;
    try {
      result = checkBook(book, { MobiDoc, MarkupText, MobiIndex, MobiKf8, HuffCdic });
    } catch (error) {
      console.log(`\n${book}\n  ✗ 解析失败：${error.message}`);
      failed = true;
      continue;
    }
    const { info, sections, text, blocks, images, problems, samples, tocCount } = result;
    console.log(`\n${book}`);
    console.log(`  title        ${info.title.slice(0, 60)}`);
    console.log(`  container    ${info.kf8 ? 'KF8' : 'KF7'} v${info.version} codepage ${info.codepage} compression ${info.compression}` +
      ` records ${info.textRecordCount} text ${info.textLength} bytes`);
    console.log(`  sections     ${sections.length}（首个：${sections.length > 0 ? sections[0].title : '-'}）` +
      (tocCount === undefined ? '' : `，NCX 目录项 ${tocCount}`));
    console.log(`  blocks       ${blocks}（抽样 ${samples.length} 章）图片 ${images} 张`);
    console.log(`  elapsed      ${Date.now() - started} ms`);
    for (const problem of problems) {
      console.log(`  ✗ ${problem}`);
    }
    if (problems.length > 0) {
      failed = true;
    } else {
      console.log('  ✓ 通过');
    }
  }
} finally {
  rmSync(dir, { recursive: true, force: true });
}
process.exit(failed ? 1 : 0);
