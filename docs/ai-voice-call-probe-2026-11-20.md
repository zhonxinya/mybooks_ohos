# 语音对话 t1 探测结论：模拟器无可用系统语音引擎（2026-11-20）

## 背景
计划「AI 音频对话：全屏语音通话模式」（台账 #204，任务 #1440–1444）。
约束：OpenCode 网关实测无 `/v1/audio/speech`（404）、models 无音频条目 → API 音频不可行；用户拍板走系统 CoreSpeechKit + 全屏通话模式 + 自动播报默认关。

## 探测设计（保留在代码里，可复用）
- `AudioConversationService.probe()`：TTS 朗读一句（失败重试一次，间隔 1.5s）→ ASR createEngine → startListening → AudioCapturer(16k/单声道/S16LE, `on('readData')` 灌 `writeAudio`) → 4s 后 finish，8s settle 上限；结果字符串显示在 **AI 设置页「语音能力探测」行**（testResult），同步 hilog TAG=AudioConversation/ReaderTtsService。
- MICROPHONE 权限已加：module.json5（user_grant，reason=$string:mic_permission_reason）+ requestPermissionsFromUser；模拟器弹系统授权框，允许后流程继续。

## 板上结论（127.0.0.1:5555 模拟器）
| 通道 | 结果 | 证据 |
|------|------|------|
| TTS | ❌ | `createEngine` 稳定报 **50008 Creating the engine timed out**（重试 2 次一致）；TtsAbility 进程能拉起但背后无真引擎 |
| ASR | ❌ | 引擎创建成功、AsrAbility 拉起执行后报 **6800301 (system error)**；`bm dump com.huawei.hmsapp.hiai` versionName 为空（服务空壳） |

探测 UI 结论原文：`TTS=fail | ASR=run_fail_6800301(system error)`。
**判定：模拟器不可实现端到端音频对话；用户决定暂不实现（#1441–1444 dropped），待真机或局域网音频服务再启用。**

## 可复用的关键坑
1. **`CreateEngineParams.online` 语义反直觉**：d.ts 明确 `0=在线、1=离线`（多数文档印象相反）。传 0 且无 HMS 云服务时 createEngine 报 `1002200001 Asr CreateEngineParams is wrong!`。
2. **hap-sign-tool `-mode` 必须是 `localSign`**（此前手敲 `signingMode` 连续失败报 `ERROR: 11011002 {mode} param is incorrect`——#520/#1439 两次卡签名的真正根因）。
3. TTS 引擎冷启动可能只是慢（50008 含 "try again later"），真机上探测应保留重试。
4. SettingsPage「模型设置」行在 AI 助手卡片展开后才出现（折叠交互），板上导航先点「AI 助手」再点子行。

## 恢复实施的前置条件（任一）
- 华为真机（完整 hiai voice）上跑 probe 拿 `TTS=started | ASR=engine_ok ... settle=complete`；
- 或部署局域网 OpenAI 兼容音频服务（faster-whisper `/v1/audio/transcriptions` + piper/edge-tts HTTP），改走 API 路线重写 AudioConversationService 的传输层（录音采集/喂流封装可沿用）。
