# HarmonyOS 端侧推理可行性评估

> 任务 #28 · 2026-11-07 · 只调研，不含实现
> 目标：判断 MyBooks 的 AI 助手能否脱离远端 API，在设备本地跑 1B–3B 小模型。

## 结论

**可行，但分两档。**

| 档位 | 方案 | 结论 | 适用 |
|---|---|---|---|
| 近期 | llama.cpp（CPU 后端）封装成 NAPI 库，接 OpenAI 兼容接口的本地实现 | 可行，工程量中等 | 1B–1.5B Q4/Q8 模型，问答类低频使用 |
| 远期 | 低比特专用推理（BitNet/T-MAC 类） | 性能最好，但模型受限、工程量大 | 追求 3B 级速度时再评估 |
| 不建议 | MindSpore Lite 跑 LLM | 图像/分类成熟，LLM 路径无公开验证 | 暂不投入 |

关键约束：**手机端是内存带宽受限**，速度由权重位宽决定，不是算力。3B Q4 模型约 1.8–2GB，中端机峰值内存会吃紧；1B Q4（约 0.7GB）是当前更现实的起点。

## 方案一：llama.cpp + NAPI（推荐先做）

**移植证据（第三方，可复现）**

- `momo0410/llama.cpp-openharmony-port`：在 OpenHarmony 7.0.0.39（x86_64 虚拟机）验证 CLI 推理、中文对话、`llama-server` 的 OpenAI 兼容 API；支持 `x86_64` 与 `arm64-v8a`；改动仅 3 个文件 23 行，全部是 musl/libc 兼容补丁（`_GNU_SOURCE`、`pthread_setaffinity_np` → `sched_setaffinity`、`SUBPROCESS_HAVE_CWD=0`）。
- `bachjin/oh-llama.cpp`：用 OHOS SDK 的 aarch64 工具链交叉编译，`GGML_RKNN=on` 走 RKNN 后端，在 RK3588 设备上跑 Llama-3.2-1B-Instruct GGUF。
- `Aloereed/llama.cpp-server-ohos`：HarmonyOS Next 上的 llama.cpp server 工程（OpenMP 多线程）。

**对 MyBooks 的接入方式**

1. 用 OHOS SDK native 工具链编 `libllama.so` + `libggml.so`（`GGML_OPENMP=OFF`、`LLAMA_CURL=OFF`、`GGML_NATIVE=OFF`、`OHOS_STL=c++_static`），产物放 `ohos/entry/libs/arm64-v8a/`，与现有 `libcurl.so` 同目录。
2. 新增 NAPI 模块 `entry/src/main/cpp/llama_napi.cpp`：`loadModel(path)` / `chat(messagesJson, maxTokens)` / `abort()` / `release()`。推理必须跑在 worker 线程，结果分块回传 ArkTS（对应现有 `AiStreamHandlers` 的 `onDelta/onDone/onError`）。
3. ArkTS 侧加 `LocalAiProvider`，与 `AiService` 现有 OpenAI 客户端同接口；`AiConfig.providerId` 增加 `local`，UI 只多一个「本机模型」选项 + 模型文件选择。
4. 模型文件放应用沙箱（`filesDir/models/`），支持从系统文件选择器导入 `.gguf`；不建议内置进 HAP（体积与上架限制）。

**预期性能（需实测，以下为同平台参考）**

- 鸿蒙 x86_64 模拟器上 llama.cpp Q4_0 跑 3B：5.4–5.6 tok/s（第三方 A/B 数据，2026-09）。
- 真机 arm64 无公开的 llama.cpp 1B 数据；按带宽估算 1B Q4 在旗舰机约 10–20 tok/s、中端机 5–10 tok/s，**必须上板实测后再定 UI 预期**。
- 3B Q4 峰值内存参考 1.4GB（低比特方案实测），1B Q4 估算 0.7–0.9GB。

## 方案二：低比特专用推理（远期）

`junlume/fandou-t-mac` 把微软 T-MAC（LUT 查表、2-bit 三值权重）移植到 HarmonyOS 真机（ArkTS + NAPI + C++），公开数据（HUAWEI HBN-AL00，2026-09-30）：

| 指标 | 数值 |
|---|---|
| 模型 | BitNet-b1.58-3B，2.44 BPW，966MB |
| 模型加载 | 1.69 s |
| 首轮生成 | 22.00 tok/s |
| 二轮 TTFT（链式 KV 复用） | 1.32 ms |
| 峰值内存 | 1395 MB |
| 切后台释放 | 1.30 GB |

代价：只适配 BitNet 类三值模型；需要专用 kernel（NEON shuffle/查表）与 KV 复用调度；上游生态窄。**不建议作为第一版**，可作为「3B 级流畅」的备选路线。

## 方案三：MindSpore Lite（不推荐用于 LLM）

OpenHarmony 侧有 MindSpore Lite 的图像分类/检测落地（`Rayawa/PetSnap`、`Aiyc-02/YOLO-HarmonyOS-Vision`、`ramsafin/ohos-mindspore`），但公开资料里没有 LLM 文本生成的完整案例；模型需转 `.ms`，量化与 tokenizer 链路都要另建。对「聊天」场景收益低、风险高。

## 主要风险

1. **包体积**：HAP 增加 2–5MB `.so`；模型 0.7–2GB 只能外置导入，需处理存储权限与剩余空间校验。
2. **内存/发热**：1B 模型常驻内存约 0.7GB，低端机可能被系统回收；需支持「用完即释放」与后台释放策略。
3. **线程模型**：NAPI 同步调用会卡 UI；必须 worker 线程 + 分块回调，且 `abort()` 要能真正中断 decode。
4. **工具链漂移**：OHOS SDK 的 musl/llvm 版本变化会影响上述 3 处兼容补丁；需在 CI 或本地脚本里固定 SDK 版本。
5. **模型许可**：Qwen/Llama 系许可不同，分发前需确认；llama.cpp 为 MIT。
6. **无 NPU 加速**：CPU 后端是基线；NPU（CANN/RKNN）需按芯片适配，暂不承诺。

## 建议的落地顺序

1. 先做**验证性 spike**：只编 `arm64-v8a` 的 `llama-cli`，推到测试机跑 Qwen2.5-1.5B-Instruct Q4_K_M，记录 load 时间、tok/s、峰值内存（`hidumper --mem`）。
2. spike 达标（≥8 tok/s、峰值 <1.2GB）再做 NAPI 封装与 `LocalAiProvider`。
3. 与远端 API 并存：设置页二选一，默认仍走远端；本机模型仅在用户显式开启时加载。

## 来源

- https://github.com/momo0410/llama.cpp-openharmony-port
- https://github.com/bachjin/oh-llama.cpp
- https://github.com/Aloereed/llama.cpp-server-ohos
- https://github.com/junlume/fandou-t-mac （`ohos/FULL-REPORT.md`）
- https://github.com/ramsafin/ohos-mindspore
- https://github.com/ggml-org/llama.cpp

> 注：第三方仓库数据未经本机复现，仅作方案筛选依据；所有性能数字以第 1 步 spike 实测为准。
