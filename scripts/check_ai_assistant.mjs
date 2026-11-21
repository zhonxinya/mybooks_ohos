#!/usr/bin/env node
/**
 * AI 助手离线回归（Node >= 22.6）：运行实际 ArkTS 服务和页面逻辑，不连接设备或模型。
 * 页面仅移除 ArkUI 声明式 build 部分、将 @State 擦为普通字段；SDK / 存储 / 剪贴板以本地桩替代。
 * 本文件只做编排：环境层在 harness/base.mjs（+paths/stages），用例按域拆在 harness/cases_1..8.mjs。
 * 用法：node scripts/check_ai_assistant.mjs
 */
import { rmSync } from 'node:fs';
import { dir } from './harness/paths.mjs';
import { cases, writeStubs, setup } from './harness/base.mjs';

async function main() {
  writeStubs();
  const ctx = await setup();
  for (let i = 1; i <= 8; i++) {
    (await import(`./harness/cases_${i}.mjs`)).register(ctx);
  }
  let failures = 0;
  for (const { name, run } of cases) {
    try {
      await run();
      console.log(`PASS ${name}`);
    } catch (error) {
      failures++;
      console.error(`FAIL ${name}\n${error.stack}`);
    }
  }
  console.log(`\n${cases.length - failures}/${cases.length} 通过`);
  process.exitCode = failures > 0 ? 1 : 0;
}
try {
  await main();
} finally {
  delete globalThis.__aiCheck;
  rmSync(dir, { recursive: true, force: true });
}
