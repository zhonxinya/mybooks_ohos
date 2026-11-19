# AI 灵魂与记忆 板上验证记录（2026-11-19）

分支 feature/ai-soul-memory（本地 ab518dcb / 远端 API 重放 831486f7，tree 337eb8c8 一致）。
设备：Pura70Pro 无窗口模拟器（127.0.0.1:5555），Test Server 192.168.31.160:5010，服务商 OpenCode (Go)。

## 回归与构建
- `node --experimental-strip-types scripts/check_ai_assistant.mjs` → **40/40**（新增 4 用例：存储层读写/去重/序号删除、记忆工具闸门登记与落盘、system prompt 注入、管理页操作）。
- `./scripts/build-hap.sh` → BUILD_OK；hap-sign-tool sign-app → Sign Hap success；`hdc install -r` 成功。
- 坑：首次签名命令漏 `-keystoreFile .hapsign/dev.p12` 导致静默失败、装机装到旧包（板上无新入口）；
  判据=对比 unsigned.hap 与 signed.hap 时间戳，签名输出必须见 "Sign Hap success"。

## 板上步骤与截图（.verify-shots/20261119/）
| 截图 | 状态 | 复现 |
|---|---|---|
| 120_persona_default.png | 管理页默认态：SOUL.md 默认人格全文 + 记忆空态文案 | 对话页→设置→「灵魂与记忆」行 |
| 121_soul_edited_saved.png | TextArea 文末追加「以后每条回复末尾都加一句：啊哈！」并保存（toast 灵魂已保存） | 管理页点 TextArea 输入→保存灵魂 |
| 122_save_memory_reply.png | 对话「记住我喜欢刘慈欣的长篇科幻」→活动线「记住用户的事：已记住…」→回复末尾「啊哈！」（灵魂生效） | 对话页发送 |
| 123_memory_list.png | 管理页记忆列表「1. 用户喜欢刘慈欣的长篇科幻作品」 | 管理页下滑 |
| 124_cross_session_memory.png | 清空历史后新会话问「我的阅读偏好是什么？不用查工具」→「你偏好刘慈欣的长篇科幻作品。啊哈！」（跨对话记忆+灵魂双生效） | 清空→新提问 |
| 125_forget_confirm_dialog.png | 「忘掉第 1 条记忆」→确认弹窗「AI 想执行操作：删除一条记忆 参数{"index":1}」拒绝/允许 | 对话页发送 |
| 126_memory_after_forget.png | 允许后活动线「已忘记…」+管理页回到空态 | 允许→管理页 |
| 127_soul_reset_default.png | 「恢复默认」后灵魂文本回默认（啊哈句消失） | 管理页恢复默认 |

## 遗留
- 误触教训：技能芯片「找书并下载」文案含「确认」二字，脚本按关键字找弹窗按钮会误命中；
  清空按钮实测无确认弹窗直接生效。
