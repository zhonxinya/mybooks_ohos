#!/usr/bin/env node
/**
 * 门禁自测 runner（批H，建议 #1836）
 *
 * 依次跑七个 check_*.mjs 的 --selftest（内嵌负向/豁免样例），证明门禁正则
 * 本身仍按设计命中/放行——批G 的状态色门禁首版豁免正则太窄误报 8 处，
 * 全靠手工临时注入才暴露；固化成每次构建前自动跑。
 *
 * 用法：node scripts/gates_selftest.mjs   // 任一失败 exit 1
 */
import { spawnSync } from 'child_process';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const SCRIPTS = dirname(fileURLToPath(import.meta.url));
const GATES = [
  'check_file_lines.mjs',
  'check_error_toast.mjs',
  'check_sync_io.mjs',
  'check_hardcoded_status_color.mjs',
  'check_foreach_key.mjs',
  'check_routes.mjs',
  'check_flush_promise.mjs',
];

let fails = 0;
for (const g of GATES) {
  const r = spawnSync(process.execPath, [join(SCRIPTS, g), '--selftest'], { encoding: 'utf8' });
  const out = (r.stdout || '').trim() + (r.stderr ? `\n${r.stderr.trim()}` : '');
  if (r.status === 0) {
    console.log(out.split('\n').pop());
  } else {
    fails++;
    console.log(out);
  }
}
console.log(fails === 0 ? `门禁 selftest 全部通过（${GATES.length}/${GATES.length}）`
  : `门禁 selftest 失败 ${fails} 个`);
process.exit(fails === 0 ? 0 : 1);
