# AI 思考过程显示——板上验证记录（2026-11-19）

## 问题
用户报告「没有思考过程」：推理模型（OpenCode 网关）明明在思考（「思考中…」持续十几秒），
界面上却从未显示思考内容。

## 根因
两条通道都只解析正文，`reasoning_content` 从未读取：
- SDK 流式通道：`AiService` onData 只取 `choices[0].delta.content`；
- OpenCode 网关整包通道：`parseGatewayReply` 只取 `choices[0].message.content`。

## 方案
- `AiStreamHandlers` 增可选 `onReasoning(delta)`；SDK 通道从 `delta` 按 Record 取
  `reasoning_content`（SDK 类型未声明但运行时 JSON 透传），网关通道解析
  `message.reasoning_content` 并逐轮回调（工具回路多轮思考累积）。
- `AiChatStore`：`streamingReasoning` 实时累积；`finishBubble`/`stopStreaming` 固化进
  `bubble.reasoning` 并随历史持久化，`loadHistory` 恢复。
- `AiAssistantPage`：`ReasoningBlock` 小组件——流式默认展开（「正在思考」）、历史默认折叠
  （「思考过程」点击切换）；ForEach key 覆盖 reasoning 长度防不刷新。

## 回归
47/47 通过（新增 3 用例：onReasoning 累积/固化/持久化恢复、停止生成固化已有思考、
网关 parseGatewayReply 解析 reasoning_content）。

## 板上验证（127.0.0.1:5555，签名包 23:10:49）
复现路径：书架 → wand 进对话页 → 清空 → 发「用三四句话介绍《三体》的核心思想…」→
等回复 → 气泡顶部「思考过程」折叠行 → 点击展开。

| 截图 | 状态 | 说明 |
|------|------|------|
| 170_回复完成_思考过程折叠行.png | 回复完成默认态 | 气泡顶部「思考过程」折叠行，正文在下 |
| 171_思考过程展开.png | 点击展开 | 灰色小字真实推理文本（英文 reasoning_content，含「灵魂设定: 简洁优先」），与正文分层 |
| 172_重进后思考过程仍在.png | 退出再重进 | 折叠行仍在且默认折叠——reasoning 随历史持久化成立 |

- 网关确实透传 `reasoning_content`（此前未验证过的假设，板上证实）。
- 网关通道是整包模式，思考过程随回复一次性出现（无逐字流式）；SDK 流式通道为增量累积。
