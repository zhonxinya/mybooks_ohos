// 用例组 2：AiTools 读写工具与流式回路（含防崩）（拆分自 check_ai_assistant.mjs，用例体原样）
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { test, state, settingsDefaults, enc, rtB64, deferred, tick, flush } from './base.mjs';
import { dir, read, ETS, ROOT } from './paths.mjs';

export function register(ctx) {
  const { load, deps, RealAiService, RealAiTools, parseToolBookLines, toolsState, mdParseBlocks, mdParseInline, AI_SKILLS, AiAssistantPage, AiBookPanelPage, AiRecommendPage, AiSettingsPage, AiPersonaPage, AiPersona, DEFAULT_SOUL, AiChatStore, personaState, MetaSearchService, NovelMetaService, resetSettings, settingsPage, chat, reappear } = ctx;
  test('AiTools：只读工具返回精简文本（搜索/详情/笔记/历史/未知工具/失败包装）', async () => {
    toolsState.search = async (q) => (q === '三体' ? [{ id: 12, title: '三体', authors: ['刘慈欣', '某某'] }] : []);
    assert.ok((await RealAiTools.execute('search_books', '{"query":"三体"}')).includes('- 《三体》（刘慈欣、某某） id=12'));
    assert.ok((await RealAiTools.execute('search_books', '{"query":"鲁滨逊"}')).includes('没有找到'));
    assert.ok((await RealAiTools.execute('search_books', '')).includes('query'));
    toolsState.detail = async (id) => (id === 12
      ? { id: 12, title: '三体', authors: ['刘慈欣'], rating: 9.2, tags: ['科幻'],
        files: [{ format: 'epub', size: 1 }, { format: 'mobi', size: 2 }],
        comments: 'x'.repeat(600), coverUrl: '', downloadUrl: '',
        publisher: '重庆出版社', isbn: '9787536692930', series: '' }
      : null);
    const detailText = await RealAiTools.execute('book_detail', '{"book_id":12}');
    assert.ok(detailText.includes('《三体》（刘慈欣）') && detailText.includes('epub、mobi') && detailText.includes('…'));
    assert.ok(detailText.includes('出版社：重庆出版社') && detailText.includes('ISBN：9787536692930'));
    assert.ok(!detailText.includes('丛书：'));
    assert.ok((await RealAiTools.execute('book_detail', '{"book_id":99}')).includes('没有找到 id=99'));
    toolsState.notes = [];
    assert.ok((await RealAiTools.execute('book_notes', '{"book_id":12}')).includes('还没有'));
    toolsState.notes = [{ annotationType: 'note', chapter: '第一章 命运', quoteText: '宇宙很大', content: '铺垫好' }];
    const notesText = await RealAiTools.execute('book_notes', '{"book_id":12}');
    assert.ok(notesText.includes('[笔记]') && notesText.includes('宇宙很大') && notesText.includes('铺垫好'));
    toolsState.history = [
      { bookId: 'a', title: '活着', lastReadTime: 1000, chapterName: '第12节', progressPercent: 30.4 },
      { bookId: 'b', title: '平凡的世界', lastReadTime: 5000, progressPercent: 8 },
    ];
    const historyText = await RealAiTools.execute('reading_history', '{}');
    assert.ok(historyText.indexOf('平凡的世界') < historyText.indexOf('活着'), '按最近阅读时间倒序');
    assert.ok(historyText.includes('进度 30%'));
    toolsState.history = [];
    assert.ok((await RealAiTools.execute('reading_history', '{}')).includes('还没有阅读记录'));
    assert.ok((await RealAiTools.execute('delete_book', '{}')).includes('未知工具'));
    assert.equal(RealAiTools.toolLabel('search_books'), '搜索书架');
    assert.equal(RealAiTools.toolLabel('reading_history'), '查看阅读历史');
    assert.equal(RealAiTools.toolLabel('mystery'), 'mystery');
    toolsState.notesError = '未登录';
    assert.ok((await RealAiTools.execute('book_notes', '{"book_id":12}')).includes('执行失败'));
    toolsState.notesError = '';
  });

  test('AiTools：so-novel 与书单工具（搜源/入队去重/任务列表/建单加书/确认登记）', async () => {
    toolsState.sonovelEnvelope = { status: 200, error: '', body: { code: 200, message: '', data: [
      { sourceId: 3, sourceName: '某书源', url: 'http://x/book/1/', bookName: '夜的命名术',
        author: '会说话的肘子', latestChapter: '第1200章 尾声', status: '已完结' },
    ] } };
    const s = await RealAiTools.execute('search_sonovel', '{"query":"夜的命名术"}');
    assert.ok(s.includes('《夜的命名术》') && s.includes('书源：某书源(id=3)') &&
      s.includes('url：http://x/book/1/') && s.includes('add_sonovel_task'));
    toolsState.tasks = [];
    toolsState.processed = 0;
    const t = await RealAiTools.execute('add_sonovel_task',
      '{"book_name":"夜的命名术","url":"http://x/book/1/","author":"会说话的肘子","source_id":3,"source_name":"某书源"}');
    // so-novel 下载在服务器（云端）执行，完成后应用拉取落架——文案两头都要说准
    assert.ok(t.includes('已加入云端下载任务') && t.includes('格式 epub') &&
      t.includes('下载与转换在服务器进行') && t.includes('自动拉取到本地书架'), t);
    assert.equal(toolsState.tasks.length, 1);
    assert.equal(toolsState.processed, 1);
    // bug#1486 防线：工具入参的元数据必须原样进入下载 payload（入库记录取的就是这些字段）
    assert.equal(toolsState.tasks[0].payload.author, '会说话的肘子');
    const tc = await RealAiTools.execute('add_sonovel_task',
      '{"book_name":"黎明之剑","url":"http://x/book/9/","author":"远瞳","cover":"http://img/9.jpg","source_id":3}');
    assert.ok(tc.includes('已加入云端下载任务'), tc);
    assert.equal(toolsState.tasks[1].payload.cover, 'http://img/9.jpg');
    const dup = await RealAiTools.execute('add_sonovel_task', '{"book_name":"夜的命名术","url":"http://x/book/1/"}');
    assert.ok(dup.includes('已在下载队列中'));
    assert.equal(toolsState.tasks.length, 2);
    toolsState.tasks[0].status = 'downloading';
    toolsState.tasks[0].progress = 42;
    toolsState.tasks[0].message = '章节进度 42/100';
    const l = await RealAiTools.execute('list_download_tasks', '{}');
    assert.ok(l.includes('[下载中] 《夜的命名术》') && l.includes('42%'));
    const c = await RealAiTools.execute('create_booklist', '{"name":"赛博朋克","description":"d"}');
    assert.ok(c.includes('已创建书单「赛博朋克」（id=77）'));
    assert.deepEqual(toolsState.booklistCreateCalls[0],
      { name: '赛博朋克', description: 'd', color: '#1890ff', isPublic: true });
    toolsState.booklistCreateResult = { err: 'unauthorized', msg: '请先登录' };
    assert.ok((await RealAiTools.execute('create_booklist', '{"name":"x"}')).includes('创建书单失败：请先登录'));
    toolsState.booklistCreateResult = null;
    const a = await RealAiTools.execute('add_books_to_booklist', '{"booklist_id":77,"book_ids":"12, 44 ,abc"}');
    assert.deepEqual(toolsState.booklistAddCalls[0], { id: 77, ids: [12, 44] });
    assert.ok(a.includes('已把 2 本书加入书单') && a.includes('现有 2 本'));
    assert.ok((await RealAiTools.execute('add_books_to_booklist', '{"booklist_id":0,"book_ids":""}')).includes('必填'));
    assert.equal(RealAiTools.needsConfirm('create_booklist'), true);
    assert.equal(RealAiTools.needsConfirm('add_sonovel_task'), true);
    assert.equal(RealAiTools.needsConfirm('search_books'), false);
    assert.equal(RealAiTools.needsConfirm('search_sonovel'), false);
    toolsState.sonovelEnvelope = null;
    toolsState.tasks = [];
    toolsState.booklistCreateCalls.length = 0;
    toolsState.booklistAddCalls.length = 0;
  });

  test('AiTools：add_to_shelf——书库书下载到本机书架（登录/去重/格式/配额/入队）', async () => {
    toolsState.tasks = [];
    toolsState.talebookEnqueues.length = 0;
    toolsState.processed = 0;
    toolsState.dirs.clear();
    toolsState.detail = async (id) => (id === 12
      ? { id: 12, title: '三体', authors: ['刘慈欣'], rating: 9.2, tags: [],
        files: [{ format: 'EPUB', size: 1 }, { format: 'MOBI', size: 2 }],
        comments: '', coverUrl: '/cover/12.png', downloadUrl: '',
        publisher: '', isbn: '', series: '' }
      : null);
    toolsState.authOk = false;
    assert.ok((await RealAiTools.execute('add_to_shelf', '{"book_id":12}')).includes('尚未登录'));
    toolsState.authOk = true;
    assert.ok((await RealAiTools.execute('add_to_shelf', '{}')).includes('book_id 无效'));
    assert.ok((await RealAiTools.execute('add_to_shelf', '{"book_id":99}')).includes('找不到 id=99'));
    assert.ok((await RealAiTools.execute('add_to_shelf', '{"book_id":12,"format":"pdf"}')).includes('没有 pdf 格式'));
    // 成功入队：默认 epub、destPath 与页面链路一致、立即调度
    toolsState.tasks = [];
    const ok = await RealAiTools.execute('add_to_shelf', '{"book_id":12}');
    assert.ok(ok.includes('已加入下载队列') && ok.includes('格式 epub') && ok.includes('list_download_tasks'), ok);
    assert.equal(toolsState.talebookEnqueues.length, 1);
    const p = toolsState.talebookEnqueues[0];
    assert.equal(p.bookId, 12);
    assert.equal(p.author, '刘慈欣');
    assert.equal(p.cover, 'https://stub.example/cover/12.png');
    assert.equal(p.format, 'epub');
    assert.ok(p.destPath.endsWith('/books/12.epub'), p.destPath);
    assert.equal(toolsState.processed, 1);
    // 队列已有 pending → 去重文案，不重复入队
    const dup = await RealAiTools.execute('add_to_shelf', '{"book_id":12}');
    assert.ok(dup.includes('已在下载队列'), dup);
    assert.equal(toolsState.talebookEnqueues.length, 1);
    // 已完成 → 提示已在架
    toolsState.tasks[0].status = 'completed';
    assert.ok((await RealAiTools.execute('add_to_shelf', '{"book_id":12}')).includes('已下载到本机书架'));
    // 配额用完 → 拦下且不入队
    toolsState.tasks = [];
    toolsState.quotaResult = { allowed: false, used: 10, quota: 10 };
    const q = await RealAiTools.execute('add_to_shelf', '{"book_id":12}');
    assert.ok(q.includes('配额已用完') && q.includes('10/10'), q);
    assert.equal(toolsState.talebookEnqueues.length, 1);
    // 配额查询无字段（服务器未给 allowed）→ fail-open 继续入队，指定 mobi 生效
    toolsState.quotaResult = null;
    assert.ok((await RealAiTools.execute('add_to_shelf', '{"book_id":12,"format":"MOBI"}'))
      .includes('已加入下载队列'));
    assert.equal(toolsState.talebookEnqueues.length, 2);
    assert.equal(toolsState.talebookEnqueues[1].format, 'mobi');
    // 闸门与标签
    assert.equal(RealAiTools.needsConfirm('add_to_shelf'), true);
    assert.equal(RealAiTools.toolLabel('add_to_shelf'), '加入书架');
    toolsState.tasks = [];
    toolsState.talebookEnqueues.length = 0;
    toolsState.dirs.clear();
    toolsState.detail = null;
  });

  test('AiTools：书单全生命周期（list/update 读合并写/delete/remove/非本人拒绝）', async () => {
    const mine = { err: 'ok', booklists: [
      { id: 5, name: '科幻入门', description: 'd1', color: '#1890ff', is_public: true,
        book_count: 12, is_owner: true },
      { id: 9, name: '待读', description: '', color: '#ff5722', is_public: false,
        book_count: 3, is_owner: true },
    ] };
    toolsState.myBooklists = mine;
    toolsState.booklistDetail = { 5: { id: 5, name: '科幻入门', description: 'd1', color: '#1890ff',
      is_public: true, book_count: 12, is_owner: true },
    9: { id: 9, name: '待读', description: '', color: '#ff5722', is_public: false,
      book_count: 3, is_owner: true },
    77: { id: 77, name: '别人的', description: '', color: '#1890ff', is_public: true,
      book_count: 1, is_owner: false } };
    const l = await RealAiTools.execute('list_booklists', '{}');
    assert.ok(l.includes('「科幻入门」（id=5，12 本，公开') && l.includes('「待读」（id=9，3 本，私有'), l);
    // update 读-合并-写：只改名，description/color/is_public 必须回填原值（update 是全量覆盖）
    const u = await RealAiTools.execute('update_booklist', '{"booklist_id":5,"name":"科幻经典"}');
    assert.ok(u.includes('名称「科幻入门」→「科幻经典」'), u);
    const p = toolsState.booklistUpdateCalls[0].payload;
    assert.equal(p.name, '科幻经典');
    assert.equal(p.description, 'd1');
    assert.equal(p.color, '#1890ff');
    assert.equal(p.is_public, true);
    // is_public 切换 + 非法值拒绝 + 全空拒绝
    assert.ok((await RealAiTools.execute('update_booklist', '{"booklist_id":9,"is_public":"true"}'))
      .includes('已设为公开'));
    assert.ok((await RealAiTools.execute('update_booklist', '{"booklist_id":9,"is_public":"yes"}'))
      .includes('只接受 true 或 false'));
    assert.ok((await RealAiTools.execute('update_booklist', '{"booklist_id":9}')).includes('至少给出'));
    // 同值不算改动
    assert.ok((await RealAiTools.execute('update_booklist', '{"booklist_id":9,"name":"待读"}'))
      .includes('与现值相同'));
    // 非本人书单拒绝一切改动
    assert.ok((await RealAiTools.execute('update_booklist', '{"booklist_id":77,"name":"x"}'))
      .includes('找不到你创建的书单'));
    assert.ok((await RealAiTools.execute('delete_booklist', '{"booklist_id":77}'))
      .includes('找不到你创建的书单'));
    // delete：先查详情再删，文案带名称与书本数
    const d = await RealAiTools.execute('delete_booklist', '{"booklist_id":9}');
    assert.ok(d.includes('书单「待读」（3 本）已删除') && d.includes('不受影响'), d);
    assert.deepEqual(toolsState.booklistDeleteCalls, [9]);
    // remove_book：书单校验 + 书名回填
    toolsState.detail = async (id) => (id === 12
      ? { id: 12, title: '三体', authors: ['刘慈欣'], rating: 9, tags: [], files: [],
        comments: '', coverUrl: '', downloadUrl: '', publisher: '', isbn: '', series: '' } : null);
    const r = await RealAiTools.execute('remove_book_from_booklist', '{"booklist_id":5,"book_id":12}');
    assert.ok(r.includes('已把《三体》从书单「科幻入门」移出'), r);
    assert.deepEqual(toolsState.booklistRemoveCalls, [{ id: 5, bookId: 12 }]);
    assert.ok((await RealAiTools.execute('remove_book_from_booklist', '{"booklist_id":5}'))
      .includes('都要给出'));
    assert.equal(RealAiTools.needsConfirm('update_booklist'), true);
    assert.equal(RealAiTools.needsConfirm('delete_booklist'), true);
    assert.equal(RealAiTools.needsConfirm('list_booklists'), false);
    assert.equal(RealAiTools.toolLabel('list_booklists'), '查询我的书单');
    toolsState.booklistUpdateCalls.length = 0;
    toolsState.booklistDeleteCalls.length = 0;
    toolsState.booklistRemoveCalls.length = 0;
    toolsState.myBooklists = null;
    toolsState.booklistDetail = null;
    toolsState.detail = null;
  });

  test('AiTools：push_to_device 与 reading_stats（kindle 邮箱、设备自动匹配、ftp 拒绝）', async () => {
    toolsState.detail = async (id) => (id === 12
      ? { id: 12, title: '三体', authors: ['刘慈欣'], rating: 9, tags: [], files: [],
        comments: '', coverUrl: '', downloadUrl: '', publisher: '', isbn: '', series: '' } : null);
    toolsState.devices = [
      { name: 'K1', type: 'kindle', ip: '', port: 0, schema: 'http', mailbox: 'me@kindle.com',
        ftpUsername: '', ftpPassword: '', ftpPath: '' },
      { name: 'B1', type: 'boox', ip: '192.168.1.9', port: 8080, schema: 'http', mailbox: '',
        ftpUsername: '', ftpPassword: '', ftpPath: '' },
    ];
    // kindle 省略 target → 自动取登记邮箱
    const k = await RealAiTools.execute('push_to_device', '{"book_id":12,"device_type":"kindle"}');
    assert.ok(k.includes('已把《三体》推送到') && k.includes('me@kindle.com'), k);
    assert.deepEqual(toolsState.pushCalls[0],
      { bookId: 12, type: 'kindle', url: '', mailbox: 'me@kindle.com' });
    // boox 省略 target → 按类型拼设备地址
    assert.ok((await RealAiTools.execute('push_to_device', '{"book_id":12,"device_type":"boox"}'))
      .includes('http://192.168.1.9:8080'));
    // 未登记类型且没给 target → 引导；显式 target 可用
    assert.ok((await RealAiTools.execute('push_to_device', '{"book_id":12,"device_type":"duokan"}'))
      .includes('没有登记'));
    assert.ok((await RealAiTools.execute('push_to_device',
      '{"book_id":12,"device_type":"duokan","target":"http://10.0.0.2:8000"}')).includes('推送'));
    // ftp 与非法类型拒绝
    assert.ok((await RealAiTools.execute('push_to_device', '{"book_id":12,"device_type":"ftp"}'))
      .includes('详情页'));
    assert.ok((await RealAiTools.execute('push_to_device', '{"book_id":12,"device_type":"nook"}'))
      .includes('不支持的设备类型'));
    // 未登录挡下
    toolsState.authOk = false;
    assert.ok((await RealAiTools.execute('push_to_device', '{"book_id":12,"device_type":"boox"}'))
      .includes('尚未登录'));
    toolsState.authOk = true;
    assert.equal(RealAiTools.needsConfirm('push_to_device'), true);
    // reading_stats：四格计数 + 在读列表
    toolsState.readingStats = { totalReading: 4, totalReadDone: 21, monthReading: 2, monthReadDone: 1 };
    toolsState.currentReading = [
      { id: 12, title: '三体', author: '刘慈欣', cover: '', recommender: null },
      { id: 13, title: '活着', author: '', cover: '', recommender: null },
    ];
    const s = await RealAiTools.execute('reading_stats', '{}');
    assert.ok(s.includes('累计在读 4 本、累计读完 21 本') && s.includes('本月读完 1 本'), s);
    assert.ok(s.includes('- 《三体》（刘慈欣）') && s.includes('- 《活着》（佚名）'), s);
    toolsState.readingStats = null;
    assert.ok((await RealAiTools.execute('reading_stats', '{}')).includes('未返回阅读统计'));
    assert.equal(RealAiTools.needsConfirm('reading_stats'), false);
    toolsState.pushCalls.length = 0;
    toolsState.devices = null;
    toolsState.currentReading = null;
    toolsState.detail = null;
  });

  test('思考强度：网关 body 透传 reasoning_effort，default 档不发该字段', async () => {
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'deepseek-v4.1-flash', 'sk-oc', 0.5);
    const reply = (t) => ({ statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: t } }] })) });
    RealAiService.saveReasoningEffort('medium');
    deps.state.rcpResponses = [reply('a')];
    RealAiService.chatStream([{ role: 'user', content: 'q' }],
      { onDelta: () => {}, onDone: () => {}, onError: () => {} }, 64);
    await flush();
    assert.ok(deps.state.requests.at(-1).content.includes('"reasoning_effort":"medium"'),
      deps.state.requests.at(-1).content);
    RealAiService.saveReasoningEffort('default');
    deps.state.requests.length = 0;
    deps.state.rcpResponses = [reply('b')];
    RealAiService.chatStream([{ role: 'user', content: 'q' }],
      { onDelta: () => {}, onDone: () => {}, onError: () => {} }, 64);
    await flush();
    assert.ok(!deps.state.requests.at(-1).content.includes('reasoning_effort'), 'default 档不发强度字段');
  });

  test('思考强度：SDK 通道 params 注入 reasoning_effort，default 档不注入', async () => {
    RealAiService.saveConfig('deepseek', 'https://api.deepseek.com', 'deepseek-chat', 'sk-d', 0.5);
    RealAiService.saveReasoningEffort('high');
    deps.state.chatCalls.length = 0;
    await RealAiService.complete([{ role: 'user', content: 'q' }], 64);
    assert.equal(deps.state.chatCalls.at(-1).body.reasoning_effort, 'high');
    RealAiService.saveReasoningEffort('default');
    deps.state.chatCalls.length = 0;
    await RealAiService.complete([{ role: 'user', content: 'q' }], 64);
    assert.equal(deps.state.chatCalls.at(-1).body.reasoning_effort, undefined, 'default 档不注入');
  });

  test('网关工具回路：执行 tool_calls 回填结果，第二轮拿到最终回答', async () => {
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    // 前面 fetchModels 用例写入过持久 id，这里重置为「未生成」态验证回路也走稳定会话头
    deps.state.store.delete('p:ai_opencode_session');
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'deepseek-v4.1-flash', 'sk-oc', 0.5);
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '',
        tool_calls: [{ id: 'call_1', type: 'function',
          function: { name: 'search_books', arguments: '{"query":"三体"}' } }] } }] })) },
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '帮你查到了《三体》，id=12。' } }] })) },
    ];
    toolsState.search = async (q) => (q === '三体' ? [{ id: 12, title: '三体', authors: ['刘慈欣'] }] : []);
    let full = '';
    let error = '';
    const toolLabels = [];
    const toolResults = [];
    RealAiService.chatStream([{ role: 'user', content: '书架上有三体吗' }], {
      onDelta: (t) => { full += t; }, onDone: () => {}, onError: (m) => { error = m; },
      onTool: (l, name) => { toolLabels.push([name, l]); },
      onToolResult: (name, l, text) => { toolResults.push([name, text]); },
    }, 256);
    await flush();
    assert.equal(error, '');
    assert.deepEqual(toolLabels, [['search_books', '搜索书架']]);
    assert.equal(toolResults.length, 1);
    assert.equal(toolResults[0][0], 'search_books');
    assert.ok(toolResults[0][1].includes('- 《三体》（刘慈欣） id=12'));
    assert.equal(deps.state.requests.length, 2);
    const b1 = JSON.parse(deps.state.requests[0].content);
    assert.equal(b1.stream, false);
    assert.ok(Array.isArray(b1.tools) && b1.tools.length === 29 && b1.tools[0].function.name === 'search_books');
    assert.equal(deps.state.requests[0].headers['x-opencode-session'], 'test-uuid-fixed-0001');
    const b2 = JSON.parse(deps.state.requests[1].content);
    const assistant = b2.messages.find((m) => m.role === 'assistant');
    assert.equal(assistant.tool_calls[0].function.name, 'search_books');
    const toolMsg = b2.messages.find((m) => m.role === 'tool');
    assert.equal(toolMsg.tool_call_id, 'call_1');
    assert.ok(toolMsg.content.includes('- 《三体》（刘慈欣） id=12'));
    assert.equal(full, '帮你查到了《三体》，id=12。');
  });

  test('工具回路：ask_user 反问——onAsk 点选回填答复，跳过/无回调收敛，逗号归一拆分', async () => {
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'deepseek-v4.1-flash', 'sk-oc', 0.5);
    const askReply = (opts) => ({ statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '',
      tool_calls: [{ id: 'q1', type: 'function', function: { name: 'ask_user',
        arguments: JSON.stringify({ question: '转成什么格式？', options: opts }) } }] } }] })) });
    const finalReply = (t) => ({ statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: t } }] })) });

    // 1) 用户点选：onAsk 收到拆好的问题与选项，回填「用户选择了」续跑
    deps.state.rcpResponses = [askReply('epub、mobi、txt'), finalReply('好，转 mobi')];
    let seen = null;
    const labels = [];
    const results = [];
    const errs = [];
    RealAiService.chatStream([{ role: 'user', content: '把这本转个格式' }], {
      onDelta: () => {}, onDone: () => {}, onError: (e) => { errs.push(e); },
      onAsk: (q, os) => { seen = [q, os]; return Promise.resolve('mobi'); },
      onTool: (l) => { labels.push(l); },
      onToolResult: (n, l, t, id) => { results.push([n, t, id]); },
    }, 128);
    await flush();
    assert.deepEqual(errs, []);
    assert.deepEqual(seen, ['转成什么格式？', ['epub', 'mobi', 'txt']]);
    assert.deepEqual(labels, ['向用户提问']);
    const back1 = JSON.parse(deps.state.requests[1].content);
    const tool1 = back1.messages.find((m) => m.role === 'tool');
    assert.equal(tool1.content, '用户选择了「mobi」');
    assert.equal(tool1.tool_call_id, 'q1');
    assert.ok(back1.messages.some((m) => m.role === 'assistant' && m.tool_calls !== undefined),
      'ask_user 也须回填 assistant(tool_calls)');
    assert.deepEqual(results, [['ask_user', '用户选择了「mobi」', 'q1']]);

    // 2) 跳过 + 英文逗号归一
    deps.state.requests.length = 0;
    deps.state.rcpResponses = [askReply('epub, mobi'), finalReply('按默认来')];
    let seen2 = null;
    RealAiService.chatStream([{ role: 'user', content: '转格式' }], {
      onDelta: () => {}, onDone: () => {}, onError: () => {},
      onAsk: (q, os) => { seen2 = os; return Promise.resolve(''); },
    }, 128);
    await flush();
    assert.deepEqual(seen2, ['epub', 'mobi'], '英文逗号须归一并去空白');
    assert.ok(JSON.parse(deps.state.requests[1].content).messages
      .find((m) => m.role === 'tool').content.startsWith('用户跳过了该问题'), '空答复=跳过文案');

    // 3) 无 onAsk 渠道：收敛为跳过而不是挂等
    deps.state.requests.length = 0;
    deps.state.rcpResponses = [askReply('a、b'), finalReply('那我按常见做法')];
    RealAiService.chatStream([{ role: 'user', content: '转格式' }], {
      onDelta: () => {}, onDone: () => {}, onError: () => {},
    }, 128);
    await flush();
    assert.ok(JSON.parse(deps.state.requests[1].content).messages
      .find((m) => m.role === 'tool').content.startsWith('用户跳过了该问题'), '缺回调按跳过收敛');

    // 4) 语音等直调执行器的渠道：兜底文案引导模型用正文提问
    const voiceText = await RealAiTools.execute('ask_user', '{"question":"x","options":"a、b"}');
    assert.ok(voiceText.includes('当前渠道不支持'), voiceText);
    assert.equal(RealAiTools.toolLabel('ask_user'), '向用户提问');
  });

  test('网关请求重试：网络异常/429/5xx 退避后重试，其他 4xx 不重试，重试用尽才报错', async () => {
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'deepseek-v4.1-flash', 'sk-oc', 0.5);
    const reply = (t) => ({ statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: t } }] })) });
    const runOnce = (prep) => {
      deps.state.requests.length = 0;
      deps.state.rcpResponses.length = 0;
      deps.state.rcpThrowQueue.length = 0;
      prep();
      const box = { full: '', error: '' };
      return new Promise((resolve) => {
        RealAiService.chatStream([{ role: 'user', content: 'hi' }], {
          onDelta: (t) => { box.full += t; },
          onDone: () => resolve(box), onError: (m) => { box.error = m; resolve(box); },
        }, 64);
      });
    };
    // 网络异常：第一次 fetch 抛、第二次成功——旧行为在此直接报废整条回复
    let r = await runOnce(() => {
      deps.state.rcpThrowQueue = [new Error('连接失败')];
      deps.state.rcpResponses = [reply('重试后成功')];
    });
    assert.equal(r.error, '');
    assert.equal(r.full, '重试后成功');
    assert.equal(deps.state.requests.length, 2);
    // 429 限流：退避后重试拿到回答
    r = await runOnce(() => {
      deps.state.rcpResponses = [{ statusCode: 429, body: enc('rate limited') }, reply('429 恢复')];
    });
    assert.equal(r.error, '');
    assert.equal(deps.state.requests.length, 2);
    // 400 参数错误：重试无意义，一次即报错
    r = await runOnce(() => { deps.state.rcpResponses = [{ statusCode: 400, body: enc('bad request') }]; });
    assert.ok(r.error.includes('400'), r.error);
    assert.equal(deps.state.requests.length, 1);
    // 5xx 重试用尽（1+2 次）才报错
    r = await runOnce(() => {
      deps.state.rcpResponses = [{ statusCode: 502, body: enc('bad gateway') },
        { statusCode: 502, body: enc('bad gateway') }, { statusCode: 503, body: enc('unavailable') }];
    });
    assert.ok(r.error.length > 0);
    assert.equal(deps.state.requests.length, 3);
  });

  test('工具失败处理：只读瞬时失败自动重试一次，写工具永不自动重试，确定性失败给修正指引', async () => {
    // 1 只读工具瞬时失败：第一次抛「连接超时」，代码层重试后拿到正常结果
    let okCalls = 0;
    toolsState.searchThrowOnce = '连接超时';
    toolsState.search = async () => { okCalls += 1; return [{ id: 12, title: '三体', authors: ['刘慈欣'] }]; };
    let out = await RealAiTools.execute('search_books', '{"query":"三体"}');
    assert.ok(out.includes('《三体》'), out);
    assert.equal(okCalls, 1, '重试那次应走正常通道（首次由 throwOnce 抛出）');
    // 2 只读工具重试后仍瞬时失败：文案带「已自动重试一次」，且恰好尝试 2 次
    let attempts = 0;
    toolsState.search = async () => { attempts += 1; throw new Error('HTTP 502 bad gateway'); };
    out = await RealAiTools.execute('search_books', '{"query":"三体"}');
    assert.ok(out.includes('暂时失败') && out.includes('已自动重试一次'), out);
    assert.equal(attempts, 2, '只读瞬时失败应恰好尝试 2 次');
    // 3 写工具瞬时失败：永不自动重试（部分成功可能已落服务端），文案不声称重试过
    toolsState.booklistCreateCalls.length = 0;
    toolsState.createThrowOnce = '连接超时';
    out = await RealAiTools.execute('create_booklist', '{"name":"重试测试"}');
    assert.ok(out.includes('暂时失败') && !out.includes('已自动重试'), out);
    assert.equal(toolsState.booklistCreateCalls.length, 1, '写工具不得自动重试');
    // 4 确定性失败：非瞬时，回「执行失败」+ 修正指引
    toolsState.search = async () => { throw new Error('参数非法'); };
    out = await RealAiTools.execute('search_books', '{"query":"x"}');
    assert.ok(out.includes('执行失败') && out.includes('不要原样重试'), out);
    toolsState.search = null;
    toolsState.booklistCreateCalls.length = 0;
  });

  test('长任务：连续 6 轮 tool_calls 在新上限（12）内正常完成——旧上限 4 会在第 5 轮报错截断', async () => {
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'deepseek-v4.1-flash', 'sk-oc', 0.5);
    const mk = (i) => ({ statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '',
      tool_calls: [{ id: `call_${i}`, type: 'function',
        function: { name: 'search_books', arguments: `{"query":"三体${i}"}` } }] } }] })) });
    deps.state.rcpResponses = [mk(1), mk(2), mk(3), mk(4), mk(5), mk(6),
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '6 本都查完了。' } }] })) }];
    toolsState.search = async (q) => [{ id: 12, title: q, authors: ['刘慈欣'] }];
    let error = '';
    let full = '';
    const toolResults = [];
    RealAiService.chatStream([{ role: 'user', content: '把三体系列全查一遍' }], {
      onDelta: (t) => { full += t; }, onDone: () => {}, onError: (m) => { error = m; },
      onToolResult: (name, l, text) => { toolResults.push(text); },
    }, 256);
    await flush();
    assert.equal(error, '', '6 轮工具调用不得触发上限错误');
    assert.equal(deps.state.requests.length, 7, '6 轮回路 + 1 轮最终回答');
    assert.equal(toolResults.length, 6);
    assert.equal(full, '6 本都查完了。');
  });

}
