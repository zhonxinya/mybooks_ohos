#!/usr/bin/env node
/**
 * 同步大文件 I/O 门禁（批G，#1677 防回归）
 *
 * UI 层（pages/components）禁止 fs.readSync / fs.writeSync / fs.copyFileSync：
 * 这三者按 MB 级数据整读整写，在 UI 线程同步执行会卡帧（批F 实测每 4MB 块 10-40ms）。
 * mkdirSync/accessSync/statSync 等元数据操作开销在 µs 级，不在禁止范围。
 *
 * 豁免（文件级，附原因）：
 *  - ReadKitReader.ets：自定义字体 loadFileFromPath 被 native 同步回调链消费，
 *    改异步需动 native 契约（台账 #1677 判定项）。
 *
 * 用法：node scripts/check_sync_io.mjs --gate   // 违规 exit 1
 */
import { readdirSync, readFileSync, statSync } from 'fs';
import { join, posix } from 'path';

const GATE = process.argv.includes('--gate');
const ROOT = process.argv.slice(2).find((a) => !a.startsWith('--')) ??
  new URL('..', import.meta.url).pathname;
const ETS = join(ROOT, 'ohos/entry/src/main/ets');
const DIRS = ['pages', 'components'];
const ALLOW = new Set(['ReadKitReader.ets']);
const RE = /fs\.(readSync|writeSync|copyFileSync)\s*\(/;

// --selftest（批H，建议 #1836）：负向/放行样例自证正则灵敏度
if (process.argv.includes('--selftest')) {
  const samples = [
    { line: 'const n = fs.readSync(file.fd, buf, 0, buf.byteLength);', want: true, desc: 'readSync 命中' },
    { line: 'fs.writeSync(file.fd, data);', want: true, desc: 'writeSync 命中' },
    { line: 'fs.copyFileSync(uri, dest);', want: true, desc: 'copyFileSync 命中' },
    { line: 'await fs.read(fd, buf, { length: n });', want: false, desc: '异步 read 放行' },
    { line: 'fs.statSync(dir);', want: false, desc: '元数据 statSync 放行' },
    { line: 'fs.mkdirSync(dir, { recursive: true });', want: false, desc: '元数据 mkdirSync 放行' },
  ];
  let fails = 0;
  for (const s of samples) {
    if (RE.test(s.line) !== s.want) { fails++; console.log(`  [FAIL] ${s.desc}（期望${s.want ? '命中' : '放行'}）`); }
  }
  console.log(fails === 0 ? `同步 I/O 门禁 selftest 通过（${samples.length}/${samples.length}）`
    : `同步 I/O 门禁 selftest 失败 ${fails} 项`);
  process.exit(fails === 0 ? 0 : 1);
}

const hits = [];
for (const d of DIRS) {
  const dir = join(ETS, d);
  for (const name of readdirSync(dir)) {
    if (!name.endsWith('.ets') || ALLOW.has(name)) continue;
    const lines = readFileSync(join(dir, name), 'utf8').split('\n');
    lines.forEach((line, i) => {
      if (RE.test(line)) hits.push(`${posix.relative(ETS, join(dir, name))}:${i + 1}: ${line.trim().slice(0, 90)}`);
    });
  }
}

console.log(`同步大文件 I/O 门禁：命中 ${hits.length} 处`);
for (const h of hits) console.log(`  ${h}`);
if (hits.length > 0 && GATE) {
  console.error('错误：UI 层禁止 fs.readSync/writeSync/copyFileSync（MB 级同步读写卡 UI 线程），改 fs 异步 API。');
  process.exit(1);
}
