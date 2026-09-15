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
/** 纯解析链路：都不碰 ArkUI，只用 TextCodec 解码。 */
const MODULES = ['PalmDoc', 'MarkupText', 'TextCodec', 'MobiDoc'];
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
  for (const name of MODULES) {
    const source = readFileSync(join(ENGINE_DIR, `${name}.ets`), 'utf8')
      .replace(/from '\.\/([A-Za-z]+)'/g, "from './$1.ts'")
      .replace(/from '@kit\.ArkTS'/g, "from './kit_shim.ts'");
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

function checkBook(path, MobiDoc, MarkupText) {
  const file = readFileSync(path);
  const head = readRange(path, 0, MobiDoc.HEADER_BYTES, file);
  const recordCount = MobiDoc.recordCount(head);
  const list = readRange(path, MobiDoc.HEADER_BYTES, recordCount * 8, file);
  const records = MobiDoc.recordOffsets(list, recordCount, statSync(path).size);
  const record0 = readRange(path, records[0], records[1] - records[0], file);
  const info = MobiDoc.parse(records, record0);
  const from = records[1];
  const to = records[info.textRecordCount + 1];
  const text = MobiDoc.assembleText(readRange(path, from, to - from, file), from, records, info);
  const sections = MobiDoc.sections(info, text);

  const problems = [];
  if (text.length !== info.textLength) {
    problems.push(`正文长度 ${text.length} != 声明长度 ${info.textLength}`);
  }
  if (sections.length === 0) {
    problems.push('没有切出任何章节');
  }
  let previousEnd = 0;
  let blocks = 0;
  let images = 0;
  for (let i = 0; i < sections.length; i++) {
    const section = sections[i];
    if (section.start < previousEnd || section.end > text.length || section.end <= section.start) {
      problems.push(`章节 ${i} 区间非法：${section.start}..${section.end}`);
      break;
    }
    previousEnd = section.end;
    const html = MobiDoc.decodeSection(text.slice(section.start, section.end), info.codepage);
    const parsed = MarkupText.toBlocks(MobiDoc.replaceImageRecords(html, new Map()));
    blocks += parsed.length;
    const wanted = MobiDoc.imageRecords(html);
    for (const recindex of wanted) {
      const record = info.firstResource + recindex - 1;
      if (record < 0 || record + 1 >= records.length) {
        problems.push(`章节 ${i} 的图片 recindex=${recindex} 超出记录表`);
        continue;
      }
      const data = new Uint8Array(readRange(path, records[record], records[record + 1], file));
      if (MobiDoc.imageStart(data) < 0) {
        // FLIS/FCIS 等尾部记录会被 recindex 误指，属于可容忍情形，只计数提示
        continue;
      }
      images++;
    }
  }
  return { info, sections, text, blocks, images, problems };
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
  for (const book of books) {
    const started = Date.now();
    let result;
    try {
      result = checkBook(book, MobiDoc, MarkupText);
    } catch (error) {
      console.log(`\n${book}\n  ✗ 解析失败：${error.message}`);
      failed = true;
      continue;
    }
    const { info, sections, text, blocks, images, problems } = result;
    console.log(`\n${book}`);
    console.log(`  title        ${info.title.slice(0, 60)}`);
    console.log(`  container    KF7 v${info.version} codepage ${info.codepage} compression ${info.compression}` +
      ` records ${info.textRecordCount} text ${info.textLength} bytes`);
    console.log(`  sections     ${sections.length}（首个：${sections[0].title}）`);
    console.log(`  blocks       ${blocks} 图片 ${images} 张`);
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
