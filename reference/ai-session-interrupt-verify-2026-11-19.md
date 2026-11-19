# AI 对话退出中断修复——板上验证记录（2026-11-19）

## 问题与根因
- 用户报告：退出聊天界面（对话页）后，正在流式生成的回复就中断了。
- 根因：`AiAssistantPage.aboutToDisappear()` 里调用 `stopStreaming()`——页面被路由销毁时
  requestId++ 并 abort 掉在途流，部分内容被固化成「已停止生成」。
- 页面实例随退出销毁，流式状态机（messages/streamingText/liveActivities/abort）全部挂在
  页面 @State 上，重进页面只能读落盘历史，在途回复无处可续。

## 方案
- 新增 `services/AiChatStore.ets` 全局单例：持有会话状态机与 send/stopStreaming/
  saveHistory/loadHistory/buildContext/encodeImage/finishBubble/beginActivity/endActivity。
- `AiAssistantPage` 变纯视图：@State 全部为 store 镜像，store 每次变化经 attachView 注册的
  回调同步；`aboutToDisappear` 只解绑视图（token 比对，防旧页迟到的 disappear 误清新页），
  **不再中断流**。
- 写操作闸门确认弹窗依赖 UIContext：页面在场走 `requestConfirm` 弹 showDialog；
  页面不在场（confirmUi 未绑定）一律按拒绝——与切页/停止/回退键的既有语义一致。
- 历史读取加 `loaded` 守卫：流式途中重进页面不会用落盘历史覆盖在途气泡。
- 备注：ArkTS 不允许 struct implements interface（编译错误 10905212），故视图契约用
  函数+token 注册而非接口实现。

## 回归
- `node --experimental-strip-types scripts/check_ai_assistant.mjs`：**44/44 通过**。
- 新增两用例：
  - 「退出对话页不中断流式：后台完成落盘，重进页面即见完整回复」
  - 「写闸门：页面不在场时确认一律按拒绝」

## 板上验证（127.0.0.1:5555，签名包 22:38:40）
复现路径：书架 → 右上 wand 进对话页 → 输入框输入问题 → 点发送 → 流式中按 Back 退到书架 →
等待后台完成 → 再点 wand 重进 → 回复完整。

| 截图 | 状态 | 说明 |
|------|------|------|
| 166_生成中退出前.png | 流式中、页面在场 | 问题气泡 + 「思考中…」+ 输入框占位「生成中…」+ 红色停止钮 |
| 167_生成中已退出.png | 已退出到书架 | Back 一次键盘收起、再 Back 退出对话页（流继续后台跑） |
| 168_重进后回复完整.png | 重进后 | 回复完整：Markdown 加粗渲染 + search_books 书目卡带封面 + 追问 + 「复制」按钮；**无「已停止生成」** |

- 判据：重进后 dump 无「已停止生成」「超时」，长回答 + 复制按钮在场（168 中回复还包含工具
  回路结果，证明整条链路在后台跑完并落盘）。

## 过程中发现（非本次改动引入）
- 同一超长问题（三部各 600 字）**页面在场不退出也会失败**：一次「AI 返回内容为空」、
  一次「AI 请求超时」——OpenCode 网关当日长请求不稳定，与流式中断修复无关。
- 首轮 450 字问题约 10 秒完成，说明常规长度无影响。
