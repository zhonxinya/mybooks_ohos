// 用例组 8：MCP 客户端/执行/集成 + 灵魂管理页（拆分自 check_ai_assistant.mjs，用例体原样）
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { test, state, settingsDefaults, enc, rtB64, deferred, tick, flush } from './base.mjs';
import { dir, read, ETS, ROOT } from './paths.mjs';

export function register(ctx) {
  const { load, deps, RealAiService, RealAiTools, parseToolBookLines, toolsState, mdParseBlocks, mdParseInline, AI_SKILLS, AiAssistantPage, AiBookPanelPage, AiRecommendPage, AiSettingsPage, AiPersonaPage, AiPersona, DEFAULT_SOUL, AiChatStore, personaState, MetaSearchService, NovelMetaService, resetSettings, settingsPage, chat, reappear } = ctx;
  test('MCP 客户端：四家握手合并、SSE 解析、单家降级与会话缓存', async () => {
    const { McpService } = await load('RealMcp');
    McpService.reset();
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    const ok = (sid) => ({ statusCode: 200, headers: { 'mcp-session-id': sid },
      body: enc(JSON.stringify({ jsonrpc: '2.0', id: 1, result: { protocolVersion: '2025-03-26' } })) });
    const notify = { statusCode: 202, headers: {}, body: enc('') };
    const esList = { statusCode: 200, headers: {}, body: enc(
      'event: message\ndata: ' + JSON.stringify({ jsonrpc: '2.0', id: 2, result: { tools: [
        { name: 'bailian_web_search', description: '联网搜索', inputSchema: { properties: { query: { type: 'string' } }, required: ['query'] } },
      ] } }) + '\n\n') };
    const wsList = { statusCode: 200, headers: {}, body: enc(JSON.stringify({ jsonrpc: '2.0', id: 2, result: { tools: [
      { name: 'web_search', description: '网页搜索', inputSchema: { type: 'object', properties: { query: { type: 'string' } } } },
    ] } })) };
    const wfList = { statusCode: 200, headers: {}, body: enc(JSON.stringify({ jsonrpc: '2.0', id: 2, result: { tools: [
      { name: 'web_extractor', description: '网页抽取', inputSchema: { type: 'object', properties: { url: { type: 'string' } } } },
    ] } })) };
    const badKey = { statusCode: 401, headers: {}, body: enc('{"code":"InvalidApiKey","message":"Invalid API-key provided."}') };
    // 并行发起顺序=登记序（es,ws,wf,sg）：init×4 → notify×3（sg 已死）→ list×3；sg 401 降级
    deps.state.rcpResponses.push(ok('sid-es'), ok('sid-ws'), ok('sid-wf'), badKey,
      notify, notify, notify, esList, wsList, wfList);
    const tools = await McpService.ensureToolset('sk-sp-test');
    assert.equal(tools.length, 3, '单家失败静默跳过，其余保留');
    assert.equal(tools[0].function.name, 'mcp_es_bailian_web_search');
    assert.equal(tools[1].function.name, 'mcp_ws_web_search');
    assert.equal(tools[2].function.name, 'mcp_wf_web_extractor');
    assert.equal(tools[0].function.parameters.type, 'object', 'inputSchema 缺 type 时强制补齐');
    const req0 = deps.state.requests[0];
    assert.ok(req0.url.includes('/mcps/EnhancedSearch/mcp'));
    assert.equal(req0.headers['Authorization'], 'Bearer sk-sp-test');
    assert.ok(req0.headers['Accept'].includes('text/event-stream'));
    // list 请求带 initialize 响应的会话头
    const listEs = deps.state.requests.find((r) => r.content.includes('tools/list') && r.url.includes('EnhancedSearch'));
    assert.equal(listEs.headers['mcp-session-id'], 'sid-es');
    const before = deps.state.requests.length;
    const again = await McpService.ensureToolset('sk-sp-test');
    assert.equal(again.length, 3);
    assert.equal(deps.state.requests.length, before, '缓存命中零请求');
    // Key 变化 + reset 都要重新握手
    deps.state.rcpResponses.push(ok('a'), ok('b'), ok('c'), badKey,
      notify, notify, notify, esList, wsList, wfList);
    await McpService.ensureToolset('sk-sp-other');
    assert.ok(deps.state.requests.length > before, '换 Key 强制重握手');
    McpService.reset();
    assert.equal(McpService.enabledFor('deepseek', 'sk-d'), false, '非 Token Plan 不启用');
    assert.equal(McpService.enabledFor('qwen-tokenplan', ''), false, '无 Key 不启用');
    assert.equal(McpService.enabledFor('qwen-tokenplan', 'sk-sp-x'), true);
    assert.equal(McpService.isMcpTool('mcp_es_x'), true);
    assert.equal(McpService.isMcpTool('mcp_ws_x'), true, '第四家前缀同样路由');
    assert.equal(McpService.isMcpTool('search_books'), false);
    assert.equal(McpService.labelOf('mcp_wf_x'), '百炼网页解析');
    assert.equal(McpService.labelOf('mcp_ws_x'), '百炼联网搜索');
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
  });

  test('MCP 执行：tools/call 内容拼接、isError、非法参数与坏会话重试', async () => {
    const { McpService } = await load('RealMcp');
    McpService.reset();
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    const init = { statusCode: 200, headers: { 'mcp-session-id': 'sid1' },
      body: enc('{"jsonrpc":"2.0","id":1,"result":{}}') };
    const notify = { statusCode: 202, headers: {}, body: enc('') };
    const list = { statusCode: 200, headers: {}, body: enc(JSON.stringify({ jsonrpc: '2.0', id: 2, result: { tools: [
      { name: 'search', description: 's', inputSchema: { type: 'object', properties: {} } },
    ] } })) };
    const bad = { statusCode: 401, headers: {}, body: enc('{"code":"InvalidApiKey","message":"nope"}') };
    // 四家并行：init-es, init-ws, init-wf, init-sg, notify-es, list-es（ws/wf/sg 在 init 即败）
    deps.state.rcpResponses.push(init, bad, bad, bad, notify, list);
    await McpService.ensureToolset('k');
    assert.equal(deps.state.requests.length, 6, 'es 全握手、ws/wf/sg init 即败');
    // 正常调用：多段 text 拼接
    deps.state.rcpResponses.push({ statusCode: 200, headers: {}, body: enc(JSON.stringify({
      jsonrpc: '2.0', id: 3, result: { content: [{ type: 'text', text: '第一段' }, { type: 'image' }, { type: 'text', text: '第二段' }] } })) });
    const text = await McpService.callTool('mcp_es_search', '{"q":"三体"}', 'k');
    assert.equal(text, '第一段\n第二段');
    const call = deps.state.requests[deps.state.requests.length - 1];
    assert.ok(call.content.includes('"name":"search"'), '剥前缀还原服务端原名');
    assert.ok(call.content.includes('{"q":"三体"}'), 'arguments JSON 原样透传');
    assert.equal(call.headers['mcp-session-id'], 'sid1', '会话头续用');
    // isError 前缀
    deps.state.rcpResponses.push({ statusCode: 200, headers: {}, body: enc(JSON.stringify({
      jsonrpc: '2.0', id: 3, result: { isError: true, content: [{ type: 'text', text: '配额用尽' }] } })) });
    assert.ok((await McpService.callTool('mcp_es_search', '{}', 'k')).startsWith('MCP 工具返回错误：'));
    // 非法参数 JSON：不发请求
    assert.ok((await McpService.callTool('mcp_es_search', '{bad', 'k')).includes('合法 JSON'));
    // 未知工具/空 Key 容错
    assert.ok((await McpService.callTool('mcp_zz_x', '{}', 'k')).includes('未知'));
    assert.ok((await McpService.callTool('mcp_es_search', '{}', '')).includes('未配置'));
    // 会话失效：error → 重新握手 → 重试成功（es 无 sg：init/notify/list + call）
    deps.state.rcpResponses.push(
      { statusCode: 200, headers: {}, body: enc('{"jsonrpc":"2.0","id":3,"error":{"code":-32001,"message":"session expired"}}') },
      { statusCode: 200, headers: { 'mcp-session-id': 'sid2' }, body: enc('{"jsonrpc":"2.0","id":1,"result":{}}') },
      notify, list,
      { statusCode: 200, headers: {}, body: enc(JSON.stringify({ jsonrpc: '2.0', id: 3, result: { content: [{ type: 'text', text: '重试成功' }] } })) });
    assert.equal(await McpService.callTool('mcp_es_search', '{}', 'k'), '重试成功');
    const retry = deps.state.requests[deps.state.requests.length - 1];
    assert.equal(retry.headers['mcp-session-id'], 'sid2', '重握手后用新会话');
    McpService.reset();
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
  });

  test('MCP 集成：chatStream 第四参并入 tools，回路 mcp_ 路由执行并回填', async () => {
    const RealAiService = (await load('RealAiService')).AiService;
    deps.state.store.clear();
    deps.state.chatCalls.length = 0;
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    deps.state.chatStreamRounds = null;
    RealAiService.saveConfig('deepseek', 'https://api.deepseek.com/v1', 'deepseek-chat', 'sk-d', 0.5);
    const fake = { type: 'function', function: { name: 'mcp_es_probe', description: 'd',
      parameters: { type: 'object', properties: {} } } };
    const handlers = { onDelta: () => {}, onDone: () => {}, onError: () => {},
      onTool: () => {}, onToolResult: () => {} };
    // 1) 不传 mcp：只挂内置工具（计数取实际值做基线，工具增删不破坏本用例）
    RealAiService.chatStream([{ role: 'user', content: 'x' }], handlers, 2048);
    const baseN = deps.state.chatCalls[0].body.tools.length;
    assert.ok(baseN >= 27, '内置工具集基线');
    // 2) 传 mcp：基线+1 且末位为 mcp 工具
    deps.state.chatCalls.length = 0;
    RealAiService.chatStream([{ role: 'user', content: 'x' }], handlers, 2048, [fake]);
    const tools2 = deps.state.chatCalls[0].body.tools;
    assert.equal(tools2.length, baseN + 1);
    assert.equal(tools2[baseN].function.name, 'mcp_es_probe');
    // 3) 回路路由：模型调 mcp_es_probe → 走 McpService（rcp mock 握手+执行），结果回填 tool 消息
    deps.state.chatCalls.length = 0;
    deps.state.chatStreamRounds = [
      [{ choices: [{ delta: { tool_calls: [{ index: 0, id: 'c9',
        function: { name: 'mcp_es_probe', arguments: '{"q":"x"}' } }] } }] }],
      [{ choices: [{ delta: { content: '整合完毕' } }] }],
    ];
    const init = { statusCode: 200, headers: { 'mcp-session-id': 'sidm' }, body: enc('{"jsonrpc":"2.0","id":1,"result":{}}') };
    const notify = { statusCode: 202, headers: {}, body: enc('') };
    const list = { statusCode: 200, headers: {}, body: enc(JSON.stringify({ jsonrpc: '2.0', id: 2, result: { tools: [
      { name: 'probe', description: 'd', inputSchema: { type: 'object', properties: {} } },
    ] } })) };
    // callTool 单家串行：init→notify→list→tools/call
    deps.state.rcpResponses.push(init, notify, list,
      { statusCode: 200, headers: {}, body: enc(JSON.stringify({ jsonrpc: '2.0', id: 3,
        result: { content: [{ type: 'text', text: 'MCP 返回内容' }] } })) });
    const done = [];
    RealAiService.chatStream([{ role: 'user', content: '查一下' }],
      { onDelta: () => {}, onDone: (t) => done.push(t), onError: (e) => done.push('ERR ' + e),
        onTool: () => {}, onToolResult: () => {} }, 2048, [fake]);
    await flush();
    assert.deepEqual(done, ['整合完毕']);
    const msgs = deps.state.chatCalls[1].body.messages;
    const toolMsg = msgs.find((m) => m.role === 'tool');
    assert.ok(toolMsg !== undefined, '须回填 tool 结果消息');
    assert.equal(toolMsg.content, 'MCP 返回内容');
    assert.equal(toolMsg.tool_call_id, 'c9');
    const called = deps.state.requests.filter((r) => r.content && r.content.includes('tools/call'));
    assert.equal(called.length, 1, '恰发一次 tools/call');
    deps.state.chatStreamRounds = null;
    deps.state.chatCalls.length = 0;
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
  });

  test('灵魂管理页：灵魂保存/恢复默认，手动补记与删除记忆', () => {
    personaState.files.clear();
    const page = new AiPersonaPage();
    page.aboutToAppear();
    assert.equal(page.soul, DEFAULT_SOUL);
    page.soul = '自定义人格';
    page.onSaveSoul();
    assert.equal(personaState.files.get('/stub-files/ai_soul/SOUL.md'), '自定义人格');
    assert.equal(state.lastToast, '灵魂已保存，下次对话生效');
    page.newMemory = '喜欢科幻';
    page.onAddMemory();
    assert.deepEqual(page.memories, ['喜欢科幻']);
    page.onRemoveMemory(0);
    assert.deepEqual(page.memories, []);
    page.onResetSoul();
    assert.equal(page.soul, DEFAULT_SOUL);
  });

  test('MCP 每家开关：默认开、禁用家不握手与调用防御、切换即时失效缓存', async () => {
    const { McpService } = await load('RealMcp');
    McpService.reset();
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    assert.equal(McpService.isServerEnabled('es'), true, '未设置=启用（默认行为不变）');
    assert.equal(McpService.serverList().length, 4, '四家登记');
    const ok = (sid) => ({ statusCode: 200, headers: { 'mcp-session-id': sid },
      body: enc(JSON.stringify({ jsonrpc: '2.0', id: 1, result: { protocolVersion: '2025-03-26' } })) });
    const notify = { statusCode: 202, headers: {}, body: enc('') };
    const list = (name) => ({ statusCode: 200, headers: {}, body: enc(JSON.stringify(
      { jsonrpc: '2.0', id: 2, result: { tools: [{ name, description: 'd',
        inputSchema: { type: 'object', properties: {} } }] } })) });
    // 关 es：工具集不含、握手零请求（并行队列序=登记序跳过 es：ws,wf,sg）
    McpService.setServerEnabled('es', false);
    deps.state.rcpResponses.push(ok('w'), ok('f'), ok('g'), notify, notify, notify,
      list('web_search'), list('web_extractor'), list('speech_generate_text'));
    const tools = await McpService.ensureToolset('sk-sp-x');
    assert.equal(tools.length, 3);
    assert.ok(!tools.some((t) => t.function.name.startsWith('mcp_es_')), '禁用家不挂载');
    assert.equal(deps.state.requests.filter((r) => r.url.includes('EnhancedSearch')).length, 0,
      '禁用家零请求');
    // 模型幻觉调用禁用家：文案拒绝，不发请求
    const before = deps.state.requests.length;
    const denied = await McpService.callTool('mcp_es_bailian_web_search', '{"query":"x"}', 'sk-sp-x');
    assert.ok(denied.includes('禁用'), denied);
    assert.equal(deps.state.requests.length, before, '禁用家调用不触网');
    // 重新启用：setServerEnabled 已 reset 缓存，本轮握手含 es
    McpService.setServerEnabled('es', true);
    deps.state.rcpResponses.push(ok('e'), ok('w2'), ok('f2'), ok('g2'),
      notify, notify, notify, notify,
      list('bailian_web_search'), list('web_search'), list('web_extractor'), list('speech_generate_text'));
    const back = await McpService.ensureToolset('sk-sp-x');
    assert.equal(back.length, 4);
    assert.equal(back[0].function.name, 'mcp_es_bailian_web_search');
    // 摘要文案：禁用家标「已禁用」
    McpService.setServerEnabled('sg', false);
    assert.ok(McpService.summaryBrief().includes('百炼语音转写：已禁用'));
    McpService.setServerEnabled('sg', true);
    McpService.reset();
    deps.state.store.clear();
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
  });

}
