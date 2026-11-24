// 用例组 3：工具回路并行/权限模式/技能/结构化列表（拆分自 check_ai_assistant.mjs，用例体原样）
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { test, state, settingsDefaults, enc, rtB64, deferred, tick, flush } from './base.mjs';
import { dir, read, ETS, ROOT } from './paths.mjs';

export function register(ctx) {
  const { load, deps, RealAiService, RealAiTools, parseToolBookLines, toolsState, mdParseBlocks, mdParseInline, AI_SKILLS, AiAssistantPage, AiBookPanelPage, AiRecommendPage, AiSettingsPage, AiPersonaPage, AiPersona, DEFAULT_SOUL, AiChatStore, personaState, MetaSearchService, NovelMetaService, resetSettings, settingsPage, chat, reappear } = ctx;
  test('工具回路并行：同轮全只读并发执行（先齐 T 后齐 R），tool 消息保序、卡片按 callId 配对', async () => {
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'deepseek-v4.1-flash', 'sk-oc', 0.5);
    toolsState.search = async (q) => [{ id: q.length, title: q, authors: [`${q}作者`] }];
    const events = [];
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '', tool_calls: [
        { id: 'c1', type: 'function', function: { name: 'search_books', arguments: '{"query":"三体"}' } },
        { id: 'c2', type: 'function', function: { name: 'search_books', arguments: '{"query":"球状闪电"}' } },
        { id: 'c3', type: 'function', function: { name: 'search_books', arguments: '{"query":"乡村教师"}' } },
      ] } }] })) },
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '三本都在。' } }] })) },
    ];
    let full = '';
    let error = '';
    RealAiService.chatStream([{ role: 'user', content: '三本都查一下' }], {
      onDelta: (t) => { full += t; }, onDone: () => {}, onError: (m) => { error = m; },
      onTool: (l, name) => { events.push('T'); },
      onToolResult: (name, l, text, cid) => { events.push('R' + cid); },
    }, 256);
    await flush();
    assert.equal(error, '');
    // 并行分支特征：三个 onTool 先行（活动区同时亮三条 doing），结果按原序回填
    assert.deepEqual(events, ['T', 'T', 'T', 'Rc1', 'Rc2', 'Rc3']);
    const b2 = JSON.parse(deps.state.requests[1].content);
    const toolMsgs = b2.messages.filter((m) => m.role === 'tool');
    assert.deepEqual(toolMsgs.map((m) => m.tool_call_id), ['c1', 'c2', 'c3']);
    assert.ok(toolMsgs[0].content.includes('《三体》') && !toolMsgs[0].content.includes('球状闪电'),
      '第一条 tool 结果不得混入后完成的查询');
    assert.ok(full.includes('三本都在。'));
    // AiTools 层配对契约：并行 execute 两笔，takeLastBooksFor 各归各（静态槽会被后完成者覆盖）
    const p1 = RealAiTools.execute('search_books', '{"query":"甲书"}', 'k1');
    const p2 = RealAiTools.execute('search_books', '{"query":"乙书"}', 'k2');
    await Promise.all([p1, p2]);
    assert.equal(RealAiTools.takeLastBooksFor('k1')[0].title, '《甲书》');
    assert.equal(RealAiTools.takeLastBooksFor('k2')[0].title, '《乙书》');
  });

  test('工具回路并行边界：含写工具轮保持串行（T/R 交替），闸门语义不变', async () => {
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'deepseek-v4.1-flash', 'sk-oc', 0.5);
    RealAiService.savePermission('auto');
    toolsState.search = async (q) => [{ id: 12, title: q, authors: ['刘慈欣'] }];
    const events = [];
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '', tool_calls: [
        { id: 'm1', type: 'function', function: { name: 'search_books', arguments: '{"query":"三体"}' } },
        { id: 'm2', type: 'function', function: { name: 'create_booklist', arguments: '{"name":"混轮"}' } },
      ] } }] })) },
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: ' done' } }] })) },
    ];
    RealAiService.chatStream([{ role: 'user', content: '查完顺手建书单' }], {
      onDelta: () => {}, onDone: () => {}, onError: () => {},
      onTool: (l, name) => { events.push('T' + name); },
      onToolResult: (name, l, text, cid) => { events.push('R' + cid); },
    }, 256);
    await flush();
    assert.deepEqual(events, ['Tsearch_books', 'Rm1', 'Tcreate_booklist', 'Rm2'],
      '写工具不得与只读并发跑（顺序与确认语义依赖串行）');
    assert.equal(toolsState.booklistCreateCalls.length, 1);
    toolsState.booklistCreateCalls.length = 0;
    RealAiService.savePermission('confirm');
  });

  test('工具回路收尾：剩 3 轮注入收敛提示；上限轮有正文软着陆、无正文才报错', async () => {
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'deepseek-v4.1-flash', 'sk-oc', 0.5);
    toolsState.search = async (q) => [{ id: 1, title: q, authors: [] }];
    const mk = () => ({ statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '',
      tool_calls: [{ id: 'x', type: 'function', function: { name: 'search_books', arguments: '{"query":"q"}' } }] } }] })) });
    const final = (t) => ({ statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: t } }] })) });
    // ① 第 9 轮请求带内部提示、第 8 轮不带，模型随即收尾 → 提示只注入一次
    deps.state.rcpResponses = [...Array(9).fill(0).map(mk), final('查完了。')];
    let error = '';
    let full = '';
    RealAiService.chatStream([{ role: 'user', content: '慢慢查' }], {
      onDelta: (t) => { full += t; }, onDone: () => {}, onError: (m) => { error = m; },
    }, 256);
    await flush();
    assert.equal(error, '');
    const b9 = JSON.parse(deps.state.requests[9].content);
    const b8 = JSON.parse(deps.state.requests[8].content);
    const hinted = (msgs) => msgs.filter((m) => m.role === 'user' && `${m.content}`.includes('仅剩 3 轮')).length;
    assert.equal(hinted(b8.messages), 0, '前 9 轮不得注入');
    assert.equal(hinted(b9.messages), 1, 'round==MAX-3 注入一次收敛提示');
    // ② 上限轮模型仍调工具 → 自动续段：预算重开、tools 重新挂上、任务延续，
    //    不再把半截结果甩回用户（旧「12 轮上限」截断已废除）
    deps.state.requests.length = 0;
    deps.state.rcpResponses = [...Array(12).fill(0).map(mk),
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '已查到部分内容。',
        tool_calls: [{ id: 'y', type: 'function', function: { name: 'search_books', arguments: '{"query":"q"}' } }] } }] })) },
      final('续段后查完了。')];
    error = '';
    full = '';
    RealAiService.chatStream([{ role: 'user', content: '无限查' }], {
      onDelta: (t) => { full += t; }, onDone: () => {}, onError: (m) => { error = m; },
    }, 256);
    await flush();
    assert.equal(error, '', '触顶自动续段不得报错');
    assert.ok(full.includes('续段后查完了。') && !full.includes('轮上限'), full);
    const b12 = JSON.parse(deps.state.requests[12].content);
    const b13 = JSON.parse(deps.state.requests[13].content);
    assert.equal(b12.tools === undefined, true, '段一上限轮不带 tools（逼收尾）');
    assert.ok(b13.tools !== undefined && b13.tools.length > 0, '续段首轮回带 tools');
    const continued = (msgs) => msgs.filter((m) => m.role === 'user' && `${m.content}`.includes('已自动续期')).length;
    assert.equal(continued(b13.messages), 1, '续段注入内部提示一次');
    // ③ 连续 5 段（12×5 轮）全调工具 → 硬上限报错（防死循环烧 token）
    deps.state.requests.length = 0;
    deps.state.rcpResponses = [...Array(65).fill(0).map(mk)];
    error = '';
    RealAiService.chatStream([{ role: 'user', content: '光查不说' }], {
      onDelta: () => {}, onDone: () => {}, onError: (m) => { error = m; },
    }, 256);
    await flush();
    assert.match(error, /硬上限/, '超 4 次自动续段后按硬上限报错');
  });

  test('上下文折叠单元：最近 4 条 tool 消息保全文，更早截到头部+可重查提示；幂等；数组不动', async () => {
    const { AiServiceGateway } = await load('RealAiServiceGateway');
    const long = 'x'.repeat(400);
    const msgs = [
      { role: 'user', content: 'q' },
      { role: 'tool', content: long, tool_call_id: 't1' },
      { role: 'tool', content: 'short', tool_call_id: 't2' },
      { role: 'tool', content: long, tool_call_id: 't3' },
      { role: 'tool', content: long, tool_call_id: 't4' },
      { role: 'tool', content: long, tool_call_id: 't5' },
      { role: 'tool', content: [{ type: 'text', text: '多模态' }], tool_call_id: 't6' },
    ];
    AiServiceGateway.foldStaleToolResults(msgs);
    // 保留窗=最后 4 条 tool（t6/t5/t4/t3）；t1 折叠；t2 短于头部长度跳过
    assert.ok(msgs[1].content.startsWith('xxx') && msgs[1].content.includes('…（已折叠 240 字符'),
      `t1 应截到 160 字符+提示：${msgs[1].content.slice(150, 200)}`);
    assert.equal(msgs[2].content, 'short', '短条目不动');
    assert.equal(msgs[3].content, long, 't3 在保留窗内须全文');
    assert.ok(Array.isArray(msgs[6].content), '多模态数组 content 不动');
    const snapshot = msgs[1].content;
    AiServiceGateway.foldStaleToolResults(msgs);
    assert.equal(msgs[1].content, snapshot, '幂等：已折叠条目不得二次截短');
  });

  test('上下文折叠链路：6 轮长结果任务后续请求折叠最早结果、最近 4 条全文', async () => {
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'deepseek-v4.1-flash', 'sk-oc', 0.5);
    const longTitle = '测试'.repeat(60);
    toolsState.search = async () => [
      { id: 1, title: longTitle, authors: ['甲'] },
      { id: 2, title: longTitle + '贰', authors: ['乙'] },
      { id: 3, title: longTitle + '叁', authors: ['丙'] },
    ];
    const mkFold = () => ({ statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '',
      tool_calls: [{ id: 'f', type: 'function', function: { name: 'search_books', arguments: '{"query":"f"}' } }] } }] })) });
    const fin = (t) => ({ statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: t } }] })) });
    deps.state.rcpResponses = [...Array(6).fill(0).map(mkFold), fin('查完了。')];
    let error = '';
    RealAiService.chatStream([{ role: 'user', content: '逐本查' }], {
      onDelta: () => {}, onDone: () => {}, onError: (m) => { error = m; },
    }, 256);
    await flush();
    assert.equal(error, '');
    const b = JSON.parse(deps.state.requests[6].content);
    const toolMsgs = b.messages.filter((m) => m.role === 'tool');
    assert.equal(toolMsgs.length, 6);
    assert.ok(`${toolMsgs[0].content}`.includes('…（已折叠') && `${toolMsgs[1].content}`.includes('…（已折叠'),
      '最早两条应被折叠');
    for (let i = 2; i < 6; i++) {
      assert.ok(!`${toolMsgs[i].content}`.includes('已折叠'), '最近 4 条保持全文');
    }
    toolsState.search = async () => [];
  });

  test('写工具确认闸门：拒绝/无确认方不执行，批准才执行', async () => {
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'deepseek-v4.1-flash', 'sk-oc', 0.5);
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '',
        tool_calls: [{ id: 'w1', type: 'function',
          function: { name: 'create_booklist', arguments: '{"name":"科幻入门"}' } }] } }] })) },
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '',
        tool_calls: [{ id: 'w2', type: 'function',
          function: { name: 'add_sonovel_task', arguments: '{}' } }] } }] })) },
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '好' } }] })) },
    ];
    const asked = [];
    const confirm = (label, args) => {
      asked.push([label, args]);
      return Promise.resolve(label === '创建书单'); // 第一笔允许、第二笔拒绝
    };
    RealAiService.chatStream([{ role: 'user', content: '建个书单' }], {
      onDelta: () => {}, onDone: () => {}, onError: () => {}, onConfirm: confirm,
    }, 128);
    await flush();
    assert.deepEqual(asked, [['创建书单', '{"name":"科幻入门"}'], ['添加 so-novel 下载任务', '{}']]);
    // 第一笔被批准 → 真实执行：桩记下参数并返回新书单 id
    const b2 = JSON.parse(deps.state.requests[1].content);
    assert.match(b2.messages.find((m) => m.role === 'tool').content, /已创建书单「科幻入门」（id=77）/);
    assert.deepEqual(toolsState.booklistCreateCalls,
      [{ name: '科幻入门', description: '', color: '#1890ff', isPublic: true }]);
    toolsState.booklistCreateCalls.length = 0;
    // 第二笔被拒绝 → 不执行，直接回填拒绝文案（历史里有两条 tool 消息，看末条）
    const b3 = JSON.parse(deps.state.requests[2].content);
    const toolMsgs = b3.messages.filter((m) => m.role === 'tool');
    assert.equal(toolMsgs.length, 2);
    assert.equal(toolMsgs[1].content, '用户拒绝了该操作');
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '',
        tool_calls: [{ id: 'w3', type: 'function',
          function: { name: 'create_booklist', arguments: '{}' } }] } }] })) },
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '算了' } }] })) },
    ];
    RealAiService.chatStream([{ role: 'user', content: '建个书单' }], {
      onDelta: () => {}, onDone: () => {}, onError: () => {},
    }, 128);
    await flush();
    const bNoAsk = JSON.parse(deps.state.requests[1].content);
    assert.equal(bNoAsk.messages.find((m) => m.role === 'tool').content, '用户拒绝了该操作');
  });

  test('权限模式：definitions(mode) 三档过滤——readonly 去写工具，其余全量', () => {
    const WRITE = ['create_booklist', 'add_books_to_booklist', 'update_booklist', 'delete_booklist',
      'remove_book_from_booklist', 'add_sonovel_task', 'add_to_shelf', 'push_to_device',
      'update_book_meta', 'set_cover', 'forget_memory'];
    assert.equal(RealAiTools.definitions().length, 35);
    assert.equal(RealAiTools.definitions('confirm').length, 35);
    assert.equal(RealAiTools.definitions('auto').length, 35);
    const ro = RealAiTools.definitions('readonly');
    assert.equal(ro.length, 22);
    assert.ok(ro.some((d) => d.function.name === 'list_categories'), 'list_categories 是只读工具须保留');
    for (const name of WRITE) {
      assert.ok(!ro.some((d) => d.function.name === name), `readonly 泄漏写工具 ${name}`);
    }
    assert.ok(ro.some((d) => d.function.name === 'search_books'), 'readonly 应保留读工具');
    assert.ok(RealAiTools.definitions('readonly') !== RealAiTools.definitions('confirm'),
      'readonly 不得返回 TOOL_DEFS 本体（防调用方原地污染）');
  });

  test('权限模式：只读——请求体不带写工具，幻觉写调用被回路挡下且不弹确认', async () => {
    deps.state.store.set('p:ai_permission_mode', 'readonly');
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'deepseek-v4.1-flash', 'sk-oc', 0.5);
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '',
        tool_calls: [{ id: 'r1', type: 'function',
          function: { name: 'create_booklist', arguments: '{"name":"违规书单"}' } }] } }] })) },
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '当前只读，无法创建。' } }] })) },
    ];
    let asked = 0;
    const toolResults = [];
    RealAiService.chatStream([{ role: 'user', content: '建个书单' }], {
      onDelta: () => {}, onDone: () => {}, onError: () => {},
      onConfirm: () => { asked += 1; return Promise.resolve(true); },
      onToolResult: (name, l, text) => { toolResults.push([name, text]); },
    }, 128);
    await flush();
    const b1 = JSON.parse(deps.state.requests[0].content);
    assert.equal(b1.tools.length, 22);
    assert.ok(!b1.tools.some((d) => d.function.name === 'create_booklist'));
    assert.ok(b1.tools.some((d) => d.function.name === 'ask_user'), 'ask_user 是只读交互工具，只读档须保留');
    const b2 = JSON.parse(deps.state.requests[1].content);
    assert.equal(b2.messages.find((m) => m.role === 'tool').content,
      '当前为只读权限模式，写操作不可执行');
    assert.equal(asked, 0, '只读模式不该弹确认');
    assert.deepEqual(toolsState.booklistCreateCalls, [], '被挡下的写工具不得执行');
    assert.deepEqual(toolResults[0], ['create_booklist', '当前为只读权限模式，写操作不可执行']);
    deps.state.store.delete('p:ai_permission_mode');
  });

  test('权限模式：自动放行——写工具不弹确认直接执行，活动标注「自动执行」', async () => {
    deps.state.store.set('p:ai_permission_mode', 'auto');
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'deepseek-v4.1-flash', 'sk-oc', 0.5);
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '',
        tool_calls: [{ id: 'a1', type: 'function',
          function: { name: 'create_booklist', arguments: '{"name":"科幻入门"}' } }] } }] })) },
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '已建好' } }] })) },
    ];
    let asked = 0;
    const labels = [];
    RealAiService.chatStream([{ role: 'user', content: '建个书单' }], {
      onDelta: () => {}, onDone: () => {}, onError: () => {},
      onConfirm: () => { asked += 1; return Promise.resolve(false); },
      onTool: (l, name) => { labels.push([name, l]); },
    }, 128);
    await flush();
    const b1 = JSON.parse(deps.state.requests[0].content);
    assert.equal(b1.tools.length, 35, 'auto 模式写工具须在 tools 里');
    assert.equal(asked, 0, 'auto 模式不该弹确认');
    assert.deepEqual(labels, [['create_booklist', '创建书单（自动执行）']]);
    assert.deepEqual(toolsState.booklistCreateCalls.map((c) => c.name), ['科幻入门']);
    toolsState.booklistCreateCalls.length = 0;
    deps.state.store.delete('p:ai_permission_mode');
  });

  test('权限模式：未设置/非法值回落逐笔确认，顶栏徽标镜像与持久化联动', () => {
    deps.state.store.delete('p:ai_permission_mode');
    assert.equal(RealAiService.loadPermission(), 'confirm');
    deps.state.store.set('p:ai_permission_mode', 'garbage');
    assert.equal(RealAiService.loadPermission(), 'confirm');
    RealAiService.savePermission('readonly');
    assert.equal(RealAiService.loadPermission(), 'readonly');
    deps.state.store.delete('p:ai_permission_mode');
    const page = chat();
    page.permission = 'readonly';
    assert.equal(page.permissionLabel(), '只读');
    page.permission = 'auto';
    assert.equal(page.permissionLabel(), '自动放行');
    page.applyPermission('confirm');
    assert.equal(page.permission, 'confirm');
    assert.equal(page.permissionLabel(), '逐笔确认');
    // 页面桩走 shim 的 AiService.savePermission，落在全局 settings 里
    assert.equal(state.settings.permission, 'confirm');
  });

  test('系统提示词：网关档含工具指引与三档权限补注，非网关档不提工具', async () => {
    chat();
    const store = AiChatStore.instance();
    // 工具指引段只在挂 tools 的网关通道出现，本用例主体先钉成网关配置
    const savedConfig = state.settings.config;
    state.settings.config = { ...savedConfig, baseUrl: 'https://opencode.ai/zen/go/v1' };
    const sys = (await store.buildContext())[0].content;
    assert.ok(!sys.includes('（书籍详情，需 id）'), '旧版逐工具枚举未删净（与 tools payload 重复）');
    assert.ok(!sys.includes('写操作工具：create_booklist'), '写工具清单枚举未删净');
    assert.ok(sys.includes('回答与思考过程一律使用中文'), '缺中文约束');
    assert.ok(sys.includes('工具返回「暂时失败」时可稍后原样重试一次'), '缺工具失败重试引导');
    assert.ok(sys.includes('返回「执行失败」时按错误提示修正参数或方案再试'), '缺确定性失败修正指引');
    assert.ok(sys.includes('自我学习：用 save_memory'), '工具档缺自我学习规程');
    assert.ok(sys.includes('先用 forget_memory 删除再 save 新版'), '学习规程缺冲突更新纪律');
    assert.ok(sys.includes('不要记录：工具随时可查的数据'), '学习规程缺不该记清单');
    assert.ok(sys.includes('当前为「逐笔确认」权限模式'), 'confirm 档缺补注');
    state.settings.permission = 'readonly';
    const ro = (await store.buildContext())[0].content;
    assert.ok(ro.includes('当前为「只读」权限模式'), 'readonly 档缺补注');
    assert.ok(ro.includes('「逐笔确认」或「自动放行」'), 'readonly 补注未给准确目标档位名');
    assert.ok(!ro.includes('当前为「逐笔确认」权限模式'), 'readonly 档不得再带 confirm 补注');
    state.settings.permission = 'auto';
    const auto = (await store.buildContext())[0].content;
    assert.ok(auto.includes('当前为「自动放行」权限模式'), 'auto 档缺补注');
    assert.ok(auto.includes('不逐笔确认、直接执行'), 'auto 补注缺行为定义');
    assert.ok(!auto.includes('失败时不要重试'), 'auto 补注与工具失败重试引导矛盾');
    state.settings.permission = 'confirm';
    // 非网关通道不挂 tools：提「调用工具」会诱导模型伪造伪工具调用文本当正文
    state.settings.config = { ...savedConfig, baseUrl: 'https://api.deepseek.com/v1' };
    const noTools = (await store.buildContext())[0].content;
    assert.ok(!noTools.includes('先调用相应工具'), '无 tools 档不得写「先调用相应工具」');
    assert.ok(!noTools.includes('权限模式'), '无 tools 档不得带权限补注');
    assert.ok(!noTools.includes('search_sonovel'), '无 tools 档不得带跨工具流程指引');
    assert.ok(!noTools.includes('自我学习'), '无 tools 档不得带学习规程（save_memory 无写入通道）');
    assert.ok(noTools.includes('回答与思考过程一律使用中文'), '中文约束应全档保留');
    assert.ok(noTools.includes('如实说明不确定，绝不编造'), '无 tools 档仍须防编造');
    state.settings.config = savedConfig;
  });

  test('技能：六个内置技能均带工具指引，点击填入输入框', () => {
    assert.equal(AI_SKILLS.length, 6);
    const prompts = AI_SKILLS.map((s) => s.prompt);
    for (const tool of ['search_books', 'book_detail', 'book_notes', 'reading_history',
      'search_sonovel', 'add_sonovel_task', 'list_download_tasks', 'create_booklist', 'add_books_to_booklist']) {
      assert.ok(prompts.some((p) => p.includes(tool)), `缺工具 ${tool}`);
    }
    for (const s of AI_SKILLS) {
      assert.ok(s.label.length > 0 && s.hint.length > 0, s.label);
      assert.ok(s.prompt.includes('《') || s.prompt.includes('「'), s.label);
    }
    const page = chat();
    page.applySkill(AI_SKILLS[0]);
    assert.equal(page.input, AI_SKILLS[0].prompt);
  });

  test('parseToolBookLines：解析三类列表行（纯书名行/带状态前缀），跳非条目行', () => {
    const books = parseToolBookLines(
      '书架上找到 2 本：\n- 《三体》（刘慈欣） id=12\n- [下载中] 《夜名》（肘子） 进度 42%\n' +
        '说明：《三体》是系列\n普通文本行');
    assert.equal(books.length, 2);
    assert.equal(books[0].title, '《三体》');
    assert.equal(books[0].subtitle, '（刘慈欣） id=12');
    assert.equal(books[1].title, '《夜名》');
    assert.ok(books[1].subtitle.startsWith('[下载中]'));
  });

  test('对话页活动时间线：doing→done/rejected 翻转，书目结果转结构化条目', () => {
    const page = chat();
    page.store.beginActivity('search_books', '搜索书架');
    assert.equal(page.liveActivities.length, 1);
    assert.equal(page.liveActivities[0].state, 'doing');
    page.store.endActivity('search_books', '搜索书架', '书架上找到 2 本：\n- 《三体》（刘慈欣） id=12\n- 《三体全集》（刘慈欣） id=444');
    assert.equal(page.liveActivities[0].state, 'done');
    assert.equal(page.liveActivities[0].books.length, 2);
    assert.equal(page.liveActivities[0].books[0].title, '《三体》');
    assert.equal(page.liveActivities[0].summary, '');
    page.store.beginActivity('create_booklist', '创建书单');
    page.store.endActivity('create_booklist', '创建书单', '用户拒绝了该操作');
    const lastAct = page.liveActivities[1];
    assert.equal(lastAct.state, 'rejected');
    assert.equal(lastAct.books.length, 0);
    assert.equal(lastAct.summary, '用户拒绝了该操作');
    // 同名多条 doing：只翻最后一条
    page.store.beginActivity('search_sonovel', '搜索网络小说书源');
    page.store.beginActivity('search_sonovel', '搜索网络小说书源');
    page.store.endActivity('search_sonovel', '搜索网络小说书源', '各书源没有相关小说');
    assert.equal(page.liveActivities[2].state, 'doing');
    assert.equal(page.liveActivities[3].state, 'done');
    assert.equal(page.liveActivities[3].summary, '各书源没有相关小说');
    // 闸门拒绝的工具不走 beginActivity：endActivity 须补记 ✕ 行（上板发现：拒绝不可见）
    page.store.endActivity('add_sonovel_task', '添加 so-novel 下载任务', '用户拒绝了该操作');
    const appended = page.liveActivities[4];
    assert.equal(appended.state, 'rejected');
    assert.equal(appended.name, 'add_sonovel_task');
    assert.equal(appended.summary, '用户拒绝了该操作');
  });

  test('search_books 结构化缓存：takeLastBooks 带封面、读后即清、下次执行防串台', async () => {
    toolsState.search = async (q) => (q === '三体'
      ? [{ id: 12, title: '三体', authors: ['刘慈欣'], coverUrl: '/get/cover/12.jpg' }] : []);
    const text = await RealAiTools.execute('search_books', '{"query":"三体"}');
    assert.ok(text.includes('- 《三体》（刘慈欣） id=12'));
    const books = RealAiTools.takeLastBooks();
    assert.equal(books.length, 1);
    assert.equal(books[0].title, '《三体》');
    assert.equal(books[0].cover, '/get/cover/12.jpg');
    assert.equal(RealAiTools.takeLastBooks().length, 0, '读后即清');
    await RealAiTools.execute('search_books', '{"query":"鲁滨逊"}');
    assert.equal(RealAiTools.takeLastBooks().length, 0, '无结果时不留旧缓存');
  });

  test('list_categories：解析 nav 分类与子标签，空数据给兜底提示', async () => {
    toolsState.bookNavAsync = async () => ({ status: 200, body: { navs: [
      { legend: '科幻时空', tags: [{ name: '科幻', count: 12 }, { name: '', count: 1 }] },
      { legend: '文化', tags: [] },
      { legend: '', tags: [{ name: '幽灵分类' }] },
    ] } });
    const out = await RealAiTools.execute('list_categories', '{}');
    assert.ok(out.includes('现有 2 个分类'), out);
    assert.ok(out.includes('· 科幻时空：科幻') && out.includes('· 文化'), out);
    assert.ok(!out.includes('幽灵分类') && !out.includes('undefined'), '空 legend 跳过、名字段过滤空串');
    toolsState.bookNavAsync = async () => ({ status: 200, body: { navs: [] } });
    assert.ok((await RealAiTools.execute('list_categories', '{}')).includes('没有读到分类列表'));
    toolsState.bookNavAsync = null;
  });

  test('#1623 工具痕迹：traceBox 采集（并行轮+挡写轮），下轮回放 assistant.tool_calls+tool 历史', async () => {
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'deepseek-v4.1-flash', 'sk-oc', 0.5);
    RealAiService.savePermission('readonly');
    toolsState.search = async (q) => [{ id: q.length, title: q, authors: ['作者'] }];
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '', tool_calls: [
        { id: 'q1', type: 'function', function: { name: 'search_books', arguments: '{"query":"三体"}' } },
        { id: 'q2', type: 'function', function: { name: 'search_books', arguments: '{"query":"玫瑰星球"}' } },
      ] } }] })) },
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '', tool_calls: [
        { id: 'w1', type: 'function', function: { name: 'add_to_shelf', arguments: '{"bookId":1}' } },
      ] } }] })) },
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '查到了，加书架被挡。' } }] })) },
    ];
    let trace = null;
    let error = '';
    RealAiService.chatStream([{ role: 'user', content: '查两本并加书架' }], {
      onDelta: () => {}, onDone: (f, u, tr) => { trace = tr; }, onError: (m) => { error = m; },
    }, 256);
    await flush();
    assert.equal(error, '');
    assert.ok(trace !== null && trace.length === 2, `trace 应 2 轮：${JSON.stringify(trace)}`);
    assert.equal(trace[0].calls.length, 2);
    assert.equal(trace[0].calls[0].id, 'q1');
    assert.equal(trace[0].calls[0].name, 'search_books');
    assert.equal(trace[0].calls[0].args, '{"query":"三体"}');
    assert.ok(trace[0].calls[0].result.includes('三体') && trace[0].calls[1].result.includes('玫瑰星球'));
    // 挡写轮也留痕：模型下轮看得到「被挡过」，不反复撞闸门
    assert.equal(trace[1].calls[0].id, 'w1');
    assert.ok(trace[1].calls[0].result.includes('只读权限模式'), trace[1].calls[0].result);
    // 回放：下一轮历史带 toolTrace → 请求体展开为 assistant(tool_calls)+tool×N，且在末文本之前
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '嗯' } }] })) }];
    RealAiService.chatStream([
      { role: 'user', content: '查两本并加书架' },
      { role: 'assistant', content: '查到了，加书架被挡。', toolTrace: trace },
      { role: 'user', content: '你刚才是不是没真加' },
    ], { onDelta: () => {}, onDone: () => {}, onError: () => {} }, 256);
    await flush();
    const sent = JSON.parse(deps.state.requests[0].content).messages;
    const withTc = sent.filter((m) => m.tool_calls !== undefined);
    assert.equal(withTc.length, 2);
    assert.deepEqual(withTc[0].tool_calls.map((c) => c.id), ['q1', 'q2']);
    assert.deepEqual(sent.filter((m) => m.role === 'tool').map((m) => m.tool_call_id), ['q1', 'q2', 'w1']);
    const firstTc = sent.findIndex((m) => m.tool_calls !== undefined);
    const finalText = sent.findIndex((m) => m.role === 'assistant' && m.content === '查到了，加书架被挡。');
    assert.ok(firstTc >= 0 && finalText > firstTc, '回放顺序：工具历史在前、末文本在后（协议合法）');
    // 回放消息不带 toolTrace 键（界面层字段不进协议体）
    assert.equal(withTc[0].toolTrace, undefined);
  });

  test('#1623 工具痕迹持久化：parseBubbles 读 toolTrace，坏项过滤、旧存档兼容', async () => {
    const { parseBubbles } = await load('AiChatModel');
    const raw = [
      { role: 'assistant', content: '完成', streaming: false, error: false, activities: [], toolTrace: [
        { text: '前言', calls: [{ id: 'a', name: 'search_books', args: '{}', result: 'ok' }] },
        { text: '', calls: [] },
        { text: '', calls: [{ name: '缺 id' }] },
        '非对象项',
      ] },
      { role: 'user', content: 'hi', streaming: false, error: false, activities: [] },
    ];
    const bubbles = parseBubbles(JSON.parse(JSON.stringify(raw)));
    assert.equal(bubbles[0].toolTrace.length, 1, '空 calls/缺 id/非对象轮全部过滤');
    assert.equal(bubbles[0].toolTrace[0].text, '前言');
    assert.equal(bubbles[0].toolTrace[0].calls[0].id, 'a');
    assert.equal(bubbles[1].toolTrace, undefined, '无键=undefined（旧存档兼容）');
  });

  test('#1624 回放协议：user 泡痕迹排在问题文本后；空文本 assistant 有痕不推空消息', async () => {
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'deepseek-v4.1-flash', 'sk-oc', 0.5);
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '嗯' } }] })) }];
    const carried = [{ text: '', calls: [{ id: 'c1', name: 'search_books', args: '{"query":"x"}', result: '已执行' }] }];
    RealAiService.chatStream([
      { role: 'system', content: 'sys' },
      { role: 'user', content: '加一本', toolTrace: carried },
      { role: 'assistant', content: '', toolTrace: carried },
    ], { onDelta: () => {}, onDone: () => {}, onError: () => {} }, 256);
    await flush();
    const sent = JSON.parse(deps.state.requests[0].content).messages;
    const uIdx = sent.findIndex((m) => m.role === 'user' && m.content === '加一本');
    const tcIdx = sent.findIndex((m) => m.tool_calls !== undefined);
    assert.ok(uIdx >= 0 && tcIdx > uIdx, `user 痕迹：问题文本在前、工具轮在后（u=${uIdx},tc=${tcIdx}）`);
    // assistant 空文本+痕迹：只展开工具历史，不再推 content='' 的多余消息
    const emptyAssist = sent.filter((m) => m.role === 'assistant' && (m.content ?? '') === '' && m.tool_calls === undefined);
    assert.equal(emptyAssist.length, 0, '空 assistant 文本消息不推');
    assert.deepEqual(sent.filter((m) => m.role === 'tool').map((m) => m.tool_call_id), ['c1', 'c1']);
  });

  test('#1624 store：错误泡留痕进回放（文案不进上下文）；retryFrom 截泡带走痕迹', async () => {
    const { collectTraces } = await load('AiChatModel');
    const mk = (role, extra) => Object.assign({ role, content: '', streaming: false, error: false,
      activities: [], images: [], reasoning: '', voice: false, ts: 1 }, extra);
    const trace = [{ text: '', calls: [{ id: 'c1', name: 'add_to_shelf', args: '{"bookId":9}', result: '已加入' }] }];
    // collectTraces：拼接 from 起所有痕迹
    const bs = [mk('user', {}), mk('assistant', { toolTrace: trace }), mk('assistant', { toolTrace: trace })];
    assert.equal(collectTraces(bs, 1).length, 2);
    assert.equal(collectTraces(bs, 2).length, 1);
    assert.equal(collectTraces(bs, 0).length, 2);
    const store = AiChatStore.instance();
    store.resetForTest();
    // 错误轮 finishBubble 不再弃痕
    store.messages = [mk('user', { content: '加一本' }), mk('assistant', { streaming: true })];
    store.finishBubble('网络错误', true, undefined, trace);
    assert.equal(store.messages[1].error, true);
    assert.ok(store.messages[1].toolTrace !== undefined && store.messages[1].toolTrace.length === 1,
      '错误轮保留工具痕迹');
    // buildContext：有痕错误泡仍回放，content 置空（错误文案不进上下文）
    const ctxMsgs = await store.buildContext();
    const lastMsg = ctxMsgs[ctxMsgs.length - 1];
    assert.equal(lastMsg.role, 'assistant');
    assert.equal(lastMsg.content, '', '错误文案不进上下文');
    assert.ok(lastMsg.toolTrace !== undefined, '错误泡痕迹透传给回放');
    // retryFrom：截掉的错误泡痕迹移挂问题泡
    store.messages = [mk('user', { content: '加一本' }),
      mk('assistant', { error: true, content: '网络错误', toolTrace: trace })];
    state.ready = true;
    assert.equal(store.retryFrom(2), true);
    // send 同步段已重推问题+流式泡；messages[0] 即带痕的问题泡
    assert.ok(store.messages[0].toolTrace !== undefined && store.messages[0].toolTrace.length === 1,
      '重试轮问题泡携带被截泡的痕迹');
    await flush();
  });

  test('#1628 痕迹回放 token 治理：仅最近 TRACE_FULL_ROUNDS 轮全量展开，旧轮压一行摘要', async () => {
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'deepseek-v4.1-flash', 'sk-oc', 0.5);
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '嗯' } }] })) }];
    const mkRound = (id) => ({ text: '', calls: [{ id, name: 'search_books', args: '{}', result: `RESULT_${id}_`.repeat(40) }] });
    RealAiService.chatStream([
      { role: 'system', content: 'sys' },
      { role: 'user', content: 'q1' },
      { role: 'assistant', content: 'a1', toolTrace: [mkRound('r1'), mkRound('r2'), mkRound('r3')] },
    ], { onDelta: () => {}, onDone: () => {}, onError: () => {} }, 256);
    await flush();
    const sent = JSON.parse(deps.state.requests[0].content).messages;
    const withTc = sent.filter((m) => m.tool_calls !== undefined);
    assert.deepEqual(withTc.map((m) => m.tool_calls[0].id), ['r2', 'r3'], '仅最近 2 轮全量展开');
    const compressed = sent.filter((m) => m.role === 'assistant' && (m.content ?? '').includes('早前工具轮已执行'));
    assert.equal(compressed.length, 1);
    assert.ok(compressed[0].content.includes('search_books'), '压缩行仍告知做过什么');
    const body = JSON.stringify(sent);
    assert.ok(!body.includes('RESULT_r1'), '旧轮 result 全文不进请求体');
    assert.ok(body.includes('RESULT_r3'), '最近轮 result 仍全量回放');
  });

}
