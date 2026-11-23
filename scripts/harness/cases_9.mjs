// 用例组 9：对话 UI 精修 P2/P3 批（Token 用量/思考耗时/按住说话/只读工具缓存/功能专属模型槽；自 cases_1 拆出以过 800 行门禁）
import assert from 'node:assert/strict';
import { test, state, enc } from './base.mjs';

export function register(ctx) {
  const { load, deps, RealAiService, RealAiTools, AiChatStore, chat, providersPage, resetSettings } = ctx;

  test('Token 用量（#1514）：parseUsage 校验、mergeUsage 累加、整包解析、落盘往返、气泡固化', async () => {
    const model = await load('AiChatModel');
    assert.equal(model.parseUsage(undefined), null, '缺字段=null');
    assert.equal(model.parseUsage('x'), null, '非对象=null');
    assert.equal(model.parseUsage({ completion_tokens: 5 }), null, '无 total=null');
    const u = model.parseUsage({ prompt_tokens: 10, completion_tokens: 4, total_tokens: 14 });
    assert.deepEqual(u, { prompt: 10, completion: 4, total: 14 });
    const acc = { prompt: 0, completion: 0, total: 0 };
    model.mergeUsage(acc, u);
    model.mergeUsage(acc, u);
    assert.equal(acc.total, 28, '跨轮累加');
    assert.equal(acc.prompt, 20);
    // 整包通道：usage 顶层随 choices 一并解析
    const { RealAiService } = ctx;
    const r = RealAiService.parseGatewayReply(JSON.stringify({
      choices: [{ message: { content: 'x' } }],
      usage: { prompt_tokens: 7, completion_tokens: 3, total_tokens: 10 },
    }));
    assert.equal(r.usage.total, 10, '整包 usage');
    const rNo = RealAiService.parseGatewayReply(JSON.stringify({ choices: [{ message: { content: 'x' } }] }));
    assert.equal(rNo.usage, null, '服务商不回传=null');
    // 落盘往返：有 usage 恢复、无 usage 保持 undefined（不造零值假数据）
    const back = model.parseBubbles([{ role: 'assistant', content: 'a',
      usage: { prompt: 1, completion: 2, total: 3 } }]);
    assert.equal(back[0].usage.total, 3);
    const backOld = model.parseBubbles([{ role: 'assistant', content: 'a' }]);
    assert.equal(backOld[0].usage, undefined);
    // store 固化：onDone 第二参进气泡并落盘；错误轮无 usage
    const page = chat();
    const store = AiChatStore.instance();
    await page.send('用量问题');
    state.handlers.onDone('用量回答', { prompt: 100, completion: 20, total: 120 });
    assert.equal(store.messages[1].usage.total, 120, 'usage 固化进气泡');
    assert.ok(JSON.parse(state.prefs.get('ai_chat_history'))[1].usage.total === 120, 'usage 随历史落盘');
    assert.equal(page.sessionTokens(), 120, '页面累计=会话总和');
    await page.send('再来');
    state.handlers.onError('网络错误');
    assert.equal(store.messages[store.messages.length - 1].usage, undefined, '错误泡不带 usage');
    assert.equal(page.sessionTokens(), 120, '累计不受错误轮影响');
  });

  test('思考耗时（#1515）：formatThinkMs 边界、thinkMs 落盘往返、send 打点/固化/停止清零', async () => {
    const model = await load('AiChatModel');
    assert.equal(model.formatThinkMs(undefined), '', '无打点=空串不占位');
    assert.equal(model.formatThinkMs(0), '');
    assert.equal(model.formatThinkMs(299), '', '<300ms 不值得展示');
    assert.equal(model.formatThinkMs(320), '0.3s');
    assert.equal(model.formatThinkMs(350), '0.4s', '半档进位');
    assert.equal(model.formatThinkMs(60000), '1m0s', '整分钟进分秒格式');
    assert.equal(model.formatThinkMs(90500), '1m31s');
    // 落盘往返：有 thinkMs 恢复、旧存档保持 undefined（与 usage 同取舍）
    const back = model.parseBubbles([{ role: 'assistant', content: 'a', thinkMs: 1234 }]);
    assert.equal(back[0].thinkMs, 1234, 'thinkMs 随存档恢复');
    assert.equal(model.parseBubbles([{ role: 'assistant', content: 'a' }])[0].thinkMs, undefined);
    // store 轮次：send 打点 → finishBubble 在落盘前结算 → 随历史持久
    const page = chat();
    const store = AiChatStore.instance();
    await page.send('思考问题');
    assert.ok(store.thinkStartAt > 0, 'send 记录思考起点');
    store.thinkStartAt = Date.now() - 4200; // 伪环境无真实流逝，手动回拨起点
    state.handlers.onDone('思考回答');
    const ms = store.messages[1].thinkMs;
    assert.ok(ms >= 4200 && ms <= 4210, `结算耗时≈4200（实测 ${ms}）`);
    assert.equal(store.thinkStartAt, 0, '结算后清零');
    assert.ok(JSON.parse(state.prefs.get('ai_chat_history'))[1].thinkMs >= 4200, 'thinkMs 随历史落盘');
    // 错误轮不计量（与 usage 同语义）
    await page.send('再问');
    store.thinkStartAt = Date.now() - 1000;
    state.handlers.onError('网络错误');
    assert.equal(store.messages[store.messages.length - 1].thinkMs, undefined, '错误泡不带耗时');
    assert.equal(store.thinkStartAt, 0, '错误轮也清零');
    // 中途停止：拆表不计量，半截气泡不带 thinkMs
    await page.send('长答');
    store.thinkStartAt = Date.now() - 5000;
    store.stopStreaming();
    assert.equal(store.thinkStartAt, 0, '停止拆表');
    assert.equal(store.messages[store.messages.length - 1].thinkMs, undefined, '停止轮不计量');
  });

  test('按住说话（#1516）：appendHeardText 拼接与 holdStart/holdFinish 链路', async () => {
    const model = await load('AiChatModel');
    assert.equal(model.appendHeardText('', ' 你好 '), '你好', '空输入去首尾空白');
    assert.equal(model.appendHeardText('有什么书', '推荐本科幻'), '有什么书 推荐本科幻', '空格相接不覆盖');
    assert.equal(model.appendHeardText('a', '   '), 'a', '空识别保留原文');
    const page = chat();
    assert.equal(page.holdPlaceholder(), '输入问题');
    // 正常轮：按下开录→松手识别→并入输入框（不自动发送）
    state.hold.wav = 'QUJDRA==';
    state.hold.text = '推荐一本科幻小说';
    await page.holdStart();
    assert.equal(state.hold.starts, 1, '按下开录');
    assert.equal(page.holdRecording, true);
    assert.equal(page.holdPlaceholder(), '聆听中…松手转文字');
    await page.holdFinish();
    assert.equal(state.hold.b64s.length, 1, '录音送 ASR');
    assert.equal(page.input, '推荐一本科幻小说', '识别进输入框');
    assert.equal(page.holdBusy, false, '识别态归位');
    // 追加不覆盖已有文本
    page.input = '顺便,';
    await page.holdStart();
    await page.holdFinish();
    assert.equal(page.input, '顺便, 推荐一本科幻小说');
    // 静音：不白调识别，有提示
    state.hold.wav = '';
    await page.holdStart();
    await page.holdFinish();
    assert.equal(state.hold.b64s.length, 2, '无录音不送识别');
    assert.equal(state.lastToast, '没听到声音，请再试一次');
    // 识别抛错：busy 归位、文本不动
    page.input = '顺便,';
    state.hold.wav = 'QUJDRA==';
    state.hold.asrErr = true;
    await page.holdStart();
    await page.holdFinish();
    assert.equal(page.input, '顺便,', '出错不改文本');
    assert.equal(page.holdBusy, false, '出错 busy 归位');
    state.hold.asrErr = false;
    // 权限拒绝：不进录音态
    state.micGrant = false;
    await page.holdStart();
    assert.equal(page.holdRecording, false, '拒绝授权不开录');
    assert.equal(state.lastToast, '请在系统设置中允许麦克风权限后重试');
    state.micGrant = true;
    // 生成中禁用（与发送键互斥语义一致）
    await page.send('生成中');
    await page.holdStart();
    assert.equal(page.holdRecording, false, 'thinking 期不录音');
    state.handlers.onDone('完毕');
    // 入口门控：语音档非 Token Plan 不显示按钮
    assert.equal(chat().holdTalkReady, false, '无云端 ASR 档藏入口');
  });

  test('只读工具缓存（#1517）：白名单、归一键、命中零请求、失败不固化、FIFO 上限', async () => {
    assert.equal(RealAiTools.isCacheable('search_web'), true);
    assert.equal(RealAiTools.isCacheable('mcp_web_search'), true, 'mcp 动态工具全家');
    assert.equal(RealAiTools.isCacheable('search_books'), false, '书目侧信道类不缓存');
    assert.equal(RealAiTools.isCacheable('list_download_tasks'), false, '进度语义类不缓存');
    assert.equal(RealAiTools.isCacheable('add_to_shelf'), false, '写工具不缓存');
    // 归一键：参数同义不同序等价；坏 JSON 原样退化
    assert.equal(RealAiTools.toolCacheKey('t', '{"b":2,"a":1}'),
      RealAiTools.toolCacheKey('t', '{"a":1,"b":2}'), '键序无关');
    assert.notEqual(RealAiTools.toolCacheKey('t', 'not json'),
      RealAiTools.toolCacheKey('t', 'other'), '坏 JSON 按原文区分');
    // FIFO 上限：24 封顶，最旧出局
    RealAiTools.clearToolCache();
    for (let i = 0; i < 25; i++) {
      RealAiTools.rememberCache(`k${i}`, `v${i}`);
    }
    assert.equal(RealAiTools.toolCache.size, 24, '上限 24');
    assert.equal(RealAiTools.toolCache.has('k0'), false, '最旧被逐');
    assert.equal(RealAiTools.toolCache.get('k24').text, 'v24');
    // 端到端：真发一次→同参再调命中零请求（本用例内开缓存）
    RealAiTools.cacheDisabled = false;
    try {
      const html = '<html><head><title>缓存页</title></head><body><p>正文段落。</p></body></html>';
      deps.state.rcpError = null;
      deps.state.rcpResponses = [{ statusCode: 200, body: enc(html) }];
      const before = deps.state.requests.length;
      const first = await RealAiTools.execute('fetch_url', '{"url":"https://example.com/cached"}');
      assert.ok(first.includes('《缓存页》') && !first.includes('[缓存复用]'), first);
      assert.equal(deps.state.requests.length, before + 1);
      const second = await RealAiTools.execute('fetch_url', '{"url":"https://example.com/cached"}');
      assert.ok(second.startsWith('[缓存复用]'), `命中须带标注：${second}`);
      assert.equal(deps.state.requests.length, before + 1, '缓存命中不发网络请求');
      // 瞬时失败轮不固化：恢复后重试是真执行
      deps.state.rcpError = new Error('connection reset by peer');
      const errText = await RealAiTools.execute('fetch_url', '{"url":"https://example.com/err"}');
      assert.ok(errText.includes('失败'), `网络异常应回失败文本：${errText}`);
      assert.equal(deps.state.rcpResponses.length, 0);
      deps.state.rcpError = null;
      deps.state.rcpResponses = [{ statusCode: 200, body: enc(html) }];
      const after = await RealAiTools.execute('fetch_url', '{"url":"https://example.com/err"}');
      assert.ok(!after.includes('[缓存复用]') && after.includes('《缓存页》'), '失败不钉，重试可达');
      RealAiTools.clearToolCache();
      // 不同参数不互扰
      deps.state.rcpResponses = [{ statusCode: 200, body: enc(html) }, { statusCode: 200, body: enc(html) }];
      await RealAiTools.execute('fetch_url', '{"url":"https://example.com/a"}');
      await RealAiTools.execute('fetch_url', '{"url":"https://example.com/b"}');
      assert.equal(deps.state.rcpResponses.length, 0, '两个 URL 各自真执行');
    } finally {
      RealAiTools.cacheDisabled = true;
    }
  });

  test('缓存 TTL/LRU（#1648）：时效 15min 元数据 6h，过期重查、命中提升不被逐、写前清死条目', async () => {
    assert.equal(RealAiTools.toolCacheTtl('search_web'), 15 * 60 * 1000);
    assert.equal(RealAiTools.toolCacheTtl('mcp_web_search'), 15 * 60 * 1000, 'mcp 走时效默认');
    assert.equal(RealAiTools.toolCacheTtl('search_meta'), 6 * 60 * 60 * 1000);
    assert.equal(RealAiTools.toolCacheTtl('search_encyclopedia'), 6 * 60 * 60 * 1000, '百科词条静态长存');
    let fakeNow = 1000000;
    RealAiTools.nowFn = () => fakeNow;
    RealAiTools.cacheDisabled = false;
    try {
      RealAiTools.clearToolCache();
      const html = '<html><head><title>TTL页</title></head><body><p>正文。</p></body></html>';
      deps.state.rcpError = null;
      deps.state.rcpResponses = [{ statusCode: 200, body: enc(html) }, { statusCode: 200, body: enc(html) }];
      const before = deps.state.requests.length;
      await RealAiTools.execute('fetch_url', '{"url":"https://example.com/ttl"}');
      assert.equal(deps.state.requests.length, before + 1);
      // TTL 内命中零请求
      fakeNow += 14 * 60 * 1000;
      const hit = await RealAiTools.execute('fetch_url', '{"url":"https://example.com/ttl"}');
      assert.ok(hit.startsWith('[缓存复用]'), `TTL 内应命中：${hit}`);
      assert.equal(deps.state.requests.length, before + 1, 'TTL 内不发请求');
      // 越过 TTL 重查（15min 已过）
      fakeNow += 2 * 60 * 1000;
      const miss = await RealAiTools.execute('fetch_url', '{"url":"https://example.com/ttl"}');
      assert.ok(!miss.includes('[缓存复用]') && miss.includes('TTL页'), `过期应重查：${miss.slice(0, 40)}`);
      assert.equal(deps.state.requests.length, before + 2, '过期条目必须重取');
      // LRU：命中把条目提升到尾，后续写满上限逐的是最旧而非热点
      RealAiTools.clearToolCache();
      deps.state.rcpResponses = [{ statusCode: 200, body: enc(html) }];
      await RealAiTools.execute('fetch_url', '{"url":"https://example.com/hot"}');
      for (let i = 0; i < 23; i++) {
        RealAiTools.rememberCache(`k${i}`, `v${i}`);
      }
      await RealAiTools.execute('fetch_url', '{"url":"https://example.com/hot"}'); // 命中→提升到尾
      const hotKey = RealAiTools.toolCacheKey('fetch_url', '{"url":"https://example.com/hot"}');
      RealAiTools.rememberCache('newer', 'v'); // 满 24 逐最旧（k0），热点幸存
      assert.equal(RealAiTools.toolCache.size, 24);
      assert.equal(RealAiTools.toolCache.has(hotKey), true, '热点条目命中后不得被逐');
      assert.equal(RealAiTools.toolCache.has('k0'), false, '最旧被逐');
      assert.equal(RealAiTools.toolCache.has('newer'), true);
      // 写前清扫：全部过期后一次写入不留 24 个死位
      RealAiTools.clearToolCache();
      for (let i = 0; i < 24; i++) {
        RealAiTools.rememberCache(`x${i}`, 'y');
      }
      fakeNow += 60 * 60 * 1000; // 时效类 15min 全过期
      RealAiTools.rememberCache('fresh', 'new');
      assert.equal(RealAiTools.toolCache.size, 1, '写入须先清过期条目');
    } finally {
      RealAiTools.nowFn = null;
      RealAiTools.cacheDisabled = true;
      RealAiTools.clearToolCache();
    }
  });

  test('功能专属模型槽（#1600）：voice 键兼容、音频三件回退链、绑定独立、解绑跟随', async () => {
    deps.state.store.clear();
    RealAiService.saveConfig('deepseek', 'https://api.deepseek.com/v1', 'deepseek-chat', 'sk-d', 0.5);
    // 未绑功能档 = 全局
    assert.equal(RealAiService.loadFeatureConfig('vision').providerId, 'deepseek');
    assert.equal(RealAiService.hasFeatureProvider('vision'), false);
    // voice = 历史键零迁移：saveVoiceConfig 即绑 'voice' 功能档
    RealAiService.saveVoiceConfig('qwen-tokenplan', 'qwen3.6-flash');
    assert.equal(RealAiService.loadFeatureConfig('voice').providerId, 'qwen-tokenplan', 'voice 槽读旧键');
    assert.equal(RealAiService.loadFeatureProviderId('voice'), 'qwen-tokenplan');
    assert.equal(RealAiService.loadVoiceConfig().model, RealAiService.loadFeatureConfig('voice').model,
      '兼容层与泛化层等价');
    // 音频三件未绑退 voice（voice 再退全局的链在兼容用例已覆盖）
    assert.equal(RealAiService.loadFeatureConfig('asr').providerId, 'qwen-tokenplan', 'asr 未绑退语音档');
    assert.equal(RealAiService.loadFeatureConfig('tts').model, 'qwen3.6-flash');
    // 绑定后独立解析（voice 保持另一模型）
    RealAiService.saveFeatureConfig('asr', 'opencode', 'asr-custom');
    assert.equal(RealAiService.loadFeatureConfig('asr').providerId, 'opencode');
    assert.equal(RealAiService.loadFeatureModel('asr'), 'asr-custom');
    assert.equal(RealAiService.loadFeatureConfig('realtime').providerId, 'qwen-tokenplan', 'realtime 仍退 voice');
    // 解绑 = 恢复跟随
    RealAiService.saveFeatureConfig('asr', '', '');
    assert.equal(RealAiService.hasFeatureProvider('asr'), false);
    assert.equal(RealAiService.loadFeatureConfig('asr').providerId, 'qwen-tokenplan');
    // 非音频档绑定后与 voice 无关（vision 绑 ollama 不影响语音档）
    RealAiService.saveFeatureConfig('vision', 'ollama', 'llava');
    assert.equal(RealAiService.loadFeatureConfig('vision').baseUrl, 'http://127.0.0.1:11434/v1');
    assert.equal(RealAiService.loadFeatureConfig('voice').providerId, 'qwen-tokenplan');
    deps.state.store.clear();
    // store 消费链（shim 语义）：带图轮 chatStream 收到 vision 档、纯文本轮无 override
    const page = chat();
    const store = AiChatStore.instance();
    await store.send('纯文本', []);
    assert.equal(state.settings.lastChatOverride, undefined, '文本轮不传功能档');
    state.handlers.onDone('好');
    state.settings.providers.push({ id: 'ollama', name: 'Ollama', baseUrl: 'http://127.0.0.1:11434/v1',
      model: 'llama3', hasKey: false });
    state.settings.featureSlots.vision = { providerId: 'ollama', model: 'llava' };
    store.visionEnabled = true; // 视觉开关是前置门（关=图不进 bubbleImages，功能档无从触发）
    await store.send('看图', ['/tmp/pic.png']);
    assert.equal(state.settings.lastChatOverride.providerId, 'ollama', '带图轮走绑定档');
    state.handlers.onDone('图好');
    // 摘要压缩走 summary 档：塞满触发阈值轮次后断言 complete 收到的 config
    state.settings.featureSlots.summary = { providerId: 'ollama', model: 'qwen2.5:7b' };
    for (let i = 0; i < 16; i++) {
      await store.send(`第${i}问`, []);
      state.handlers.onDone(`第${i}答，内容足够长以触发窗口外判定xxxxxxxxxxxx`);
    }
    await store.compressHistory();
    assert.equal(state.settings.lastCompleteConfig.providerId, 'ollama', '摘要吃绑定档');
  });

  test('服务商并行（#1612）：模型分槽互不覆盖、启停过滤、profile 不改默认、旧全局模型迁移', async () => {
    deps.state.store.clear();
    // 模型按服务商分槽：切回不丢
    RealAiService.saveConfig('deepseek', 'https://api.deepseek.com/v1', 'deepseek-chat', 'sk-d', 0.5);
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'glm-4.7', 'sk-o', 0.5);
    assert.equal(RealAiService.modelFor('deepseek'), 'deepseek-chat', '各家记住自己的模型');
    assert.equal(RealAiService.modelFor('opencode'), 'glm-4.7');
    assert.equal(RealAiService.loadConfig().providerId, 'opencode', '最后保存者即默认');
    // 管理页编辑资产：不动当前默认；Key 留空=保持已存
    RealAiService.updateProviderProfile('lmstudio', 'http://192.168.31.160:1234/v1', 'qwen3:4b', 'sk-l');
    assert.equal(RealAiService.loadConfig().providerId, 'opencode', '编辑不改默认');
    assert.equal(RealAiService.modelFor('lmstudio'), 'qwen3:4b');
    assert.equal(RealAiService.hasKeyFor('lmstudio'), true);
    RealAiService.updateProviderProfile('lmstudio', 'http://192.168.31.160:1234/v1', 'qwen3:4b', '');
    assert.equal(RealAiService.hasKeyFor('lmstudio'), true, 'Key 留空保持');
    // 启停：enabled 清单过滤，全量清单仍含（管理页可见）
    RealAiService.setProviderEnabled('opencode', false);
    assert.equal(RealAiService.isProviderEnabled('opencode'), false);
    assert.equal(RealAiService.listEnabledProviders().some((p) => p.id === 'opencode'), false);
    assert.equal(RealAiService.listProviders().some((p) => p.id === 'opencode'), true, '管理页仍可见');
    RealAiService.setProviderEnabled('opencode', true);
    assert.equal(RealAiService.listEnabledProviders().some((p) => p.id === 'opencode'), true);
    // 设为默认只切选择
    RealAiService.setDefaultProvider('opencode');
    assert.equal(RealAiService.loadConfig().providerId, 'opencode');
    // 旧版全局单槽模型一次性迁移进当前家
    deps.state.store.clear();
    deps.state.store.set('p:ai_provider', 'deepseek');
    deps.state.store.set('p:ai_model', 'legacy-m');
    assert.equal(RealAiService.modelFor('deepseek'), 'legacy-m', '旧模型挪进本家槽');
    assert.equal(deps.state.store.get('p:ai_model'), '', '旧键清空不重复迁');
    deps.state.store.clear();
    // 管理页：默认家不可停用、编辑保存写对槽
    resetSettings();
    const page = providersPage();
    assert.equal(page.all.some((p) => p.id === 'custom'), false, 'custom 占位不生成卡片');
    page.currentId = 'deepseek';
    page.toggleEnabled('deepseek', false);
    assert.equal(state.settings.providerDisabled.deepseek, undefined, '默认家不能停用');
    page.toggleEnabled('opencode', false);
    assert.equal(state.settings.providerDisabled.opencode, true);
    page.enterEdit('opencode');
    page.editModel = 'glm-5';
    page.editKey = 'sk-new';
    page.saveProfile();
    assert.equal(state.settings.modelSlots.opencode, 'glm-5');
    assert.equal(state.settings.keys.has('opencode'), true);
    assert.equal(state.settings.defaultProviderId, '', '编辑保存不动默认');
    resetSettings();
  });

}
