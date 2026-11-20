# Token Plan（千问）音频 API 协议实测档案（2026-11-20）

网关：`https://token-plan.maas.qianwenaiapi.com`。Key 经 `Authorization: Bearer`；错误体两套格式：网关级 404 `{"code":"NotFound","message":"Api not found."}`，后端级 DashScope 格式 `{request_id,code,message}`。`GET /compatible-mode/v1/models` 共 23 模型（chat 全家桶 + qwen-audio-3.0-asr-flash/tts-plus/realtime-plus + qwen-image-3.0-pro/wan2.7-image(-pro)/wan3.0-video）。

## 1. 文字对话（OpenAI 兼容，直接可用）
`POST /compatible-mode/v1/chat/completions` —— qwen3.6-flash 实测 200，含 `reasoning_content`。**注意：音频模型走这个端点会被拒**（chat/completions+input_audio → 400 空 body；/responses → Unsupported model；/audio/speech、/audio/transcriptions → 网关/url 错）。

## 2. TTS：`qwen-audio-3.0-tts-plus`（实测✅）
```
POST /api/v1/services/audio/tts/SpeechSynthesizer
{"model":"qwen-audio-3.0-tts-plus","input":{"text":"…","voice":"longanhuan_v3.6","format":"mp3","sample_rate":22050}}
→ output.audio.url（OSS 临时链接，含 Expires）→ 二次 GET 下载
```
voice 合法集是 qwen-audio 系（`longanhuan_v3.6` 实测可用；Cherry/Tina/Ethan/longxiaochun/default 全报 `Request voice is invalid!`）。mp3 22.05kHz 单声道 128kbps。

## 3. ASR：`qwen-audio-3.0-asr-flash`（实测✅）
```
POST /api/v1/services/aigc/multimodal-generation/generation
{"model":"qwen-audio-3.0-asr-flash",
 "input":{"messages":[{"role":"user","content":[{"type":"input_audio","input_audio":{"data":"data:audio/mpeg;base64,<b64>"}}]}]},
 "parameters":{"format":"mp3"}}
→ output.text（逐字转写），output.sentence.words[] 带 begin_time/end_time 词级时间戳
```
data 支持 `data:<mime>;base64,` 或公网 URL；时长 ≤5 分钟；MIME 表 aac/amr/flac/m4a/mp3/ogg/opus/wav/webm。TTS→ASR 闭环验证：转写与原文逐字一致。

## 4. 实时对话：`qwen-audio-3.0-realtime-plus`（实测✅ VAD+转写+回复）
WebSocket：`wss://token-plan.maas.qianwenaiapi.com/api-ws/v1/realtime?model=qwen-audio-3.0-realtime-plus`（header Authorization Bearer）。
协议同 OpenAI Realtime：连上收 `session.created` → 发 `session.update`（`modalities:["audio","text"]`、`voice:"longanqian"`、`input_audio_format:"pcm"`(16k)、`output_audio_format:"pcm"`(24k)、`turn_detection:{type:"server_vad",threshold:0.5,silence_duration_ms:600}`）→ 持续 `input_audio_buffer.append`(base64 16k s16le，~100ms/3200B 一块) → 服务端自动 speech_started/stopped → `conversation.item.input_audio_transcription.delta/.completed`（[你说]）→ `response.audio_transcript.delta/.done`（AI 文本）→ `response.audio.delta`(播放) → `response.done`。
注入 8.8s TTS 音频验证：VAD 触发、AI 回复「你好！有什么可以帮你的吗？」全链路事件齐全；`response.audio.delta` 字节数待真人会话复核（脚本收 0B，事件却有 audio.done——voice=longanqian 在 realtime 有效性由官方示例背书）。

## 5. 项目脚本
- `qwen_realtime_voice.py`（仓库根，用户提供的官方示例，sounddevice 麦→WS→扬声器免提对话）。
  运行环境（本机无 root 的方案）：venv `/tmp/qp_venv`（websockets>=15/sounddevice/certifi/requests）；**PortAudio 缺失** → `apt-get download libportaudio2 && dpkg-deb -x` 到 `/tmp/portaudio`，补软链 `libportaudio.so -> libportaudio.so.2`，运行时 `LD_LIBRARY_PATH=/tmp/portaudio/usr/lib/x86_64-linux-gnu`；Key 走 `TOKEN_PLAN_API_KEY` env（不落盘不进日志）。
- 依赖 numpy 仅 sd.rec/play 需要；脚本用 RawInputStream/RawOutputStream，不需 numpy。

## 6. App 端接入含义（#204 重开的设计输入）
- 服务商登记：AI_PROVIDERS 加预设（compatible-mode/v1 基址）；文字即可用。
- App 内音频对话不依赖系统 CoreSpeechKit（模拟器空壳结论作废为无关项）：ASR=上传 wav/mp3 base64 到 multimodal-generation；TTS=SpeechSynthesizer 拿 OSS url 再下载播放（rcp GET + AudioRenderer/AudioPlaybackService）；realtime 需要 WebSocket——rcp 有 WebSocket 支持（rcp.WebSocket）待验证，或降级「按住说话→ASR→chat→TTS」非全双工模式先行。
- 音频规格契合：录音侧 AudioCapturer 16k 单声道 PCM→包 wav→base64 即可。
