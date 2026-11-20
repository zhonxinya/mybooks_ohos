# 工具回路优化：同轮并行 + 收尾策略（2026-11-20，commit 397646f1）

## 改动行为
1. **同轮只读工具并行**：`chatViaGateway` 一轮返回的 `tool_calls` 若**全部免确认**（非 `WRITE_TOOLS`），`Promise.all` 并发执行；含任一击写工具的轮保持串行（确认闸门与执行顺序必须与模型输出一致）。tool 消息与 `onResult` 均按**调用原序**回填，协议顺序不变。
2. **结构化书卡按 callId 配对**：`AiTools.booksByCall: Map<callId, ToolBookLine[]>` 与静态槽 `lastBooks` 在**同一同步段**双写；UI 经 `onToolResult(…, callId)` → `takeLastBooksFor(callId)` 取回，map 无登记回退静态槽（串行路径零变化）。回路 `finally` 调 `clearPendingBooks()` 清理中断残留。
3. **activity 翻转方向**：有 callId（网关回路）→ 正序翻**最早**同名 doing（并行结果原序回填）；无 callId（页面直调）→ 保留旧「只翻最后一条」语义。
4. **收尾策略**：`round === MAX_TOOL_ROUNDS - 3` 时向 gwMessages 注入一次 user 角色的内部收敛提示；达到 12 轮上限时——模型有正文 → **软着陆**返回正文+「达到 N 轮上限」说明（部分成果不再报废），无正文 → 仍按旧语义抛错。

## 关键契约（回归钉死于 92/92 中的 3 个新用例）
- 并行分支事件形态：`T T T R1 R2 R3`（onTool 全部先行）；混轮形态：`Tsearch R… Tcreate R…`（严格交替）。
- 并行 `execute(search_books,…,c1)` 与 `(…,c2)` 后 `takeLastBooksFor` 各归各书，不串台。
- 提示只在第 9 轮请求出现一次；软着陆文案含「12 轮上限」；纯工具无正文才报「达到上限」。

## 验证
- harness：`node --experimental-strip-types scripts/check_ai_assistant.mjs` → **92/92**（基线 89+3）。
- 构建：`scripts/build-hap.sh` → BUILD SUCCESSFUL。
- 板上：无布局改动（活动区条目顺序与卡片归属变化），并入 #1450 模拟器补验。
