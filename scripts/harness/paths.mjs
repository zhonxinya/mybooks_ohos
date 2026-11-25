// harness 共享路径与真实源码读取（拆分自 check_ai_assistant.mjs）
import { mkdtempSync, readFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), '../..');
export const ETS = join(ROOT, 'ohos/entry/src/main/ets');
const TMP = process.env.TMPDIR || '/vol3/1000/Public/Share/.tmp';
mkdirSync(TMP, { recursive: true });
export const dir = mkdtempSync(join(TMP, 'ai-check-'));
// #1827 批E：staging 目录平铺，'../utils/ErrorFormat' 会逃逸出 dir；统一改写为桩内 ErrorFormat.ts
export const read = (path) => readFileSync(join(ETS, path), 'utf8')
  .replace(/'\.\.\/utils\/ErrorFormat'/g, `'./ErrorFormat.ts'`);
