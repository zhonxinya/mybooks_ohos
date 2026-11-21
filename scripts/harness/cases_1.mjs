// 用例组 1：对话页行为/服务配置/OpenCode/MdParse/设置页基础（拆分自 check_ai_assistant.mjs，用例体原样）
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { test, state, settingsDefaults, enc, rtB64, deferred, tick, flush } from './base.mjs';
import { dir, read, ETS, ROOT } from './paths.mjs';

export function register(ctx) {
  const { load, deps, RealAiService, RealAiTools, parseToolBookLines, toolsState, mdParseBlocks, mdParseInline, AI_SKILLS, AiAssistantPage, AiBookPanelPage, AiRecommendPage, AiSettingsPage, AiPersonaPage, AiPersona, DEFAULT_SOUL, AiChatStore, personaState, MetaSearchService, NovelMetaService, resetSettings, settingsPage, chat, reappear } = ctx;
  test('从模型设置返回时刷新三个 AI 页面的可用状态', () => {
    for (const Page of [AiAssistantPage, AiBookPanelPage, AiRecommendPage]) {
      const page = new Page();
      state.ready = true;
      page.onPageShow?.();
      assert.equal(page.configured, true, Page.name);
      state.ready = false;
      page.onPageShow?.();
      assert.equal(page.configured, false, Page.name);
    }
  });
  test('复制指定气泡而非最后一条回复', async () => {
    const page = chat();
    page.messages = [
      { role: 'assistant', content: '第一条', streaming: false, error: false },
      { role: 'assistant', content: '第二条', streaming: false, error: false },
    ];
    if (page.copyBubble) {
      await page.copyBubble(0);
    } else {
      await page.copyLast();
    }
    assert.equal(state.copied, '第一条');
  });
  test('停止生成会结束当前气泡，保留已收到文本', async () => {
    const page = chat();
    await page.send('问题');
    state.handlers.onDelta('部分回答');
    page.stopStreaming();
    assert.equal(page.thinking, false);
    assert.equal(page.messages.at(-1).streaming, false);
    assert.equal(page.messages.at(-1).content, '部分回答');
  });
  test('退出对话页不中断流式：后台完成落盘，重进页面即见完整回复', async () => {
    const page = chat();
    await page.send('问题');
    const handlers = state.handlers;
    handlers.onDelta('前半');
    page.aboutToDisappear();           // 曾经的 bug 触发点：切页即 abort
    const store = AiChatStore.instance();
    assert.equal(store.thinking, true, '退出页面后必须仍在生成');
    handlers.onDelta('后半');
    handlers.onDone('前半后半');
    assert.equal(store.thinking, false);
    const saved = JSON.parse(state.prefs.get('ai_chat_history'));
    assert.equal(saved.at(-1).content, '前半后半', '后台完成后照常落盘');
    const page2 = reappear();
    assert.equal(page2.messages.at(-1).content, '前半后半');
    assert.equal(page2.thinking, false);
  });
  test('思考过程：onReasoning 累积、finishBubble 固化并随历史持久化', async () => {
    const page = chat();
    const store = AiChatStore.instance();
    await page.send('问题');
    const handlers = state.handlers;
    handlers.onReasoning('让我想想。');
    handlers.onReasoning('先给结论。');
    assert.equal(store.streamingReasoning, '让我想想。先给结论。');
    handlers.onDelta('正文');
    handlers.onDone('正文');
    assert.equal(page.messages.at(-1).reasoning, '让我想想。先给结论。', '固化进气泡');
    assert.equal(store.streamingReasoning, '', '固化后重置');
    const saved = JSON.parse(state.prefs.get('ai_chat_history'));
    assert.equal(saved.at(-1).reasoning, '让我想想。先给结论。', '随历史落盘');
    const page2 = reappear();
    page2.store.loadHistory();
    assert.equal(page2.messages.at(-1).reasoning, '让我想想。先给结论。', '历史恢复');
  });
  test('思考过程：停止生成也固化已有思考', async () => {
    const page = chat();
    await page.send('问题');
    state.handlers.onReasoning('半截思考');
    page.stopStreaming();
    assert.equal(page.messages.at(-1).reasoning, '半截思考');
  });
  test('网关整包：parseGatewayReply 解析 reasoning_content', () => {
    const raw = JSON.stringify({ choices: [{ message: { role: 'assistant', content: '答', reasoning_content: '因为' } }] });
    const reply = RealAiService.parseGatewayReply(raw);
    assert.equal(reply.content, '答');
    assert.equal(reply.reasoning, '因为');
    const noThink = RealAiService.parseGatewayReply(JSON.stringify({ choices: [{ message: { content: 'x' } }] }));
    assert.equal(noThink.reasoning, '');
  });
  test('写闸门：页面不在场时确认一律按拒绝', async () => {
    const page = chat();
    await page.send('建个书单');
    page.aboutToDisappear();
    const ok = await state.handlers.onConfirm('创建书单', '{}');
    assert.equal(ok, false, '无视图在场不得执行写操作');
  });
  test('清空后迟到的流式回调不会污染新对话', async () => {
    const page = chat();
    await page.send('旧问题');
    const old = state.handlers;
    page.clearChat();
    old.onDone('旧回答');
    assert.deepEqual(page.messages, []);
    await page.send('新问题');
    const fresh = state.handlers;
    old.onDelta('迟到片段');
    old.onError('旧错误');
    assert.equal(page.messages.at(-1).content, '');
    assert.equal(page.thinking, true);
    assert.equal(page.errorTip, '');
  });
  test('生成中不能切换书籍面板的结果类型', async () => {
    const page = new AiBookPanelPage();
    state.ready = true;
    const response = deferred();
    state.summary = () => response.promise;
    const request = page.run('summary');
    await page.run('meta');
    assert.equal(page.activeTab, 0);
    response.resolve('摘要');
    await request;
    assert.equal(page.result, '摘要');
    assert.equal(page.loading, false);
  });
  test('偏好画像读取 authors 数组与逗号标签', async () => {
    const page = new AiRecommendPage();
    state.shelf = { books: [{ title: '书名', authors: ['作者甲', '作者乙'], tags: '科幻,悬疑' }] };
    const profile = await page.buildProfile();
    assert.deepEqual(profile.authors, ['作者甲', '作者乙']);
    assert.deepEqual(profile.tags, ['科幻', '悬疑']);
  });
  test('推荐命中必须核对书名与作者，而非搜索结果第一本', async () => {
    const page = new AiRecommendPage();
    const items = [{ title: '目标书', author: '正确作者', reason: '测试' }];
    page.items = items;
    page.matchedIds = [-1];
    state.search = async () => ({ body: { books: [
      { id: 1, title: '不相关书', authors: ['正确作者'] },
      { id: 2, title: '目标书', authors: ['另一作者'] },
      { id: 3, title: '《目标书》', authors: ['正确作者'] },
    ] } });
    await page.matchAll(items, page.requestId);
    assert.deepEqual(page.matchedIds, [3]);
  });
  test('重新生成后旧匹配请求不能覆盖新书单', async () => {
    const page = new AiRecommendPage();
    state.ready = true;
    state.shelf = { books: [{ title: '在架书', authors: ['作者'] }] };
    state.recommend = async () => [{ title: '旧推荐', author: '旧作者', reason: '旧' }];
    const old = deferred();
    state.search = (title) => title === '旧推荐' ? old.promise : Promise.resolve({ body: { books: [
      { id: 22, title: '新推荐', authors: ['新作者'] },
    ] } });
    await page.generate();
    state.recommend = async () => [{ title: '新推荐', author: '新作者', reason: '新' }];
    await page.generate();
    await tick();
    assert.deepEqual(page.matchedIds, [22]);
    old.resolve({ body: { books: [{ id: 11, title: '旧推荐', authors: ['旧作者'] }] } });
    await tick();
    assert.deepEqual(page.matchedIds, [22]);
  });

  test('服务：预设含 OpenCode (Go)，自定义服务商可增删且未知 id 兜底', () => {
    deps.state.store.clear();
    const base = RealAiService.listProviders();
    assert.ok(base.some((p) => p.id === 'opencode' && p.baseUrl === 'https://opencode.ai/zen/go/v1'));
    const preset = RealAiService.addCustomProvider('我的网关', 'https://example.com/v1/chat/completions', 'qwen3');
    assert.ok(preset.id.startsWith('custom-'));
    assert.equal(preset.baseUrl, 'https://example.com/v1');
    assert.equal(RealAiService.presetOf(preset.id).name, '我的网关');
    assert.equal(RealAiService.listProviders().length, base.length + 1);
    RealAiService.removeCustomProvider(preset.id);
    assert.equal(RealAiService.listProviders().length, base.length);
    assert.equal(RealAiService.presetOf('missing').id, 'custom');
  });
  test('服务：API Key 按服务商分存，旧单 Key 首次读取时迁移一次', () => {
    deps.state.store.clear();
    deps.state.store.set('s:ai_api_key', 'sk-legacy');
    const config = RealAiService.loadConfig();
    assert.equal(config.providerId, 'deepseek');
    assert.equal(config.hasKey, true);
    assert.equal(deps.state.store.get('s:ai_api_key'), undefined);
    assert.equal(RealAiService.apiKeyFor('deepseek'), 'sk-legacy');
    RealAiService.saveConfig('opencode', 'https://opencode.ai/inference/openai/v1', 'big-pickle', 'sk-oc', 0.5);
    assert.equal(RealAiService.apiKeyFor('opencode'), 'sk-oc');
    assert.equal(RealAiService.apiKeyFor('deepseek'), 'sk-legacy');
    const current = RealAiService.loadConfig();
    assert.equal(current.providerId, 'opencode');
    assert.equal(current.model, 'big-pickle');
    assert.equal(current.hasKey, true);
  });
  test('服务：fetchModels 去重保序、带鉴权头，4xx 走人话文案', async () => {
    deps.state.store.clear();
    deps.state.models = [{ id: 'b' }, { id: 'a' }, { id: 'b' }];
    deps.state.rcpResponse = null;
    const ids = await RealAiService.fetchModels('opencode', 'https://opencode.ai/inference/openai/v1/', 'sk-oc');
    assert.deepEqual(ids, ['b', 'a']);
    assert.equal(deps.state.lastRequest.url, 'https://opencode.ai/inference/openai/v1/models');
    assert.equal(deps.state.lastRequest.headers['Authorization'], 'Bearer sk-oc');
    const abuf = (s) => { const b = Buffer.from(s, 'utf8'); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); };
    deps.state.rcpResponse = { statusCode: 401, body: abuf('{"error":{"message":"bad key"}}') };
    await assert.rejects(() => RealAiService.fetchModels('opencode', 'https://opencode.ai/inference/openai/v1', 'sk-bad'), /401/);
    deps.state.rcpResponse = null;
    await assert.rejects(() => RealAiService.fetchModels('opencode', 'https://x/v1', ''), /API Key/);
    await assert.rejects(() => RealAiService.fetchModels('opencode', '', 'sk-oc'), /接口地址/);
  });
  test('OpenCode 网关：chatStream/complete 绕过 SDK 直连 rcp，携带 x-opencode-session，id 持久稳定', async () => {
    deps.state.store.clear();
    deps.state.chatCalls.length = 0;
    deps.state.rcpResponse = { statusCode: 200, body: (() => { const s = '{"choices":[{"message":{"content":"你好"}}]}'; const b = Buffer.from(s, 'utf8'); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); })() };
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'big-pickle', 'sk-oc', 0.5);
    let got = '';
    await new Promise((resolve, reject) => {
      RealAiService.chatStream([{ role: 'user', content: 'hi' }], {
        onDelta: (d) => { got += d; }, onDone: resolve, onError: reject,
      });
    });
    assert.equal(got, '你好');
    assert.equal(deps.state.lastRequest.url, 'https://opencode.ai/zen/go/v1/chat/completions');
    assert.equal(deps.state.lastRequest.headers['x-opencode-session'], 'test-uuid-fixed-0001');
    assert.equal(JSON.parse(deps.state.lastRequest.content).stream, false);
    assert.equal(deps.state.store.get('p:ai_opencode_session'), 'test-uuid-fixed-0001');
    assert.equal(deps.state.chatCalls.length, 0, 'opencode 不应走 SDK create');
    assert.equal(await RealAiService.complete([{ role: 'user', content: 'hi' }]), '你好');
    assert.equal(deps.state.lastRequest.headers['x-opencode-session'], 'test-uuid-fixed-0001');
    deps.state.rcpResponse = null;
  });
  test('非 OpenCode 网关：chat 走 SDK 流式，不携带自定义会话头', () => {
    deps.state.store.clear();
    deps.state.chatCalls.length = 0;
    RealAiService.saveConfig('deepseek', 'https://api.deepseek.com/v1', 'deepseek-chat', 'sk-d', 0.5);
    RealAiService.chatStream([{ role: 'user', content: 'hi' }], { onDelta: () => {}, onDone: () => {}, onError: () => {} });
    assert.equal(deps.state.chatCalls.length, 1);
    assert.equal(deps.state.chatCalls[0].options.requestConfiguration, undefined);
    assert.equal(deps.state.chatCalls[0].body.stream, true);
  });
  test('SDK 流式回路：tool_calls 分片累积→执行回填→终轮打字机（非网关服务商同享工具）', async () => {
    deps.state.store.clear();
    deps.state.chatCalls.length = 0;
    RealAiService.saveConfig('deepseek', 'https://api.deepseek.com/v1', 'deepseek-chat', 'sk-d', 0.5);
    deps.state.chatStreamRounds = [
      [
        { choices: [{ delta: { content: '先查' } }] },
        { choices: [{ delta: { content: '一下', tool_calls: [
          { index: 0, id: 'call_9', function: { name: 'search_books', arguments: '{"qu' } }] } }] },
        { choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: 'ery":"三体"}' } }] } }] },
      ],
      [
        { choices: [{ delta: { content: '找到' } }] },
        { choices: [{ delta: { content: '一本' } }] },
      ],
    ];
    deps.state.chatResponses = [{ statusCode: 200, body: enc('{}') },
      { statusCode: 200, body: enc('{}') }];
    const deltas = [];
    const activities = [];
    const errs = [];
    const handlers = {
      onDelta: (t) => { deltas.push(t); },
      onDone: () => {},
      onError: (e) => { errs.push(e); },
      onTool: (label) => { activities.push(label); },
      onToolResult: (name, label, text, callId) => { activities.push(`${label}:${text}:${callId}`); },
    };
    toolsState.search = async (q) => (q === '三体' ? [{ id: 12, title: '三体', authors: ['刘慈欣'] }] : []);
    RealAiService.chatStream([{ role: 'user', content: '搜三体' }], handlers);
    await flush();
    // 第一轮：挂 tools，正文分片打字机 + tool_calls 按 index 分片
    assert.equal(deps.state.chatCalls.length, 2, 'errs=' + JSON.stringify(errs));
    assert.equal(deps.state.chatCalls[0].body.stream, true);
    assert.ok(Array.isArray(deps.state.chatCalls[0].body.tools) &&
      deps.state.chatCalls[0].body.tools.length === 28, 'SDK 通道请求体须挂全量 tools');
    // 第二轮：assistant tool_calls + tool 结果回填，终轮回答
    const msgs = deps.state.chatCalls[1].body.messages;
    const asst = msgs.find((m) => m.role === 'assistant' && m.tool_calls !== undefined);
    assert.ok(asst !== undefined, '须回填 assistant(tool_calls)');
    assert.equal(asst.tool_calls[0].id, 'call_9');
    assert.equal(asst.tool_calls[0].function.name, 'search_books');
    assert.equal(asst.tool_calls[0].function.arguments, '{"query":"三体"}');
    const toolMsg = msgs.find((m) => m.role === 'tool');
    assert.ok(toolMsg !== undefined && toolMsg.tool_call_id === 'call_9' && toolMsg.content.includes('三体'),
      JSON.stringify(toolMsg));
    assert.deepEqual(activities, ['搜索书架', '搜索书架:找到 1 本：\n- 《三体》（刘慈欣） id=12:call_9']);
    // 打字机：两轮正文分片都直达 onDelta（工具轮正文在前，终轮在后），全文定稿不重复回调
    assert.equal(deltas.join(''), '先查一下找到一本');
    deps.state.chatStreamRounds = null;
    deps.state.chatResponses = [];
    deps.state.chatCalls.length = 0;
    toolsState.search = null;
  });

  test('流式回路防崩：缺 delta/负 index/巨 index/null chunk 不得逃逸异常（napi 回调=崩溃退出）', async () => {
    deps.state.store.clear();
    RealAiService.saveConfig('deepseek', 'https://api.deepseek.com/v1', 'deepseek-chat', 'sk-d', 0.5);
    deps.state.chatCalls.length = 0;
    deps.state.feedErrors.length = 0;
    deps.state.chatStreamRounds = [
      [
        { choices: [{}] },
        { choices: [{ finish_reason: 'stop' }] },
        { choices: [{ delta: { content: 'A' } }] },
        { choices: [{ delta: { tool_calls: [{ index: -1, id: 'call_x', function: { name: 'list_categories', arguments: '{}' } }] } }] },
        { choices: [{ delta: { tool_calls: [{ index: 100001, function: { arguments: '{}' } }] } }] },
        null,
        { choices: [] },
      ],
      [
        { choices: [{ delta: { content: 'done' } }] },
      ],
    ];
    deps.state.chatResponses = [{ statusCode: 200, body: enc('{}') }, { statusCode: 200, body: enc('{}') }];
    const deltas = [];
    const errs = [];
    const handlers = {
      onDelta: (t) => { deltas.push(t); },
      onDone: () => {},
      onError: (e) => { errs.push(e); },
      onTool: () => {},
      onToolResult: () => {},
    };
    RealAiService.chatStream([{ role: 'user', content: '崩溃测试' }], handlers);
    await flush();
    assert.deepEqual(deps.state.feedErrors, [], '回调异常逃逸=真机应用退出');
    assert.deepEqual(errs, [], '回路不得报错');
    // 非法 index 收编：负数入 0 槽、巨值并入末槽——slot 唯一且执行继续
    const msgs = deps.state.chatCalls[1].body.messages;
    const asst = msgs.find((m) => m.role === 'assistant' && m.tool_calls !== undefined);
    assert.ok(asst !== undefined, '须回填 assistant(tool_calls)');
    assert.equal(asst.tool_calls.length, 1, '槽位有界不膨胀');
    assert.equal(asst.tool_calls[0].id, 'call_x');
    assert.equal(asst.tool_calls[0].function.name, 'list_categories');
    assert.equal(deltas.join(''), 'Adone', '打字机不中断');
    deps.state.chatStreamRounds = null;
    deps.state.chatResponses = [];
    deps.state.chatCalls.length = 0;
    deps.state.feedErrors.length = 0;
  });

  test('OpenCode 网关：fetchModels 携带同一会话 id，非 opencode 不带', async () => {
    deps.state.store.clear();
    deps.state.store.set('p:ai_opencode_session', 'persisted-id');
    deps.state.models = [{ id: 'big-pickle' }];
    await RealAiService.fetchModels('opencode', 'https://opencode.ai/zen/go/v1', 'sk-oc');
    assert.equal(deps.state.lastRequest.headers['x-opencode-session'], 'persisted-id');
    await RealAiService.fetchModels('deepseek', 'https://api.deepseek.com/v1', 'sk-d');
    assert.equal(deps.state.lastRequest.headers['x-opencode-session'], undefined);
  });
  test('MdParse：标题/列表/代码块/表格/行内粗体与行内码', () => {
    const blocks = mdParseBlocks(
      '# 标题\n' +
      '段落里有 **粗体** 和 `code`。\n' +
      '- 项目一\n' +
      '- 项目二\n' +
      '1. 第一\n' +
      '2. 第二\n' +
      '```js\nconst a = 1;\n```\n' +
      '| 书 | 作者 |\n| --- | --- |\n| 三体 | 刘慈欣 |');
    assert.equal(blocks[0].kind, 'h');
    assert.equal(blocks[0].level, 1);
    assert.equal(blocks[0].segs[0][0].text, '标题');
    const para = blocks[1];
    assert.equal(para.kind, 'p');
    assert.deepEqual(para.segs[0].map((s) => [s.text, s.style]),
      [['段落里有 ', 0], ['粗体', 1], [' 和 ', 0], ['code', 2], ['。', 0]]);
    assert.equal(blocks[2].kind, 'ul');
    assert.equal(blocks[2].segs.length, 2);
    assert.equal(blocks[3].kind, 'ol');
    assert.equal(blocks[3].segs.length, 2);
    const code = blocks[4];
    assert.equal(code.kind, 'code');
    assert.equal(code.raw, 'const a = 1;');
    const table = blocks[5];
    assert.equal(table.kind, 'table');
    assert.deepEqual(table.rows, [['书', '作者'], ['三体', '刘慈欣']]);
  });
  test('MdParse：引用/分隔线/链接/斜体，代码块未闭合也兜底', () => {
    const blocks = mdParseBlocks('> 引用行\n---\n看 [官网](https://x.com) 里的 *强调*\n```\n未闭合');
    assert.equal(blocks[0].kind, 'quote');
    assert.equal(blocks[0].segs[0][0].text, '引用行');
    assert.equal(blocks[1].kind, 'hr');
    const link = blocks[2].segs[0];
    assert.deepEqual(link.map((s) => [s.text, s.style]),
      [['看 ', 0], ['官网', 3], [' 里的 ', 0], ['强调', 4]]);
    const code = blocks[3];
    assert.equal(code.kind, 'code');
    assert.equal(code.raw, '未闭合');
  });
  test('设置页：添加本地服务商有校验，成功后选中为当前编辑对象', () => {
    resetSettings();
    const page = settingsPage();
    page.newName = '';
    page.newBaseUrl = 'https://gw.example.com/v1';
    page.addProvider();
    assert.equal(page.providers.length, 2);
    page.newName = '我的网关';
    page.newBaseUrl = '';
    page.addProvider();
    assert.equal(page.providers.length, 2);
    page.newBaseUrl = 'https://gw.example.com/v1';
    page.newModel = 'qwen3';
    page.addProvider();
    assert.equal(page.providers.length, 3);
    assert.ok(page.isCustomSelected());
    assert.equal(page.baseUrl, 'https://gw.example.com/v1');
    assert.equal(page.model, 'qwen3');
    assert.equal(page.showAddForm, false);
  });
  test('设置页：切换服务商时已存 Key 保持、未存 Key 不误标', () => {
    resetSettings();
    state.settings.keys.add('opencode');
    const page = settingsPage();
    page.selectProvider('opencode');
    assert.equal(page.hasKey, true);
    page.selectProvider('deepseek');
    assert.equal(page.hasKey, true);
    page.selectProvider('siliconflow');
    assert.equal(page.hasKey, false);
    assert.equal(page.modelOptions.length, 0);
  });
  test('设置页：拉取模型列表点选填入，失败以文案提示而非静默', async () => {
    resetSettings();
    const page = settingsPage();
    state.settings.models = ['glm-4-flash', 'glm-4-plus'];
    await page.fetchModelList();
    assert.deepEqual(page.modelOptions, ['glm-4-flash', 'glm-4-plus']);
    // Select 数据源须覆盖全部拉取结果；当前模型不在列表时索引落在末尾（不越界即可）
    const items = page.modelSelectItems();
    assert.ok(items.length >= 2 && items.every((o) => typeof o.value === 'string'));
    assert.ok(items.some((o) => o.value === 'glm-4-plus'));
    page.model = page.modelOptions[1];
    assert.equal(page.modelSelectIndex(), 1);
    state.settings.models = [];
    state.settings.fetchError = 'API Key 无效或已过期（HTTP 401）';
    await page.fetchModelList();
    assert.equal(page.testOk, false);
    assert.match(page.testResult, /401/);
    assert.equal(page.fetchingModels, false);
  });

}
