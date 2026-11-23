// 用例组 1：对话页行为/服务配置/OpenCode/MdParse/设置页基础（拆分自 check_ai_assistant.mjs，用例体原样）
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { test, state, settingsDefaults, enc, rtB64, deferred, tick, flush } from './base.mjs';
import { dir, read, ETS, ROOT } from './paths.mjs';

export function register(ctx) {
  const { load, deps, RealAiService, RealAiTools, parseToolBookLines, toolsState, mdParseBlocks, mdParseInline, collectLinks, linkHost, mdAppendCaret, AI_SKILLS, AiAssistantPage, AiBookPanelPage, AiRecommendPage, AiSettingsPage, AiPersonaPage, AiPersona, DEFAULT_SOUL, AiChatStore, personaState, MetaSearchService, NovelMetaService, resetSettings, settingsPage, providersPage, chat, reappear } = ctx;
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
  test('流式增量通知节流：首帧跟手、尾帧补齐；终态后迟到尾帧作废', async () => {
    const page = chat();
    const store = AiChatStore.instance();
    let syncs = 0;
    const orig = page.syncFromStore.bind(page);
    page.syncFromStore = () => { syncs++; orig(); };
    await page.send('问题');
    const base = syncs;
    for (let i = 0; i < 50; i++) {
      state.handlers.onDelta('字');
    }
    assert.equal(syncs, base + 1, '50 个增量只允许首帧立即通知，其余并进窗口');
    assert.equal(store.streamingText.length, 50, '合并只减通知次数，不减内容');
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(syncs, base + 2, '窗口结束补一次尾帧通知');
    for (let i = 0; i < 20; i++) {
      state.handlers.onDelta('字');
    }
    assert.equal(syncs, base + 3, '新一轮窗口再起首帧');
    state.handlers.onDone('字'.repeat(70));
    assert.equal(syncs, base + 4, '终态立即通知，不等窗口');
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(syncs, base + 4, '终态必须取消在途尾帧，不得迟到重建');
    assert.equal(page.thinking, false);
    assert.equal(page.messages.at(-1).content, '字'.repeat(70));
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
      deps.state.chatCalls[0].body.tools.length === 33, 'SDK 通道请求体须挂全量 tools');
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
  test('MdParse #1511：href 保留、collectLinks 去重、linkHost 展示副标', () => {
    const lines = mdParseBlocks(
      '先看 [官网](https://a.example.com/x?y=1)\n再看 [官网](https://a.example.com/x?y=1) 与 [讨论]( https://b.example.com )')[0].segs;
    const links = collectLinks(lines);
    assert.equal(links.length, 2);
    assert.equal(links[0].href, 'https://a.example.com/x?y=1');
    assert.equal(links[1].text, '讨论');
    assert.equal(links[1].href, 'https://b.example.com');
    assert.equal(linkHost('https://a.example.com/x?y=1'), 'a.example.com');
    assert.equal(linkHost('http://b.example.com#frag'), 'b.example.com');
    assert.equal(linkHost('example.org/path'), 'example.org');
    // 无 href 的旧样式段不进清单（历史数据/裸着色段不炸）
    assert.deepEqual(collectLinks([[{ text: '裸链样式', style: 3 }]]), []);
  });
  test('MdParse #1622：mdAppendCaret 只在可行内块尾行注入光标 seg，h/code/table/hr/空不注入', () => {
    // p 多行：只追加到整个文档**末块的最后一行**行尾
    const b1 = mdParseBlocks('第一段\n第二段');
    mdAppendCaret(b1);
    assert.equal(b1[0].segs[1].at(-1).text, '▌');
    assert.equal(b1[0].segs[1].at(-1).style, 5);
    assert.equal(b1[0].segs[0].some((s) => s.style === 5), false, '非尾行不注入');
    // 多块：注入落在末块（ul），前面的 p 块不碰
    const b1b = mdParseBlocks('第一段\n\n- 列表甲\n- 列表乙');
    mdAppendCaret(b1b);
    assert.equal(b1b[1].segs[1].at(-1).text, '▌', '末块（ul 末项）注入');
    assert.equal(b1b[0].segs[0].some((s) => s.style === 5), false, '非末块不注入');
    // 光标可跟在粗体段后（追加而非合并）
    const b3 = mdParseBlocks('看 **重点**');
    mdAppendCaret(b3);
    assert.deepEqual(b3[0].segs[0].map((s) => s.style), [0, 1, 5]);
    // 收尾在 h/code/table/hr：不注入（避免黑光标/污染块解析）
    for (const src of ['## 标题', '```\ncode\n```', '| a | b |\n|---|---|\n| 1 | 2 |', '---']) {
      const bb = mdParseBlocks(src);
      mdAppendCaret(bb);
      assert.equal(bb.some((blk) => blk.segs.some((l) => l.some((s) => s.style === 5))), false, src);
    }
    // 空文档 no-op 不炸
    mdAppendCaret([]);
    // quote 注入
    const b5 = mdParseBlocks('> 引用');
    mdAppendCaret(b5);
    assert.equal(b5[0].segs[0].at(-1).text, '▌');
    // 回归面：注入不改任何既有 seg 文本（旧实现拼进 content 会改块 raw/长度）
    assert.equal(b1[0].segs[1][0].text, '第二段');
  });
  test('服务商管理页：添加自定义服务商有校验，成功后出现在清单', () => {
    resetSettings();
    // 增删服务商已从 AI 设置页迁到「服务商管理」页（设置页只留快切与编辑）
    const page = providersPage();
    page.newName = '';
    page.newBaseUrl = 'https://gw.example.com/v1';
    page.addProvider();
    assert.equal(page.all.length, 2, '名称为空不添加');
    page.newName = '我的网关';
    page.newBaseUrl = '';
    page.addProvider();
    assert.equal(page.all.length, 2, '地址为空不添加');
    page.newBaseUrl = 'https://gw.example.com/v1';
    page.newModel = 'qwen3';
    page.addProvider();
    assert.equal(page.all.length, 3, '合法输入后加入清单');
    assert.ok(page.all.some((p) => p.name === '我的网关'), '新服务商在清单里');
    assert.equal(page.showAdd, false, '表单收起');
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

  test('流式气泡自订阅：store 变化扇出 StreamBubble 回调，detach 后停发', async () => {
    const page = chat();
    const store = AiChatStore.instance();
    let h1 = 0;
    let h2 = 0;
    let text1 = '';
    const t1 = store.attachStreamView(() => { h1++; text1 = store.streamingText; });
    const t2 = store.attachStreamView(() => { h2++; });
    await page.send('问题');
    const b1 = h1;
    const b2 = h2;
    state.handlers.onDelta('一');
    assert.equal(h1, b1 + 1, '增量首帧扇出到自订阅回调');
    assert.equal(h2, b2 + 1, '多个 StreamBubble 同帧齐动');
    assert.equal(text1, '一', '回调读到的是已累积的增量内容');
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(h1, b1 + 2, '尾帧同样扇出');
    store.detachStreamView(t2);
    const frozen = h2;
    state.handlers.onDelta('二');
    state.handlers.onDone('一二');
    assert.equal(h2, frozen, 'detach 后不再派发（离场组件不泄漏）');
    assert.ok(h1 > b1 + 2, '在订阅者照常收到后续通知');
    store.detachStreamView(t1);
  });

  test('文字流式气泡 key 整轮恒定；固化/语音/错误回归覆盖式 key', () => {
    const page = new AiAssistantPage();
    const streaming = { role: 'assistant', content: '', streaming: true, error: false, activities: [] };
    const k0 = page.bubbleKey(streaming, 2);
    assert.equal(k0, 'bubble-2-assistant-s');
    streaming.content = '打字机字';
    streaming.activities.push({ name: 'search_web', label: '搜索', state: 'done' });
    assert.equal(page.bubbleKey(streaming, 2), k0, '流式增量不得改 key，否则整泡销毁重挂');
    streaming.streaming = false;
    assert.notEqual(page.bubbleKey(streaming, 2), k0, '固化后换 key，触发一次重建显示固化数据');
    const voice = { role: 'assistant', content: '字幕', streaming: true, error: false, activities: [], voice: true };
    assert.notEqual(page.bubbleKey(voice, 2), 'bubble-2-assistant-s', '语音字幕气泡仍走内容长度 key');
    const err = { role: 'assistant', content: '挂', streaming: true, error: true, activities: [] };
    assert.notEqual(page.bubbleKey(err, 2), 'bubble-2-assistant-s', '错误气泡不进恒定分支');
    err.content = '挂了更长的错误文案';
    assert.notEqual(page.bubbleKey(err, 2), page.bubbleKey({ ...err, content: '短' }, 2), '错误气泡 key 仍覆盖内容长度');
    const user = { role: 'user', content: '问', streaming: false, error: false, activities: [] };
    assert.equal(page.bubbleKey(user, 3), 'bubble-3-user-d-0-1-0-0-');
  });

  test('智能跟滚：上滑离底暂停自动滚动；回底/浮钮/新消息恢复；微小滑动不误判', async () => {
    const page = chat();
    let scrolls = 0;
    page.scrollToEnd = () => { scrolls++; };
    page.scroller = { isAtEnd: () => false };
    await page.send('问题');
    assert.ok(scrolls >= 1, '发消息必须滚动跟随');
    state.handlers.onDelta('字');
    const following = scrolls;
    assert.ok(following >= 2, '跟随时增量滚动');
    // 手指明显下滑（内容上移露历史）→ 脱离跟随
    page.onListTouch({ type: globalThis.TouchType.Down, touches: [{ y: 100 }] });
    page.onListTouch({ type: globalThis.TouchType.Move, touches: [{ y: 200 }] });
    assert.equal(page.followBottom, false, '上滑读历史应脱离跟随');
    state.handlers.onDelta('字');
    state.handlers.onDelta('字');
    assert.equal(scrolls, following, '离底期生成不得抢滚');
    state.handlers.onDone('全文');
    assert.equal(scrolls, following, '离底期收尾也不得强滚');
    // 停滚恢复：仅视图真在底缘才恢复
    page.onListScrollStop();
    assert.equal(page.followBottom, false, '未到底不误恢复');
    page.scroller = { isAtEnd: () => true };
    page.onListScrollStop();
    assert.equal(page.followBottom, true, '滑回底部恢复跟随');
    // 24px 噪声阈值内不脱跟随
    page.onListTouch({ type: globalThis.TouchType.Down, touches: [{ y: 100 }] });
    page.onListTouch({ type: globalThis.TouchType.Move, touches: [{ y: 120 }] });
    assert.equal(page.followBottom, true, '轻微抖动不误判为读历史');
    // 浮钮回底
    page.onListTouch({ type: globalThis.TouchType.Move, touches: [{ y: 400 }] });
    assert.equal(page.followBottom, false);
    const before = scrolls;
    page.backToBottom();
    assert.equal(page.followBottom, true, '点浮钮立即恢复跟随');
    assert.equal(scrolls, before + 1, '浮钮滚动不受门控');
    // 离底期发新消息强制回跟随
    page.onListTouch({ type: globalThis.TouchType.Move, touches: [{ y: 900 }] });
    assert.equal(page.followBottom, false);
    await page.send('再来');
    assert.equal(page.followBottom, true, '新消息必回跟随最新');
  });

  test('长按菜单：状态化选项 + 删除单条落盘 + 编辑重发截断回填', async () => {
    const page = chat();
    const store = AiChatStore.instance();
    await page.send('第一个问题');
    state.handlers.onDone('回答一');
    // kinds：最新 assistant=复制/删除/重新生成；user=复制/编辑/删除
    assert.deepEqual(page.bubbleMenuKinds(store.messages[1], 1), ['copy', 'delete', 'regen']);
    assert.deepEqual(page.bubbleMenuKinds(store.messages[0], 0), ['copy', 'edit', 'delete']);
    const voice = { role: 'assistant', content: '语音', streaming: false, error: false, activities: [], voice: true };
    assert.ok(!page.bubbleMenuKinds(voice, 3).includes('regen'), '语音轮不走文字重生成');
    const err = { role: 'assistant', content: '失败', streaming: false, error: true, activities: [] };
    assert.deepEqual(page.bubbleMenuKinds(err, 1), ['copy', 'delete'], '错误气泡仅复制/删除');
    assert.deepEqual(page.bubbleMenuKinds({ role: 'assistant', content: '', streaming: true, error: false, activities: [] }, 2), [],
      '流式期不响应长按');
    assert.equal(store.editResend(1), '', 'assistant 气泡不可编辑重发');
    // 删除单条 + 持久化同步
    store.deleteBubble(1);
    assert.equal(store.messages.length, 1);
    assert.equal(JSON.parse(state.prefs.get('ai_chat_history')).length, 1, '删除必须落盘');
    store.deleteBubble(99);
    assert.equal(store.messages.length, 1, '越界拒绝');
    // 生成期守卫：流式气泡不可删、编辑重发拒绝
    await page.send('第二个问题');
    assert.equal(store.editResend(0), '', '生成中不得编辑重发');
    store.deleteBubble(2);
    assert.equal(store.messages.length, 3, '流式气泡不可删（copy/edit/delete+streaming 后长度 3）');
    state.handlers.onDone('回答二');
    // 编辑重发成功路径：截断该 user 及其后全部，返回原文；页面动作回填输入框
    const userIdx = store.messages.findIndex((m) => m.role === 'user' && m.content === '第二个问题');
    assert.ok(userIdx > 0);
    page.input = '';
    page.runMenuAction('edit', userIdx);
    assert.equal(page.input, '第二个问题', '编辑重发回填输入框');
    assert.equal(store.messages.length, userIdx, '该消息及之后全部抹掉');
    assert.equal(JSON.parse(state.prefs.get('ai_chat_history')).length, userIdx, '截断落盘');
  });

  test('讨论本书：buildContext 注入/可选字段省略/清除', async () => {
    chat();
    const store = AiChatStore.instance();
    const notes = async () => (await store.buildContext()).filter((m) => `${m.content}`.includes('用户正在阅读'));
    assert.equal((await notes()).length, 0, '无书不注入');
    store.setBookContext('三体', '刘慈欣', '第 10 章');
    let ctx = await store.buildContext();
    assert.equal(ctx[1].role, 'system', '书籍上下文紧跟主 system');
    assert.ok(`${ctx[1].content}`.includes('《三体》（刘慈欣），当前读到：第 10 章'), ctx[1].content);
    assert.ok(`${ctx[1].content}`.includes('不要生拉硬扯'), '缺引导约束');
    store.setBookContext('活着', '', '');
    ctx = await store.buildContext();
    const note2 = `${(await notes())[0].content}`;
    assert.ok(note2.includes('《活着》') && !note2.includes('当前读到') && !note2.includes('（'), note2);
    store.setBookContext('', 'x', 'y');
    assert.equal((await notes()).length, 0, '空书名=清除');
    store.setBookContext('三体', '', '');
    store.clearBookContext();
    assert.equal((await notes()).length, 0, 'clear 后不注入');
  });

  test('讨论本书：路由带参进页即注入横幅，X 清除；无参进入不残留', () => {
    state.routerParams = { bookTitle: '宇宙视界', chapter: '第三章' };
    const page = chat();
    assert.equal(page.bookTag, '讨论《宇宙视界》');
    page.leaveBookContext();
    assert.equal(page.bookTag, '');
    state.routerParams = {};
    const page2 = chat();
    assert.equal(page2.bookTag, '', '普通进入静默跳过');
    state.routerParams = { bookTitle: '三体' };
    const page3 = chat();
    assert.equal(page3.bookTag, '讨论《三体》', '无章节也可注入');
    delete state.routerParams;
  });

  test('时间分隔条：阈值/首条/旧数据 + ts 落盘往返 + 页面判定', async () => {
    const model = await load('AiChatModel');
    const MIN = 60000;
    assert.equal(model.shouldShowTimeDivider(0, 1000), true, '首条/上条无时间显示');
    assert.equal(model.shouldShowTimeDivider(1000, 0), false, '旧数据无 ts 不显示');
    assert.equal(model.shouldShowTimeDivider(1000, 1000 + 4 * MIN), false, '4 分钟不插条');
    assert.equal(model.shouldShowTimeDivider(1000, 1000 + 5 * MIN), true, '5 分钟插条');
    const today = new Date();
    today.setHours(9, 5, 0, 0);
    assert.equal(model.formatDividerTime(today.getTime()), '09:05', '当天只显示时分');
    const lastYear = new Date();
    lastYear.setFullYear(lastYear.getFullYear() - 1);
    assert.match(model.formatDividerTime(lastYear.getTime()), /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/, '跨年显示全日期');
    const parsed = model.parseBubbles([{ role: 'user', content: 'x', activities: [], ts: 123 }]);
    assert.equal(parsed[0].ts, 123, 'ts 进白名单');
    assert.equal(model.parseBubbles([{ role: 'user', content: 'x', activities: [] }])[0].ts, 0, '缺 ts 视为 0');
    // 落盘：同轮 user/assistant 同戳
    const page = chat();
    await page.send('q');
    state.handlers.onDone('a');
    const saved = JSON.parse(state.prefs.get('ai_chat_history'));
    assert.ok(saved[0].ts > 0 && saved[1].ts === saved[0].ts, '轮次时间戳随历史持久化');
    // 页面判定：间隔与删除场景
    page.messages = [
      { role: 'user', content: 'a', streaming: false, error: false, activities: [], ts: 1000 },
      { role: 'assistant', content: 'b', streaming: false, error: false, activities: [], ts: 1000 },
    ];
    assert.equal(page.showsTimeDivider(0), true);
    assert.equal(page.showsTimeDivider(1), false);
    // key 覆盖分隔态：同内容下 prev 无 ts vs 有 ts，key 必须不同（复用项才会重算）
    const kWith = page.bubbleKey(page.messages[1], 1);
    page.messages[0].ts = 0;
    assert.notEqual(page.bubbleKey(page.messages[1], 1), kWith, '分隔态变化必须换 key');
  });

  test('错误气泡重试：截掉错误条与其问题原样重发；regenerate 委托等价', async () => {
    const page = chat();
    const store = AiChatStore.instance();
    await page.send('问题一');
    state.handlers.onDone('答案一');
    await page.send('问题二');
    assert.equal(store.retryFrom(1), false, 'thinking 期拒绝重试');
    state.handlers.onError('网络错误');
    assert.equal(store.messages.length, 4);
    assert.equal(store.messages[3].error, true, '失败轮固化为错误气泡');
    // 从错误条位置重试：截掉 [问题二+错误条]，原样重发
    assert.equal(store.retryFrom(3), true);
    assert.equal(store.messages.length, 4, '错误条与问题截掉后，问题原样重新入列');
    assert.equal(store.messages[2].role, 'user');
    assert.equal(store.messages[2].content, '问题二', '重发的是原问题');
    assert.equal(store.messages[3].role, 'assistant');
    assert.equal(store.messages[3].streaming, true, '新一轮流式气泡就位');
    // retryFrom 内 void send()：chatStream 在 await buildContext 之后才捕获 handlers，让出一拍
    await new Promise((r) => setTimeout(r, 10));
    state.handlers.onDone('答案二·重试');
    assert.equal(store.messages.length, 4);
    assert.equal(store.messages[3].content, '答案二·重试');
    assert.equal(store.messages[3].error, false);
    // 前方无用户问题时静默拒绝；regenerate=末尾锚点委托
    assert.equal(store.retryFrom(0), false, '无问题可重发');
    assert.equal(store.regenerate(), true, 'regenerate 走同一 retryFrom');
    state.handlers.onDone('答案三');
    assert.ok(JSON.parse(state.prefs.get('ai_chat_history')).length > 0, '重试轮落盘');
  });

  test('会话改名/搜索/导出（#1513）：named 跨归档持久；搜索含正文；导出稿跳过错误/流式', async () => {
    const model = await load('AiChatModel');
    const bs = [
      { role: 'user', content: '推荐科幻', streaming: false, error: false, activities: [] },
      { role: 'assistant', content: '《三体》', streaming: false, error: false, activities: [] },
      { role: 'assistant', content: '网络错误', streaming: false, error: true, activities: [] },
      { role: 'assistant', content: '半成品', streaming: true, error: false, activities: [] },
      { role: 'assistant', content: '   ', streaming: false, error: false, activities: [] },
    ];
    const md = model.buildSessionMd('科幻推荐', bs, new Date(2026, 10, 21, 9, 5).getTime());
    assert.ok(md.startsWith('# 科幻推荐'), '标题行');
    assert.ok(md.includes('2026-11-21 09:05'), '导出时间戳');
    assert.ok(md.includes('## 用户\n\n推荐科幻') && md.includes('## 助手\n\n《三体》'), '角色分节');
    assert.ok(!md.includes('网络错误') && !md.includes('半成品'), '错误/流式/空气泡不入稿');
    assert.equal(model.sessionMatches('abc', bs, ''), true, '空词恒匹配');
    assert.equal(model.sessionMatches('abc', bs, '三体'), true, '正文命中');
    assert.equal(model.sessionMatches('ABC def', bs, 'aBC'), true, '标题忽略大小写');
    assert.equal(model.sessionMatches('abc', bs, 'zzz'), false, '无命中排除');
    // store：当前会话改名→归档名随带；存档会话改名直接落盘
    const page = chat();
    const store = AiChatStore.instance();
    await page.send('第一个问题');
    state.handlers.onDone('答一');
    assert.equal(store.renameSession(store.currentId, '  '), false, '空名拒绝');
    assert.equal(store.renameSession(store.currentId, '我的科幻话题'), true);
    assert.equal(store.currentTitle(), '我的科幻话题', '当前会话改名即生效');
    assert.equal(store.newSession(), true);
    await page.send('三体里的主线矛盾');
    state.handlers.onDone('答二');
    const s1 = store.sessions[0];
    assert.equal(s1.title, '我的科幻话题', '归档带改名标题');
    assert.equal(s1.named, '我的科幻话题', 'named 槽持久化');
    assert.equal(store.renameSession(s1.id, '归档话题名'), true, '存档会话改名');
    assert.equal(store.sessions[0].title, '归档话题名');
    const raw = JSON.parse(state.prefs.get('ai_chat_sessions'));
    assert.equal(raw.find((r) => r.id === s1.id).named, '归档话题名', '存档改名落盘');
    // 搜索过滤（只过滤存档列表，当前会话恒置顶）
    assert.equal(store.searchSessions('归档').length, 1, '标题命中');
    assert.equal(store.searchSessions('答一').length, 1, '正文命中');
    assert.equal(store.searchSessions('zzz').length, 0, '无命中为空');
    assert.equal(store.searchSessions('  ').length, 1, '空词原样返回');
    // 导出
    assert.ok(store.exportSessionMd(s1.id).includes('答一'), '导出存档会话');
    assert.ok(store.exportSessionMd('').includes('三体里的主线矛盾'), '空 id=当前会话');
    assert.equal(store.exportSessionMd('no-such-id'), '', '目标不存在导出空');
    // 切回：named 随带；超长截断
    assert.equal(store.switchSession(s1.id), true);
    assert.equal(store.currentTitle(), '归档话题名', '切回后改名不丢');
    assert.equal(store.renameSession(s1.id, 'x'.repeat(50)), true);
    assert.equal(store.currentTitle().length, 31, '超长截 30+省略号');
  });

}
