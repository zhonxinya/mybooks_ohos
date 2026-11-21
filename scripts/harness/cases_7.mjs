// 用例组 7：模型清单快切/Token Plan 音频/通话/Speak/Realtime（拆分自 check_ai_assistant.mjs，用例体原样）
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { test, state, settingsDefaults, enc, rtB64, deferred, tick, flush } from './base.mjs';
import { dir, read, ETS, ROOT } from './paths.mjs';

export function register(ctx) {
  const { load, deps, RealAiService, RealAiTools, parseToolBookLines, toolsState, mdParseBlocks, mdParseInline, AI_SKILLS, AiAssistantPage, AiBookPanelPage, AiRecommendPage, AiSettingsPage, AiPersonaPage, AiPersona, DEFAULT_SOUL, AiChatStore, personaState, MetaSearchService, NovelMetaService, resetSettings, settingsPage, featurePage, libraryPage, chat, reappear } = ctx;
  test('设置页模型清单：手动添加去重即存、删除、拉取勾选合并、切服务商重载', () => {
    resetSettings();
    const page = settingsPage();
    assert.deepEqual(page.providerModels, [], '初始为空');
    page.newModelName = ' qwen-max ';
    page.addModelToList();
    assert.deepEqual(page.providerModels, ['qwen-max'], 'trim 后入清单');
    assert.deepEqual(state.settings.providerModels.deepseek, ['qwen-max'], '改动即落盘');
    page.newModelName = 'qwen-max';
    page.addModelToList();
    assert.equal(page.providerModels.length, 1, '重复添加去重');
    page.newModelName = '  ';
    page.addModelToList();
    assert.equal(page.providerModels.length, 1, '空名不落盘');
    page.newModelName = 'glm-4';
    page.addModelToList();
    page.removeModel('qwen-max');
    assert.deepEqual(page.providerModels, ['glm-4']);
    assert.deepEqual(state.settings.providerModels.deepseek, ['glm-4'], '删除也落盘');
    // 拉取勾选合并
    page.modelOptions = ['a', 'b', 'c'];
    page.togglePick('a');
    page.togglePick('b');
    page.togglePick('b');
    assert.deepEqual(page.pickedModels, ['a'], '再点取消勾选');
    page.providerModels = ['b'];
    page.applyPicked();
    assert.deepEqual(page.providerModels, ['b', 'a'], '勾选并入去重');
    assert.deepEqual(state.settings.providerModels.deepseek, ['b', 'a'], '合并按当前服务商落盘');
    assert.equal(page.pickedModels.length, 0, '并入后清空勾选');
    page.applyPicked();
    assert.deepEqual(state.settings.providerModels.deepseek, ['b', 'a'], '无勾选时不落盘');
    // 切服务商重载各自清单
    state.settings.providerModels.opencode = ['big-pickle'];
    page.selectProvider('opencode');
    assert.deepEqual(page.providerModels, ['big-pickle']);
    page.selectProvider('deepseek');
    assert.deepEqual(page.providerModels, ['b', 'a']);
  });

  test('对话页快切：本地清单优先零拉取，「重新获取」绕过清单拉全量', async () => {
    resetSettings();
    state.settings.providerModels.deepseek = ['m-a', 'm-b'];
    state.settings.fetchError = '服务商不支持模型列表'; // 若误走拉取必失败
    const page = chat();
    await flush();
    assert.deepEqual(page.modelChoices, ['m-a', 'm-b'], '进页直接用本地清单');
    const items = page.modelMenuItems();
    assert.equal(items.length, 3, '2 模型 + 重新获取项');
    items[2].action();
    await flush();
    assert.deepEqual(page.modelChoices, ['m-a', 'm-b'], '拉取失败不动清单');
    state.settings.fetchError = '';
    items[2].action();
    await flush();
    assert.deepEqual(page.modelChoices, state.settings.models, '重新获取绕过清单拉全量');
    resetSettings();
  });

  test('AiService 服务商模型清单持久化：回读、空数组清除、坏 JSON 容错', () => {
    deps.state.store.set('p:ai_provider_models_custom-9', JSON.stringify(['a', 'b', 3]));
    assert.deepEqual(RealAiService.loadProviderModels('custom-9'), ['a', 'b'], '非字符串项丢弃');
    RealAiService.saveProviderModels('custom-9', ['x']);
    assert.deepEqual(RealAiService.loadProviderModels('custom-9'), ['x']);
    RealAiService.saveProviderModels('custom-9', []);
    assert.deepEqual(RealAiService.loadProviderModels('custom-9'), [], '空数组即清除');
    deps.state.store.set('p:ai_provider_models_custom-9', '{bad json');
    assert.deepEqual(RealAiService.loadProviderModels('custom-9'), [], '坏 JSON 不抛错');
  });

  test('Token Plan 音频链路：ASR/TTS 请求形态、缓存清理与未配 Key 容错', async () => {
    const { QwenAudioService } = await load('RealQwenAudio');
    deps.state.rcpResponses.length = 0;
    deps.state.rcpThrowQueue.length = 0;
    deps.state.rcpError = null;
    deps.state.requests.length = 0;
    deps.state.ttsFiles.length = 0;
    const prevProvider = deps.state.store.get('p:ai_provider');
    // 前面设置页用例会把 ai_base_url 落盘覆盖 preset；origin() 派生自它，必须先清
    const prevBaseUrl = deps.state.store.get('s:ai_base_url');
    deps.state.store.delete('s:ai_base_url');
    deps.state.store.set('p:ai_provider', 'qwen-tokenplan');
    deps.state.store.set('s:ai_api_key_qwen-tokenplan', 'sk-test');
    // ① ASR：DashScope 原生路径 + data URI 前缀 + output.text 解析
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(JSON.stringify({ output: { text: '推荐一本科幻' } })) }];
    assert.equal(await QwenAudioService.transcribe('QUJDRA=='), '推荐一本科幻');
    const asrReq = deps.state.requests[0];
    assert.equal(asrReq.url, 'https://token-plan.maas.qianwenaiapi.com/api/v1/services/aigc/multimodal-generation/generation');
    assert.equal(asrReq.headers['Authorization'], 'Bearer sk-test');
    const asrBody = JSON.parse(asrReq.content);
    assert.equal(asrBody.model, 'qwen-audio-3.0-asr-flash');
    assert.ok(asrBody.input.messages[0].content[0].input_audio.data.startsWith('data:audio/wav;base64,QUJDRA=='));
    assert.equal(asrBody.parameters.format, 'wav');
    // ② 空录音直接返回空串，不发请求（「没听清」分支的前提）
    const reqCount = deps.state.requests.length;
    assert.equal(await QwenAudioService.transcribe(''), '');
    assert.equal(deps.state.requests.length, reqCount);
    // ③ TTS：合成→OSS 下载→落盘 /tts/，缓存只留最近 5 个（先种 5 个旧的）
    for (let i = 0; i < 5; i++) { deps.state.ttsFiles.push(`tts_00${i}.mp3`); }
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc(JSON.stringify({ output: { audio: { url: 'https://oss.example/a.mp3?Expires=1' } } })) },
      { statusCode: 200, body: enc('MP3DATA') },
    ];
    const path = await QwenAudioService.synthesize('你好');
    assert.ok(path.includes('/tts/tts_') && path.endsWith('.mp3'), path);
    const ttsReq = deps.state.requests[deps.state.requests.length - 2];
    assert.equal(ttsReq.url, 'https://token-plan.maas.qianwenaiapi.com/api/v1/services/audio/tts/SpeechSynthesizer');
    const ttsBody = JSON.parse(ttsReq.content);
    assert.equal(ttsBody.model, 'qwen-audio-3.0-tts-plus');
    assert.equal(ttsBody.input.voice, 'longanhuan_v3.6');
    assert.equal(ttsBody.input.sample_rate, 22050);
    assert.equal(deps.state.rcpResponses.length, 0);
    assert.equal(deps.state.ttsFiles.length, 5);
    assert.ok(!deps.state.ttsFiles.includes('tts_000.mp3') && deps.state.ttsFiles.includes(path.slice(path.lastIndexOf('/') + 1)));
    // ④ 非 2xx 透传状态码与响应体片段
    deps.state.rcpResponses = [{ statusCode: 401, body: enc('{"code":"InvalidApiKey"}') }];
    await assert.rejects(() => QwenAudioService.transcribe('QUJD'), /HTTP 401: \{"code":"InvalidApiKey"\}/);
    // ⑤ 未配 Key：明确指向设置页，不带网络错误
    deps.state.store.delete('s:ai_api_key_qwen-tokenplan');
    await assert.rejects(() => QwenAudioService.synthesize('x'), /未配置 Token Plan API Key/);
    if (prevProvider === undefined) { deps.state.store.delete('p:ai_provider'); } else { deps.state.store.set('p:ai_provider', prevProvider); }
    if (prevBaseUrl !== undefined) { deps.state.store.set('s:ai_base_url', prevBaseUrl); }
    deps.state.requests.length = 0;
    deps.state.ttsFiles.length = 0;
  });

  test('多服务商并存：地址按服务商隔离、语音档位模型独立、音频服务读语音档位', async () => {
    deps.state.store.clear();
    // ① 旧版全局单槽地址迁移：挪进所属服务商槽位后清空（否则换商即脏地址）
    deps.state.store.set('p:ai_provider', 'deepseek');
    deps.state.store.set('s:ai_base_url', 'https://mirror.deepseek.com/v1');
    assert.equal(RealAiService.loadConfig().baseUrl, 'https://mirror.deepseek.com/v1', '旧地址迁移后仍对当前服务商生效');
    assert.equal(deps.state.store.get('s:ai_base_url'), undefined, '旧全局槽迁移后清空');
    // ② 各服务商地址各存各的：换回 deepseek 不被 opencode/tokenplan 污染
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'big-pickle', 'sk-oc', 0.5);
    RealAiService.saveConfig('deepseek', 'https://mirror.deepseek.com/v1', 'deepseek-chat', 'sk-d', 0.5);
    RealAiService.saveConfig('qwen-tokenplan', 'https://token-plan.maas.qianwenaiapi.com/compatible-mode/v1', 'qwen3.6-flash', 'sk-tp', 0.5);
    RealAiService.saveConfig('deepseek', 'https://mirror.deepseek.com/v1', 'deepseek-chat', '', 0.5);
    assert.equal(RealAiService.loadConfig().baseUrl, 'https://mirror.deepseek.com/v1', '全局切回 deepseek 用自己槽的地址，不被 tokenplan 污染');
    assert.equal(RealAiService.baseUrlFor('deepseek'), 'https://mirror.deepseek.com/v1', '并存：deepseek 地址不被覆盖');
    assert.equal(RealAiService.baseUrlFor('opencode'), 'https://opencode.ai/zen/go/v1', '并存：opencode 地址独立保存');
    // ③ 语音档与全局同服务商：自己的 model 独立生效（bug 核心②）
    RealAiService.saveVoiceConfig('deepseek', 'deepseek-reasoner');
    const v = RealAiService.loadVoiceConfig();
    assert.equal(v.providerId, 'deepseek');
    assert.equal(v.model, 'deepseek-reasoner', '语音档 model 不被全局值吞掉');
    assert.equal(v.baseUrl, 'https://mirror.deepseek.com/v1');
    // ④ 聊天=DeepSeek + 语音档=Token Plan 并存：ASR 走语音档的地址与 Key（bug 核心①）
    RealAiService.saveVoiceConfig('qwen-tokenplan', '');
    const { QwenAudioService } = await load('RealQwenAudio');
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(JSON.stringify({ output: { text: 'ok' } })) }];
    deps.state.requests.length = 0;
    assert.equal(await QwenAudioService.transcribe('QUJDRA=='), 'ok');
    assert.ok(deps.state.requests[0].url.startsWith('https://token-plan.maas.qianwenaiapi.com/'),
      `ASR 应走语音档 Token Plan：${deps.state.requests[0].url}`);
    assert.equal(deps.state.requests[0].headers['Authorization'], 'Bearer sk-tp', 'Key 取语音档服务商槽位');
    deps.state.rcpResponses = [];
    deps.state.requests.length = 0;
    deps.state.store.clear();
  });

  test('语音通话对话模型：跟随全局/独立服务商解析/complete 按 override 出请求', async () => {
    deps.state.store.clear();
    RealAiService.saveConfig('deepseek', 'https://api.deepseek.com/v1', 'deepseek-chat', 'sk-d', 0.5);
    // ① 未单独配置 → 跟随全局
    assert.equal(RealAiService.loadVoiceConfig().providerId, 'deepseek');
    assert.equal(RealAiService.hasVoiceProvider(), false);
    // ② 独立选 Token Plan：地址随预设解析，Key 单独判
    RealAiService.saveVoiceConfig('qwen-tokenplan', 'qwen3.6-flash');
    let v = RealAiService.loadVoiceConfig();
    assert.equal(v.providerId, 'qwen-tokenplan');
    assert.equal(v.model, 'qwen3.6-flash');
    assert.equal(v.baseUrl, 'https://token-plan.maas.qianwenaiapi.com/compatible-mode/v1');
    assert.equal(v.hasKey, false);
    assert.equal(RealAiService.loadVoiceProviderId(), 'qwen-tokenplan');
    RealAiService.saveVoiceConfig('qwen-tokenplan', '');
    assert.equal(RealAiService.loadVoiceConfig().model, 'qwen3.6-flash', 'model 空回落服务商默认');
    deps.state.store.set('s:ai_api_key_qwen-tokenplan', 'sk-tp');
    assert.equal(RealAiService.loadVoiceConfig().hasKey, true);
    // ③ 选了与全局相同的服务商：语音 model 独立生效（档位配置优先于全局）
    RealAiService.saveVoiceConfig('deepseek', 'other-model');
    assert.equal(RealAiService.loadVoiceConfig().model, 'other-model');
    // ④ complete 带 override：请求用语音配置的地址/模型/Key
    RealAiService.saveVoiceConfig('opencode', 'voice-model');
    deps.state.store.set('s:ai_api_key_opencode', 'sk-oc');
    deps.state.rcpResponse = { statusCode: 200,
      body: enc(JSON.stringify({ choices: [{ message: { content: '好的' } }] })) };
    assert.equal(await RealAiService.complete([{ role: 'user', content: 'hi' }], 512,
      RealAiService.loadVoiceConfig()), '好的');
    const req = deps.state.lastRequest;
    assert.ok(req.url.startsWith('https://opencode.ai/zen/go/v1'), req.url);
    assert.equal(JSON.parse(req.content).model, 'voice-model');
    assert.equal(req.headers['Authorization'], 'Bearer sk-oc');
    // ⑤ 恢复跟随全局
    RealAiService.saveVoiceConfig('', '');
    assert.equal(RealAiService.hasVoiceProvider(), false);
    assert.equal(RealAiService.loadVoiceConfig().providerId, 'deepseek');
    deps.state.rcpResponse = null;
    deps.state.store.delete('s:ai_api_key_qwen-tokenplan');
    deps.state.store.delete('s:ai_api_key_opencode');
    deps.state.store.delete('s:ai_base_url');
  });

  test('功能模型页（模型库版）：从库条目挑选、绑定写槽、恢复跟随、删除退回跟随', async () => {
    resetSettings();
    // 空库：页面给出提示，下拉禁用
    let page = featurePage();
    assert.deepEqual(page.features, ['vision', 'summary', 'voice', 'tts', 'asr', 'realtime']);
    assert.equal(page.entries.length, 0, '空模型库');
    assert.ok(page.featureSummary('vision').includes('跟随全局'), '未绑=跟随全局');
    // 建两条库条目（服务商+模型自由组合）——走模型库页自身方法
    let lib = libraryPage();
    lib.startAdd();
    lib.editName = '便宜摘要';
    lib.editProviderIndex = 0;
    lib.editModel = 'deepseek-chat';
    lib.commit();
    lib.startAdd();
    lib.editName = '本地视觉';
    lib.editProviderIndex = 1;
    lib.editModel = 'big-pickle';
    lib.commit();
    assert.equal(lib.entries.length, 2, '模型库页新增两条');
    const e1 = lib.entries[0];
    const e2 = lib.entries[1];
    page = featurePage();
    assert.equal(page.entries.length, 2);
    assert.equal(page.optionItems('vision').length, 3, '跟随 + 2 条目');
    assert.ok(page.optionItems('vision')[1].value.includes('便宜摘要'));
    // 绑定条目：写 entry 键并同步 provider/model（消费链零改动）
    page.selectEntry('vision', 2);
    assert.equal(state.settings.featureEntry.vision, e2.id);
    assert.equal(state.settings.featureSlots.vision.providerId, 'opencode');
    assert.equal(state.settings.featureSlots.vision.model, 'big-pickle');
    assert.equal(page.selectedIndex('vision'), 2);
    assert.ok(page.featureSummary('vision').includes('本地视觉'));
    assert.ok(page.featureSummary('vision').includes('已绑定'));
    // 同一模型可被多个功能复用（不是独占）
    page.selectEntry('summary', 1);
    assert.equal(state.settings.featureEntry.summary, e1.id);
    assert.equal(state.settings.featureEntry.vision, e2.id, '两功能各绑各的，互不干扰');
    // 恢复跟随
    page.selectEntry('vision', 0);
    assert.equal(state.settings.featureEntry.vision, '');
    assert.ok(page.featureSummary('vision').includes('跟随全局'));
    // 音频档首项文案为「跟随语音档」
    assert.equal(page.followLabel('asr'), '跟随语音档');
    assert.equal(page.followLabel('vision').startsWith('跟随全局'), true);
    // 删条目：引用它的功能退回跟随
    // 删条目：走页面删除路径（确认弹窗由 stub 直接执行 action）
    lib = libraryPage();
    lib.confirmRemove(lib.entries[0]);
    assert.equal(state.settings.featureEntry.summary, '', '删除后退回跟随');
    assert.equal(state.settings.modelEntries.length, 1);
    resetSettings();
  });

  test('SpeakService 播报引擎：默认系统、播完/打断/无引擎三态与开关持久化', async () => {
    const { SpeakService: RealSpeakService } = await load('RealSpeakService');
    const { ttsState } = await load('readerTtsDeps');
    deps.state.store.clear();
    // ① 默认走系统引擎
    assert.equal(RealAiService.loadSpeakEngine(), 'system');
    ttsState.starts.length = 0;
    ttsState.stops = 0;
    ttsState.failEngine = false;
    const p1 = RealSpeakService.speak('第一句');
    await flush();
    assert.equal(ttsState.starts.length, 1);
    assert.deepEqual(ttsState.starts[0].chunks, ['第一句']);
    ttsState.starts[0].onDone();
    assert.equal(await p1, true);
    // ② stop 打断：未播完的 speak 以 false 结束，系统引擎被停
    const p2 = RealSpeakService.speak('第二句');
    await flush();
    RealSpeakService.stop();
    assert.equal(await p2, false);
    assert.ok(ttsState.stops >= 1);
    // ③ 引擎不可用（模拟器 50008 场景）：抛人话错误供页面 toast
    ttsState.failEngine = true;
    await assert.rejects(() => RealSpeakService.speak('第三句'), /Creating the engine timed out/);
    // ④ 引擎开关持久化：非法值回落 system
    RealAiService.saveSpeakEngine('cloud');
    assert.equal(RealAiService.loadSpeakEngine(), 'cloud');
    RealAiService.saveSpeakEngine('bogus');
    assert.equal(RealAiService.loadSpeakEngine(), 'system');
    deps.state.store.delete('p:ai_speak_engine');
    ttsState.starts.length = 0;
    ttsState.stops = 0;
    ttsState.failEngine = false;
  });

  test('RealtimeCallService 全双工：握手形态、append 上行、VAD 打断清队列、拉流消费与字幕事件', async () => {
    const { RealtimeCallService: Rt } = await load('RealtimeCall');
    const { rtState } = await load('realtimeDeps');
    deps.state.store.clear();
    RealAiService.saveConfig('qwen-tokenplan', 'https://token-plan.maas.qianwenaiapi.com/compatible-mode/v1', 'qwen3.6-flash', 'sk-tp', 0.5);
    rtState.sends.length = 0;
    const ev = [];
    const cb = {
      onUserText: (t) => ev.push('user:' + t),
      onAiTextDelta: (d) => ev.push('delta:' + d),
      onAiTextDone: (t) => ev.push('done:' + t),
      onSpeechStarted: () => ev.push('barge'),
      onSpeechStopped: () => ev.push('stopped'),
      onResponding: () => ev.push('responding'),
      onResponseDone: () => ev.push('resp_done'),
      onFunctionCall: (n, a, c) => ev.push('call:' + n + ':' + c),
      onError: (m) => ev.push('err:' + m),
      onClosed: () => ev.push('closed'),
    };
    const connecting = Rt.connect('人设指令', cb, [
      { type: 'function', function: { name: 'search_books', parameters: { type: 'object', properties: {} } } },
    ]);
    await flush();
    assert.equal(rtState.lastUrl, 'wss://token-plan.maas.qianwenaiapi.com/api-ws/v1/realtime?model=qwen-audio-3.0-realtime-plus');
    assert.equal(rtState.lastOptions.header.Authorization, 'Bearer sk-tp');
    rtState.socket.fireOpen();
    await flush();
    rtState.socket.emitEvent(JSON.stringify({ type: 'session.created' }));
    await flush();
    // session.update 时序与字段（docs §4 实测协议）
    const update = JSON.parse(rtState.sends[0]);
    assert.equal(update.type, 'session.update');
    assert.equal(update.session.voice, 'longanqian');
    assert.equal(update.session.turn_detection.type, 'server_vad');
    assert.equal(update.session.input_audio_format, 'pcm');
    assert.equal(update.session.output_audio_format, 'pcm');
    assert.equal(update.session.instructions, '人设指令');
    assert.equal(update.session.tools[0].function.name, 'search_books');
    // 麦克风帧 → base64 append
    const mic = new Uint8Array(3200);
    mic[0] = 42;
    rtState.capturer.feedMic(mic);
    await flush();
    const append = JSON.parse(rtState.sends[1]);
    assert.equal(append.type, 'input_audio_buffer.append');
    assert.equal(Buffer.from(append.audio, 'base64').length, 3200);
    assert.equal(Buffer.from(append.audio, 'base64')[0], 42);
    // 下行音频入队并触发 speaking
    const pcm = new Uint8Array(4800).fill(7);
    rtState.socket.emitEvent(JSON.stringify({ type: 'response.audio.delta', delta: rtB64(pcm) }));
    await flush();
    assert.ok(ev.includes('responding'));
    assert.equal(Rt.getPlayBytes(), 4800);
    // 拉模式消费 1600B
    const buf = new ArrayBuffer(1600);
    rtState.renderer.pull(buf);
    assert.equal(Rt.getPlayBytes(), 3200);
    assert.equal(new Uint8Array(buf)[0], 7);
    // speech_started 打断：队列清零
    rtState.socket.emitEvent(JSON.stringify({ type: 'input_audio_buffer.speech_started' }));
    await flush();
    assert.equal(Rt.getPlayBytes(), 0);
    assert.ok(ev.includes('barge'));
    rtState.socket.emitEvent(JSON.stringify({ type: 'input_audio_buffer.speech_stopped' }));
    // 字幕与错误事件链
    rtState.socket.emitEvent(JSON.stringify({ type: 'conversation.item.input_audio_transcription.completed', transcript: '你好呀' }));
    rtState.socket.emitEvent(JSON.stringify({ type: 'response.audio_transcript.delta', delta: 'He' }));
    rtState.socket.emitEvent(JSON.stringify({ type: 'response.audio_transcript.delta', delta: 'llo' }));
    rtState.socket.emitEvent(JSON.stringify({ type: 'response.audio_transcript.done', transcript: 'Hello' }));
    rtState.socket.emitEvent(JSON.stringify({ type: 'response.done' }));
    rtState.socket.emitEvent(JSON.stringify({ type: 'error', error: { message: '示例错误' } }));
    await flush();
    assert.ok(ev.includes('stopped'));
    assert.ok(ev.includes('user:你好呀'));
    assert.ok(ev.includes('delta:He'));
    assert.ok(ev.includes('done:Hello'));
    assert.ok(ev.includes('resp_done'));
    assert.ok(ev.includes('err:示例错误'));
    // 工具回路：function_call → 回调执行 → output 回填 + response.create 续流
    const sendsBeforeCall = rtState.sends.length;
    rtState.socket.emitEvent(JSON.stringify({ type: 'response.function_call_arguments.done',
      call_id: 'c1', name: 'search_books', arguments: '{"query":"三体"}' }));
    await flush();
    assert.ok(ev.includes('call:search_books:c1'));
    Rt.sendToolResult('c1', '找到《三体》');
    await flush();
    assert.equal(rtState.sends.length, sendsBeforeCall + 2);
    const toolOut = JSON.parse(rtState.sends[sendsBeforeCall]);
    assert.equal(toolOut.item.type, 'function_call_output');
    assert.equal(toolOut.item.call_id, 'c1');
    assert.equal(toolOut.item.output, '找到《三体》');
    assert.equal(JSON.parse(rtState.sends[sendsBeforeCall + 1]).type, 'response.create');
    // 工具执行期间用户开口：结果仍回填，但不再抢 response.create（VAD 自动起新轮）
    rtState.socket.emitEvent(JSON.stringify({ type: 'response.function_call_arguments.done',
      call_id: 'c2', name: 'search_books', arguments: '{}' }));
    await flush();
    rtState.socket.emitEvent(JSON.stringify({ type: 'input_audio_buffer.speech_started' }));
    await flush();
    const sendsBefore2 = rtState.sends.length;
    Rt.sendToolResult('c2', '结果');
    await flush();
    assert.equal(rtState.sends.length, sendsBefore2 + 1);
    assert.equal(JSON.parse(rtState.sends[sendsBefore2]).item.call_id, 'c2');
    // 静音=停上行帧（不断采集），取消静音恢复 append
    const sendsBefore = rtState.sends.length;
    Rt.setMuted(true);
    rtState.capturer.feedMic(mic);
    await flush();
    assert.equal(rtState.sends.length, sendsBefore);
    Rt.setMuted(false);
    rtState.capturer.feedMic(mic);
    await flush();
    assert.equal(rtState.sends.length, sendsBefore + 1);
    Rt.disconnect();
    await flush();
    await connecting;
    // 缺 Key：连接即抛（页面提示配置）
    deps.state.store.delete('s:ai_api_key_qwen-tokenplan');
    await assert.rejects(() => Rt.connect('x', cb, []), /Token Plan API Key/);
    deps.state.store.clear();
  });

  test('RealtimeCallService 内嵌语音：ASR 中间结果累计 + 文字历史注入', async () => {
    const { RealtimeCallService: Rt } = await load('RealtimeCall');
    const { rtState } = await load('realtimeDeps');
    deps.state.store.clear();
    RealAiService.saveConfig('qwen-tokenplan', 'https://token-plan.maas.qianwenaiapi.com/compatible-mode/v1', 'qwen3.6-flash', 'sk-tp', 0.5);
    rtState.sends.length = 0;
    const ev = [];
    const cb = {
      onUserText: (t) => ev.push('user:' + t),
      onUserTextDelta: (t) => ev.push('udelta:' + t),
      onAiTextDelta: () => {}, onAiTextDone: () => {}, onSpeechStarted: () => {},
      onSpeechStopped: () => {}, onResponding: () => {}, onResponseDone: () => {},
      onFunctionCall: () => {}, onError: () => {}, onClosed: () => {},
    };
    const history = [
      { role: 'system', content: '系统提示应被跳过' },
      { role: 'user', content: '刚才问的书' },
      { role: 'assistant', content: '推荐了三体' },
      { role: 'user', content: '' },
    ];
    const connecting = Rt.connect('人设', cb, [], history);
    await flush();
    rtState.socket.fireOpen();
    await flush();
    rtState.socket.emitEvent(JSON.stringify({ type: 'session.created' }));
    await flush();
    // 历史注入：session.update 之后逐条 conversation.item.create，system 与空文本跳过
    const seeds = rtState.sends.slice(1).map((s) => JSON.parse(s)).filter((m) => m.type === 'conversation.item.create');
    assert.equal(seeds.length, 2, '只注入 user/assistant 非空文本');
    assert.equal(seeds[0].item.role, 'user');
    assert.equal(seeds[0].item.content[0].type, 'input_text');
    assert.equal(seeds[0].item.content[0].text, '刚才问的书');
    assert.equal(seeds[1].item.role, 'assistant');
    assert.equal(seeds[1].item.content[0].type, 'output_text');
    assert.equal(seeds[1].item.content[0].text, '推荐了三体');
    // ASR 中间结果：delta 累计全文回调；speech_started 先回调空串清占位
    ev.length = 0;
    rtState.socket.emitEvent(JSON.stringify({ type: 'conversation.item.input_audio_transcription.delta', text: '今天' }));
    await flush();
    rtState.socket.emitEvent(JSON.stringify({ type: 'conversation.item.input_audio_transcription.delta', text: '天气' }));
    await flush();
    assert.deepEqual(ev, ['udelta:今天', 'udelta:今天天气']);
    // completed 后累计作废：下一句从零开始
    ev.length = 0;
    rtState.socket.emitEvent(JSON.stringify({ type: 'conversation.item.input_audio_transcription.completed', transcript: '今天天气' }));
    await flush();
    assert.ok(ev.includes('user:今天天气'));
    ev.length = 0;
    rtState.socket.emitEvent(JSON.stringify({ type: 'input_audio_buffer.speech_started' }));
    await flush();
    assert.deepEqual(ev, ['udelta:'], '新句开始先清占位');
    rtState.socket.emitEvent(JSON.stringify({ type: 'conversation.item.input_audio_transcription.delta', text: '换个' }));
    await flush();
    assert.deepEqual(ev[1], 'udelta:换个', '累计器已随 speech_started 归零');
    Rt.disconnect();
    await flush();
    await connecting;
    deps.state.store.clear();
  });

  test('AiVoiceKit set_voice：合法音色存配置并触发重建，非法/坏 JSON 不保存；realtimeDefinitions 加 set_voice 且不在末位', async () => {
    const Kit = await load('RealAiVoiceKit');
    resetSettings();
    assert.equal(RealAiService.loadRealtimeTimbre(), 'longanqian', '未配置时默认 longanqian');
    // 合法：文案 + 持久化
    const out = Kit.AiVoiceKit.applySetVoice('{"voice":"longanlufeng"}');
    assert.ok(out.startsWith('已切换到音色'), out);
    assert.equal(RealAiService.loadRealtimeTimbre(), 'longanlufeng');
    // 非法：不保存，回文带候选清单
    const bad = Kit.AiVoiceKit.applySetVoice('{"voice":"Cherry"}');
    assert.ok(bad.indexOf('不可用') >= 0 && bad.indexOf('longanqian') >= 0, bad);
    assert.equal(RealAiService.loadRealtimeTimbre(), 'longanlufeng');
    // 坏 JSON：引导文案
    assert.ok(Kit.AiVoiceKit.applySetVoice('nope').indexOf('合法 JSON') >= 0);
    // runTool：成功才触发重建（ws 空 sendToolResult no-op，set_voice 分支不用 uiContext）
    let switched = 0;
    Kit.AiVoiceKit.voiceSwitcher = () => { switched++; };
    await Kit.AiVoiceKit.runTool('set_voice', '{"voice":"longanxiaoxin"}', 'c1', null);
    assert.equal(switched, 1);
    assert.equal(RealAiService.loadRealtimeTimbre(), 'longanxiaoxin');
    switched = 0;
    await Kit.AiVoiceKit.runTool('set_voice', '{"voice":"bogus"}', 'c2', null);
    assert.equal(switched, 0, '非法音色不得触发会话重建');
    Kit.AiVoiceKit.voiceSwitcher = null;
    // realtimeDefinitions：全集−ask_user+set_voice，set_voice 不占末位（OpenCode 丢末项护栏）
    const defs = RealAiTools.realtimeDefinitions('confirm');
    assert.equal(defs.length, 30, '30 全集−ask_user（语音无卡片）+set_voice');
    assert.equal(defs[defs.length - 1].function.name, 'forget_memory');
    assert.ok(defs.some((d) => d.function.name === 'set_voice'));
    assert.ok(!defs.some((d) => d.function.name === 'ask_user'), 'ask_user 不得暴露给语音');
    const ro = RealAiTools.realtimeDefinitions('readonly');
    assert.equal(ro.length, 17, 'set_voice 非写工具，只读模式保留（16 只读含 fetch_url 去 ask_user + set_voice）');
    assert.ok(ro[ro.length - 1].function.name !== 'set_voice', '末位护栏：set_voice 不得占尾');
    // 文字回路 dispatch 兜底：误调给出引导而非未知工具
    const guide = await RealAiTools.execute('set_voice', '{"voice":"longanqian"}');
    assert.ok(guide.indexOf('仅在实时语音通话中可用') >= 0, guide);
    // 语音侧自我学习规程（与文字共用 save_memory 记忆通道）
    assert.ok(Kit.VOICE_TOOL_NOTE.indexOf('save_memory') >= 0, '语音缺自我学习指引');
    assert.ok(Kit.VOICE_TOOL_NOTE.indexOf('同一份长期记忆') >= 0, '语音指引未点明记忆共享');
  });

  test('语音工具面与文字统一：realtimeDefinitions 并入 MCP 动态工具，mcp_ 调用走统一路由', async () => {
    const mcp = [{ type: 'function', function: { name: 'mcp_es_search', description: '增强搜索', parameters: { type: 'object', properties: {} } } }];
    const defs = RealAiTools.realtimeDefinitions('confirm', mcp);
    assert.equal(defs.length, 31, '30（含 set_voice）+1 MCP');
    assert.equal(defs[defs.length - 1].function.name, 'mcp_es_search', 'MCP 并尾；set_voice 护栏位不前移');
    assert.ok(defs.some((d) => d.function.name === 'set_voice'));
    const ro = RealAiTools.realtimeDefinitions('readonly', mcp);
    assert.equal(ro.length, 18, '17+1 MCP');
    // 统一路由：语音 runTool 与文字回路同源 AiService.toolRunFor——mcp_ 前缀进 MCP 容错分支，
    // 不再落 dispatch 的「未知工具」（旧语音链路 mcp 调用必然失败的根因）
    const out = await RealAiService.toolRunFor('mcp_es_search', '{}', 'c1');
    assert.ok(typeof out === 'string' && out.length > 0);
    assert.ok(out.indexOf('未知工具') < 0, out);
    // 内置工具经同一路由仍达 dispatch（回归护栏：ask_user 语音侧兜底文案）
    const ask = await RealAiService.toolRunFor('ask_user', '{"question":"哪本?"}', 'c2');
    assert.ok(ask.indexOf('正文里直接问') >= 0, ask);
  });

  test('groupActivities 活动合并：相邻同名同标签并一条 ×N，状态聚合 doing>rejected，summary/books 取最后非空', async () => {
    const Model = await load('AiChatModel');
    const g = Model.groupActivities;
    const act = (name, label, state, summary = '', books = []) => ({ name, label, state, summary, books });
    assert.deepEqual(g([]), []);
    const one = g([act('search_web', '搜索网页', 'done', '3 条')]);
    assert.equal(one.length, 1);
    assert.equal(one[0].count, 1);
    const merged = g([act('search_web', '搜索网页', 'done', 'A'),
      act('search_web', '搜索网页', 'done', 'B'), act('fetch_url', '读取网页', 'done')]);
    assert.equal(merged.length, 2, '同名相邻合并，异名另起');
    assert.equal(merged[0].count, 2);
    assert.equal(merged[0].summary, 'B', 'summary 取组内最后非空');
    const diffLabel = g([act('search_web', '搜索一', 'done'), act('search_web', '搜索二', 'done')]);
    assert.equal(diffLabel.length, 2, '标签不同不合并（并行同工具不同任务各算一步）');
    assert.equal(g([act('add_to_shelf', '加入书架', 'done'), act('add_to_shelf', '加入书架', 'rejected')])[0].state,
      'rejected');
    assert.equal(g([act('x', 'X', 'doing'), act('x', 'X', 'done')])[0].state, 'doing', '任一在途即 doing');
    const bk = g([act('list_shelf', '查看书架', 'done', '', [{ title: 'A', subtitle: '', cover: '' }]),
      act('list_shelf', '查看书架', 'done', '', [{ title: 'B', subtitle: '', cover: '' }])]);
    assert.equal(bk[0].books[0].title, 'B');
  });
}
