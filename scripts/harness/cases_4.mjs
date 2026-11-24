// 用例组 4：元数据写工具/vision/历史持久化/多会话/摘要/灵魂记忆（拆分自 check_ai_assistant.mjs，用例体原样）
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { test, state, settingsDefaults, enc, rtB64, deferred, tick, flush } from './base.mjs';
import { dir, read, ETS, ROOT } from './paths.mjs';

export function register(ctx) {
  const { load, deps, RealAiService, RealAiTools, parseToolBookLines, toolsState, mdParseBlocks, mdParseInline, AI_SKILLS, AiAssistantPage, AiBookPanelPage, AiRecommendPage, AiSettingsPage, AiPersonaPage, AiPersona, DEFAULT_SOUL, AiChatStore, personaState, MetaSearchService, NovelMetaService, resetSettings, settingsPage, chat, reappear } = ctx;
  test('update_book_meta：读-合并-写，只覆盖点名字段；空改动与失败路径', async () => {
    toolsState.bookDetailAsync = async () => ({ status: 200, body: { book: {
      title: '三体', authors: ['刘慈欣'], tags: ['科幻'], publisher: 'so-novel', comments: '旧简介',
      category: '科幻时空',
      isbn: '', series: '', languages: ['zh'], translators: [], series_index: 1, rating: null } } });
    toolsState.editCalls.length = 0;
    toolsState.syncMetaCalls.length = 0;
    const out = await RealAiTools.execute('update_book_meta', '{"book_id":1481,"title":"三体（新版）"}');
    assert.ok(out.includes('已更新'), out);
    assert.ok(out.includes('「三体」→「三体（新版）」'));
    // #1638：更新成功后同步本地书架快照（免重新下载整本书）
    assert.deepEqual(toolsState.syncMetaCalls, [{ id: '1481', title: '三体（新版）', author: '刘慈欣', coverUrl: '' }],
      'edit 成功后必须调 syncDownloadMeta 带新标题/第一作者');
    const p = toolsState.editCalls[0].payload;
    assert.equal(p.title, '三体（新版）');
    assert.deepEqual(p.authors, ['刘慈欣'], '未传 authors 保持原值');
    assert.deepEqual(p.tags, ['科幻']);
    assert.equal(p.category, '科幻时空', '未传 category 必须保持原值（edit 接口全量覆盖）');
    assert.equal(p.publisher, 'so-novel');
    assert.equal(p.series_index, 1);
    assert.ok(!('rating' in p), '原值 null 且未传时不发 rating');
    // 逗号分隔多值 + 分类改名（edit 字段名实测为 category 单数字符串；categories 会被服务端忽略）
    const multi = await RealAiTools.execute('update_book_meta',
      '{"book_id":1481,"authors":"刘慈欣, 某某","tags":"科幻, 经典","category":"科学"}');
    assert.ok(multi.includes('作者 →「刘慈欣、某某」') && multi.includes('标签 →「科幻、经典」'));
    assert.ok(multi.includes('分类「科幻时空」→「科学」'), multi);
    assert.equal(toolsState.editCalls[1].payload.category, '科学');
    assert.deepEqual(toolsState.editCalls[1].payload.authors, ['刘慈欣', '某某']);
    // 分类与原值相同：不算改动（防无意义全量写）
    const sameCat = await RealAiTools.execute('update_book_meta', '{"book_id":1481,"category":"科幻时空"}');
    assert.ok(sameCat.includes('没有要修改'), sameCat);
    assert.equal(toolsState.editCalls.length, 2);
    // 全空参数：不发请求
    const noop = await RealAiTools.execute('update_book_meta', '{"book_id":1481}');
    assert.ok(noop.includes('没有要修改'), noop);
    assert.equal(toolsState.editCalls.length, 2);
    // 书不存在 / 编辑失败
    toolsState.bookDetailAsync = async () => ({ status: 200, body: { book: {} } });
    assert.ok((await RealAiTools.execute('update_book_meta', '{"book_id":999,"title":"x"}')).includes('没有找到'));
    toolsState.bookDetailAsync = async () => ({ status: 200, body: { book: { title: '三体', authors: [] } } });
    toolsState.editResult = { status: 500, body: null, error: '服务端炸了' };
    const beforeFail = toolsState.syncMetaCalls.length;
    assert.ok((await RealAiTools.execute('update_book_meta', '{"book_id":1481,"title":"x"}')).includes('更新失败'));
    assert.equal(toolsState.syncMetaCalls.length, beforeFail, 'edit 失败不得同步本地快照');
    toolsState.editResult = null;
  });

  test('update_book_meta 已登记写闸门（漏登记=绕过确认，回归直接钉死）', () => {
    assert.ok(RealAiTools.needsConfirm('update_book_meta'));
    assert.ok(RealAiTools.needsConfirm('set_cover'), 'set_cover 漏登记=绕过确认直接改服务端封面');
  });

  test('search_cover/set_cover：候选缓存跨 execute 复用，onlyCover 应用与守卫', async () => {
    toolsState.referBooks = [
      { source: ' douban'.trim(), title: '三体', authors: ['刘慈欣'], publisher: '重庆出版社',
        cover_url: 'https://img.example/sanct.jpg', provider_key: 'douban', provider_value: '100' },
      { source: 'isbn', title: '三体（无图版）', authors: ['刘慈欣'], cover_url: '' },
    ];
    toolsState.referSearchCalls.length = 0;
    toolsState.applyReferCalls.length = 0;
    const found = await RealAiTools.execute('search_cover', '{"book_id":1481,"isbn":"9787536692930"}');
    assert.ok(found.includes('候选1') && found.includes('https://img.example/sanct.jpg'), found);
    assert.equal(toolsState.referSearchCalls[0].opts.isbn, '9787536692930', 'opts 透传');
    // 成功路径：只改封面（onlyCover=true、onlyMeta=false）
    const done = await RealAiTools.execute('set_cover', '{"book_id":1481,"index":1}');
    assert.ok(done.includes('已将 id=1481 的封面换成候选1'), done);
    assert.equal(toolsState.applyReferCalls[0].onlyCover, true);
    assert.equal(toolsState.applyReferCalls[0].onlyMeta, false);
    assert.equal(toolsState.applyReferCalls[0].entry.provider_value, '100', '候选对象原样传给服务端');
    // 守卫：序号越界 / 候选无封面 / 未先 search 同书
    assert.ok((await RealAiTools.execute('set_cover', '{"book_id":1481,"index":9}')).includes('超出范围'));
    assert.ok((await RealAiTools.execute('set_cover', '{"book_id":1481,"index":2}')).includes('没有封面图片'));
    assert.ok((await RealAiTools.execute('set_cover', '{"book_id":999,"index":1}')).includes('请先对该书调用 search_cover'));
    // 空候选
    toolsState.referBooks = [];
    assert.ok((await RealAiTools.execute('search_cover', '{"book_id":1481}')).includes('没有检索到'));
    // 服务端应用失败
    toolsState.referBooks = [{ source: 'x', cover_url: 'u' }];
    await RealAiTools.execute('search_cover', '{"book_id":1481}');
    toolsState.applyReferResult = { err: 'download_failed', msg: '封面下载失败' };
    assert.ok((await RealAiTools.execute('set_cover', '{"book_id":1481,"index":1}')).includes('封面下载失败'));
    toolsState.applyReferResult = null;
  });

  test('服务：vision 自动检测/手动覆盖与上下文档位持久化、轮数映射', () => {
    deps.state.store.clear();
    RealAiService.saveConfig('openai', 'https://api.openai.com/v1', 'gpt-4o-mini', 'sk-o', 0.7);
    assert.equal(RealAiService.loadConfig().vision, true, 'gpt-4o 自动识别为支持图片');
    RealAiService.saveConfig('moonshot', 'https://api.moonshot.cn/v1', 'moonshot-v1-8k', 'sk-m', 0.7);
    assert.equal(RealAiService.loadConfig().vision, false, 'moonshot-v1-8k 不该被误判');
    RealAiService.saveConfig('moonshot', 'https://api.moonshot.cn/v1', 'moonshot-v1-8k', '', 0.7, 'on', 32);
    assert.equal(RealAiService.loadConfig().vision, true, '手动覆盖优先于自动检测');
    assert.equal(RealAiService.loadConfig().contextLength, 32);
    RealAiService.saveConfig('moonshot', 'https://api.moonshot.cn/v1', 'moonshot-v1-8k', '', 0.7, '', 8);
    assert.equal(RealAiService.loadConfig().visionOverride, '', '恢复自动');
    // 200→50 保持不变；新增 300/500/1000（1M）档 → 80/80/120
    assert.deepEqual([4, 8, 32, 128, 200, 300, 500, 1000].map((k) => RealAiService.contextRounds(k)), [4, 8, 16, 30, 50, 80, 80, 120]);
    assert.deepEqual([4, 32, 200, 300, 500, 1000].map((k) => RealAiService.contextLabel(k)), ['4K', '32K', '200K', '300K', '500K', '1M'], '1000 显示 1M');
    assert.equal(RealAiService.detectVision('qwen2.5-vl-72b'), true);
    assert.equal(RealAiService.detectVision('glm-4-flash'), false);
  });

  test('多模态：带图消息两条通道都序列化为 OpenAI content 数组', async () => {
    const msg = { role: 'user', content: '这是什么', images: ['data:image/jpeg;base64,QUJD'] };
    const rcpJson = (s) => { const b = Buffer.from(s, 'utf8'); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); };
    deps.state.store.clear();
    deps.state.chatCalls.length = 0;
    // 网关通道（rcp 直连）
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'big-pickle', 'sk-oc', 0.5);
    deps.state.rcpResponse = { statusCode: 200, body: rcpJson('{"choices":[{"message":{"content":"ok"}}]}') };
    await new Promise((resolve, reject) => {
      RealAiService.chatStream([msg], { onDelta: () => {}, onDone: resolve, onError: reject });
    });
    const gwBody = JSON.parse(deps.state.lastRequest.content);
    const gwContent = gwBody.messages.find((m) => m.role === 'user').content;
    assert.ok(Array.isArray(gwContent), '网关带图必须发 content 数组');
    assert.equal(gwContent[0].type, 'text');
    assert.equal(gwContent[1].type, 'image_url');
    assert.equal(gwContent[1].image_url.url, 'data:image/jpeg;base64,QUJD');
    deps.state.rcpResponse = null;
    // SDK 通道
    RealAiService.saveConfig('deepseek', 'https://api.deepseek.com/v1', 'deepseek-chat', 'sk-d', 0.5);
    RealAiService.chatStream([msg], { onDelta: () => {}, onDone: () => {}, onError: () => {} });
    const sdkContent = deps.state.chatCalls[0].body.messages.find((m) => m.role === 'user').content;
    assert.ok(Array.isArray(sdkContent) && sdkContent[1].image_url.url === 'data:image/jpeg;base64,QUJD',
      'SDK 通道同样要多模态数组');
    // 无图消息保持纯字符串 content（老服务商兼容性）
    deps.state.chatCalls.length = 0;
    RealAiService.chatStream([{ role: 'user', content: '纯文本' }],
      { onDelta: () => {}, onDone: () => {}, onError: () => {} });
    assert.equal(deps.state.chatCalls[0].body.messages[0].content, '纯文本');
  });

  test('对话页：附图发送、vision 关闭不带图、历史上图路径恢复、档位裁剪轮数', async () => {
    state.prefs.clear();
    state.lastMessages = null;
    state.settings.config.vision = true;
    const page = chat();
    page.onPageShow();
    page.store.encodeImage = async (p) => `data:image/jpeg;base64#${p}`;
    page.pendingImages = ['/f/a.jpg'];
    await page.send('看图');
    assert.deepEqual(page.messages[0].images, ['/f/a.jpg']);
    assert.equal(page.pendingImages.length, 0, '发送即清待发图');
    const sent = state.lastMessages.find((m) => m.role === 'user' && m.content === '看图');
    assert.deepEqual(sent.images, ['data:image/jpeg;base64#/f/a.jpg'], '发送时编码为 data URL');
    // 历史恢复图片路径（不存 data URL，避免 preferences 膨胀）
    const raw = state.prefs.get('ai_chat_history');
    assert.ok(raw.includes('/f/a.jpg') && !raw.includes('base64'), '历史只存沙箱路径');
    const page2 = reappear();
    page2.store.loadHistory();
    assert.deepEqual(page2.messages[0].images, ['/f/a.jpg']);
    // vision 关闭：待发图被丢弃、消息不带图
    state.settings.config.vision = false;
    state.prefs.clear();
    const off = chat();
    off.onPageShow();
    off.pendingImages = ['/f/b.jpg'];
    await off.send('关闭后发送');
    assert.deepEqual(off.messages[0].images, []);
    // 档位裁剪：4K=4 轮 → system + 最近 8 条气泡
    state.settings.config.contextLength = 4;
    state.prefs.clear();
    const trim = chat();
    trim.onPageShow();
    for (let i = 0; i < 12; i++) {
      trim.store.messages.push({ role: i % 2 === 0 ? 'user' : 'assistant', content: `c${i}`,
        streaming: false, error: false, activities: [] });
    }
    const ctx = await trim.store.buildContext();
    assert.equal(ctx.length, 1 + 8, '4K 档只带最近 4 轮（8 条气泡）');
    assert.equal(ctx.at(-1).content, 'c11');
    assert.equal(ctx[1].content, 'c4', '更早的轮次被裁掉');
    state.settings.config.contextLength = 8;
  });

  test('设置页：上下文档位与 vision 覆盖随保存落盘', () => {
    resetSettings();
    const page = settingsPage();
    page.contextLength = 32;
    page.visionOverride = 'on';
    page.baseUrl = 'https://x/v1';
    page.model = 'glm-4v';
    page.apiKey = 'sk-x';
    assert.ok(page.save());
    assert.equal(state.settings.saved.contextLength, 32);
    assert.equal(state.settings.saved.visionOverride, 'on');
    // visionOn 优先级：手动 > 模型名自动检测
    page.visionOverride = '';
    page.model = 'deepseek-chat';
    assert.equal(page.visionOn(), false);
    page.model = 'qwen-vl-max';
    assert.equal(page.visionOn(), true);
    page.visionOverride = 'off';
    assert.equal(page.visionOn(), false, '手动关闭压过自动检测');
    const items = page.contextSelectItems();
    assert.ok(items.length === 8, '档位含 300K/500K/1M 共 8 档');
    assert.equal(items[7].value, '1M', '1000K 档展示为 1M');
    page.contextLength = 128;
    assert.equal(page.contextSelectIndex(), 3);
    page.contextLength = 1000;
    assert.equal(page.contextSelectIndex(), 7);
  });

  test('对话页历史持久化：finishBubble 落盘、loadHistory 恢复、clearChat 清空', () => {
    state.prefs.clear();
    const page = chat();
    page.store.messages.push({ role: 'user', content: '你好', streaming: false, error: false, activities: [] });
    page.store.messages.push({ role: 'assistant', content: '', streaming: true, error: false, activities: [] });
    page.store.finishBubble('你好，有什么可以帮你？', false);
    const saved = JSON.parse(state.prefs.get('ai_chat_history'));
    assert.equal(saved.length, 2);
    assert.equal(saved[1].content, '你好，有什么可以帮你？');
    const page2 = reappear();
    page2.store.loadHistory();
    assert.equal(page2.messages.length, 2);
    assert.equal(page2.messages[0].content, '你好');
    assert.equal(page2.messages[1].streaming, false);
    // 坏条目丢弃：手写一条缺 role 的记录（必须在 chat() 重置落盘之后再覆盖）
    const page3 = chat();
    state.prefs.set('ai_chat_history', '[{"content":"x"},{"role":"user","content":"好"}]');
    page3.store.loadHistory();
    assert.equal(page3.messages.length, 1);
    page3.clearChat();
    assert.equal(state.prefs.get('ai_chat_history'), '[]');
  });

  test('多会话：新建归档、互换切换、删除存档、重新生成原位替换、生成中禁止、旧历史兼容', async () => {
    const page = chat();
    const store = page.store;
    const arch = () => JSON.parse(state.prefs.get('ai_chat_sessions'));
    // 会话 A：一问一答后开新会话，A 应整条归档且标题取首问
    await page.send('第一个问题');
    state.handlers.onDone('回答一');
    assert.equal(store.newSession(), true);
    assert.equal(store.messages.length, 0);
    assert.equal(arch().length, 1);
    assert.equal(arch()[0].title, '第一个问题');
    const aId = arch()[0].id;
    // 会话 B：再一问一答；切换到 A —— B 进档、A 出档（互换语义）
    await page.send('第二个问题');
    state.handlers.onDone('回答二');
    const bId = store.currentId;
    assert.equal(store.switchSession(aId), true);
    assert.deepEqual(store.messages.map((m) => m.content), ['第一个问题', '回答一']);
    assert.equal(store.currentId, aId);
    const swapped = arch();
    assert.equal(swapped.length, 1);
    assert.equal(swapped[0].id, bId);
    assert.equal(swapped[0].title, '第二个问题');
    // 同 id 切换幂等 no-op、未知 id 拒绝；删除存档项生效
    assert.equal(store.switchSession(aId), false);
    assert.equal(store.switchSession('nope'), false);
    store.deleteSession(bId);
    assert.equal(store.sessions.length, 0);
    // 重新生成：抹掉最后 user 及其后全部并重发，原位出新答案（A 会话内 2+2 截 2 补 2）
    await page.send('第三个问题');
    state.handlers.onDone('回答三');
    assert.equal(store.regenerate(), true);
    assert.equal(store.messages.length, 4, '截掉最后 user+assistant 后重发，条数持平');
    assert.equal(store.messages[2].content, '第三个问题');
    assert.equal(store.messages[3].streaming, true);
    await flush(); // regenerate 内 send 是 fire-and-forget，等 handlers 挂上
    state.handlers.onDone('重答三');
    assert.equal(store.messages[3].content, '重答三');
    assert.equal(store.messages.length, 4, '重发不叠加旧答案');
    // 生成中：新建/切换/重生成全部拒绝（不制造双头流）
    await page.send('第四个问题');
    assert.equal(store.newSession(), false);
    assert.equal(store.switchSession(aId), false);
    assert.equal(store.regenerate(), false);
    state.handlers.onDone('回答四');
    // 归档往返闭环：新建归档 A（含重生成后的完整消息），切回 A 内容原样回来
    assert.equal(store.newSession(), true);
    assert.equal(store.sessions.length, 1);
    assert.equal(store.sessions[0].title, '第一个问题');
    const aSnap = store.sessions[0].id;
    assert.equal(store.messages.length, 0);
    assert.equal(store.switchSession(aSnap), true);
    assert.deepEqual(store.messages.map((m) => m.content),
      ['第一个问题', '回答一', '第三个问题', '重答三', '第四个问题', '回答四'], '六条消息完整往返');
    assert.ok(state.prefs.get('ai_chat_history').includes('重答三'), '切换后当前落盘键随会话走');
  });

  test('多会话：空会话不重复新建，标题兜底「新对话」', async () => {
    const page = chat();
    const store = page.store;
    assert.equal(store.newSession(), true);
    assert.equal(store.sessions.length, 0, '空当前会话不归档');
    // 只有 assistant 气泡（理论上不该发生，但归档标题必须兜底）
    store.messages.push({ role: 'assistant', content: '孤儿', streaming: false, error: false, activities: [] });
    assert.equal(store.newSession(), true);
    assert.equal(store.sessions.length, 1);
    assert.equal(store.sessions[0].title, '新对话');
    assert.equal(store.currentTitle(), '新对话');
  });

  test('上下文压缩：截断旧轮超阈值生成摘要→注入上下文→增量更新，重新生成清摘要', async () => {
    const page = chat();
    const store = page.store;
    store.contextK = 4; // 档 4 → 携带 8 条，其余进摘要
    const pushChat = (n) => {
      for (let i = 0; i < n; i++) {
        store.messages.push({ role: i % 2 === 0 ? 'user' : 'assistant',
          content: `聊${i}`, streaming: false, error: false, activities: [] });
      }
    };
    const sumPref = () => JSON.parse(state.prefs.get('ai_chat_summaries'));
    // 阶段一：17 条已完成 + 1 条在途收尾 → 窗口 8 条、截断 10 ≥ 8 → 触发首次摘要
    pushChat(17);
    store.messages.push({ role: 'assistant', content: '', streaming: true, error: false, activities: [] });
    state.settings.completeReply = '摘要V1：已聊书与偏好';
    store.finishBubble('收尾', false);
    await flush();
    let sums = sumPref();
    assert.equal(sums.length, 1);
    assert.equal(sums[0].id, store.currentId);
    assert.equal(sums[0].text, '摘要V1：已聊书与偏好');
    assert.equal(sums[0].count, 10, '18 条筛后 - 窗口 8 = 截断 10');
    // 摘要注入上下文：档 system + 摘要 system 行 + 仅窗口 8 条
    const ctx = await store.buildContext();
    assert.equal(ctx[1].role, 'system');
    assert.ok(ctx[1].content.startsWith('早前对话摘要（已压缩 10 条）'), ctx[1].content.slice(0, 30));
    assert.ok(ctx[1].content.includes('摘要V1'));
    const historyMsgs = ctx.slice(2);
    assert.equal(historyMsgs.length, 8, '窗口仍严格 8 条，摘要不占窗口');
    assert.equal(store.summaryNote(), '已摘要 10 条');
    // 阶段二：只加 2 条+收尾（截断 13-10=3 < 8）→ 不叠火，摘要保持 V1
    pushChat(2);
    store.messages.push({ role: 'assistant', content: '', streaming: true, error: false, activities: [] });
    store.finishBubble('B', false);
    await flush();
    assert.equal(sumPref()[0].count, 10, '未达阈值不更新摘要');
    // 阶段三：加 8 条+收尾（截断 22-10=12 ≥ 8）→ 二次摘要吃「旧摘要+新片段」重写
    pushChat(8);
    store.messages.push({ role: 'assistant', content: '', streaming: true, error: false, activities: [] });
    state.settings.completeReply = '摘要V2';
    store.finishBubble('C', false);
    await flush();
    assert.equal(sumPref()[0].count, 22, '增量推进');
    assert.equal(sumPref()[0].text, '摘要V2');
    const sumUser = state.settings.lastCompleteMessages.find((m) => m.role === 'user');
    assert.ok(sumUser.content.includes('已有摘要：') && sumUser.content.includes('摘要V1')
      && sumUser.content.includes('新增片段'), '增量请求须带旧摘要与新片段');
    state.settings.completeReply = 'ok';
    // 重新生成：坐标系失效，摘要清除且不注入
    assert.equal(store.regenerate(), true);
    assert.equal(sumPref().length, 0);
    assert.equal(store.summaryNote(), '');
    assert.equal((await store.buildContext()).filter((m) => m.role === 'system').length, 1,
      '清摘要后只剩档 system 行');
    await flush();
  });

  test('上下文指示器：只计实际携带的窗口正文，错误与在途气泡排除', () => {
    const page = chat();
    const store = page.store;
    store.contextK = 4; // 窗口 8 条
    for (let i = 0; i < 10; i++) {
      store.messages.push({ role: i % 2 === 0 ? 'user' : 'assistant',
        content: 'x'.repeat(100), streaming: false, error: false, activities: [] });
    }
    assert.equal(store.contextUsageK(), 8, '8 条 x100 字 = 800/100');
    store.messages[0].content = 'x'.repeat(5000); // 窗口外不计
    assert.equal(store.contextUsageK(), 8);
    store.messages.push({ role: 'assistant', content: '生成中', streaming: true, error: false, activities: [] });
    store.messages.push({ role: 'assistant', content: 'x'.repeat(100), streaming: false, error: true, activities: [] });
    assert.equal(store.contextUsageK(), 8, '在途与错误气泡不进指示器');
  });

  test('网关工具回路：触顶自动续段至 5 段后硬上限报错，段尾轮不挂 tools', async () => {
    deps.state.requests.length = 0;
    deps.state.rcpResponses.length = 0;
    RealAiService.saveConfig('opencode', 'https://opencode.ai/zen/go/v1', 'big-pickle', 'sk-oc', 0.5);
    deps.state.rcpResponse = { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '',
      tool_calls: [{ id: 'c1', type: 'function', function: { name: 'reading_history', arguments: '{}' } }] } }] })) };
    let error = '';
    RealAiService.chatStream([{ role: 'user', content: '继续' }], {
      onDelta: () => {}, onDone: () => {}, onError: (m) => { error = m; },
    }, 128);
    await flush();
    // 5 段 ×（12 轮带工具 + 1 轮收尾）= 65 次请求；每段收尾轮不挂 tools
    assert.equal(deps.state.requests.length, 65);
    assert.ok(!('tools' in JSON.parse(deps.state.requests[12].content)), '段一收尾轮不挂工具');
    assert.ok(!('tools' in JSON.parse(deps.state.requests[64].content)), '段五收尾轮不挂工具');
    assert.ok('tools' in JSON.parse(deps.state.requests[13].content), '续段首轮回带工具');
    assert.match(error, /硬上限/);
    deps.state.rcpResponse = null;
  });

  test('灵魂与记忆：SOUL.md 默认兜底，MEMORY.md 追加/去重/序号删除', () => {
    personaState.files.clear();
    assert.equal(AiPersona.loadSoul(), DEFAULT_SOUL);
    AiPersona.saveSoul('你是犀利书评人');
    assert.equal(AiPersona.loadSoul(), '你是犀利书评人');
    assert.equal(AiPersona.resetSoul(), DEFAULT_SOUL);
    assert.match(AiPersona.appendMemory('偏好刘慈欣'), /^已记住/);
    assert.deepEqual(AiPersona.loadMemories(), ['偏好刘慈欣']);
    assert.match(AiPersona.appendMemory('偏好刘慈欣'), /已经存在/);
    assert.match(AiPersona.appendMemory('正在读\n《三体》'), /^已记住/);
    assert.deepEqual(AiPersona.loadMemories(), ['偏好刘慈欣', '正在读 《三体》']);
    assert.match(AiPersona.appendMemory('  '), /为空/);
    assert.match(AiPersona.removeMemory(1), /已忘记：偏好刘慈欣/);
    assert.deepEqual(AiPersona.loadMemories(), ['正在读 《三体》']);
    assert.match(AiPersona.removeMemory(9), /超出范围/);
    const prompt = AiPersona.buildPersonaPrompt();
    assert.ok(prompt.includes('书友'));
    assert.ok(prompt.includes('1. 正在读 《三体》'));
  });

  test('记忆工具：save_memory 直接落盘，forget_memory 登记写闸门', async () => {
    personaState.files.clear();
    assert.equal(RealAiTools.needsConfirm('forget_memory'), true);
    assert.equal(RealAiTools.needsConfirm('save_memory'), true, 'save_memory 写语义须过确认闸门（漏网已修）');
    const r1 = await RealAiTools.execute('save_memory', JSON.stringify({ content: '用户偏好刘慈欣' }));
    assert.match(r1, /已记住/);
    assert.deepEqual(AiPersona.loadMemories(), ['用户偏好刘慈欣']);
    const r2 = await RealAiTools.execute('forget_memory', '{"index":1}');
    assert.match(r2, /已忘记/);
    assert.equal(AiPersona.loadMemories().length, 0);
  });

  test('对话页：system prompt 注入灵魂与记忆', async () => {
    personaState.files.clear();
    AiPersona.saveSoul('你是一位温和的书友');
    AiPersona.appendMemory('用户叫张三');
    const page = chat();
    page.onPageShow();
    page.store.messages = [{ role: 'user', content: '你好', streaming: false, error: false, activities: [] }];
    const ctx = await page.store.buildContext();
    assert.equal(ctx[0].role, 'system');
    assert.ok(ctx[0].content.includes('你是一位温和的书友'));
    assert.ok(ctx[0].content.includes('用户叫张三'));
    personaState.files.clear();
  });

  test('AiChatStore 语音轮次：interim 占位刷新、final 固化、AI 流式、打断收尾', () => {
    const store = AiChatStore.instance();
    store.resetForTest();
    // ASR 中间结果：单条进行中用户气泡整段替换
    store.voiceUser('你', false);
    store.voiceUser('你好', false);
    assert.equal(store.messages.length, 1);
    assert.equal(store.messages[0].content, '你好');
    assert.equal(store.messages[0].streaming, true);
    // speech_started 清占位（空 interim 撤气泡）
    store.voiceUser('', false);
    assert.equal(store.messages.length, 0);
    // final 固化；空 final 丢弃占位（VAD 误触发）
    store.voiceUser('你好', false);
    store.voiceUser('你好。', true);
    assert.equal(store.messages[0].content, '你好。');
    assert.equal(store.messages[0].streaming, false);
    assert.equal(store.messages[0].voice, true);
    store.voiceUser('嗯', false);
    store.voiceUser('', true);
    assert.equal(store.messages.length, 1);
    // AI 字幕流：首个 delta 建气泡，done 以全文固化
    store.voiceAi('今天', false);
    store.voiceAi('晴天', false);
    assert.equal(store.messages.length, 2);
    assert.equal(store.messages[1].content, '今天晴天');
    store.voiceAi('今天是晴天。', true);
    assert.equal(store.messages[1].content, '今天是晴天。');
    assert.equal(store.messages[1].streaming, false);
    assert.equal(store.messages[1].voice, true);
    // done 空全文：保留已累计文本
    store.voiceAi('明', false);
    store.voiceAi('', true);
    assert.equal(store.messages[2].content, '明');
    assert.equal(store.messages[2].streaming, false);
    // 打断后重新开口=新气泡（上一条已 final 固化）；seal 固化尾部流式
    store.voiceAi('后', false);
    assert.equal(store.messages.length, 4);
    store.voiceSealStreaming();
    assert.equal(store.messages[3].content, '后');
    assert.equal(store.messages[3].streaming, false);
    store.resetForTest();
  });

  test('语音轮 voice 标记落盘：loadHistory 白名单重建后仍带 voice，文字轮无标记为 false', () => {
    state.prefs.clear();
    const page = chat();
    page.store.voiceUser('你好。', true);
    page.store.voiceAi('今天晴天。', true);
    const saved = JSON.parse(state.prefs.get('ai_chat_history'));
    assert.equal(saved[0].voice, true);
    assert.equal(saved[1].voice, true);
    const page2 = reappear();
    page2.store.loadHistory();
    assert.equal(page2.messages.length, 2);
    assert.equal(page2.messages[0].voice, true);
    assert.equal(page2.messages[1].voice, true);
    // 旧版存量文字轮记录无 voice 字段：重建后为 false，不误标语音角标
    const page3 = chat();
    state.prefs.set('ai_chat_history', '[{"role":"user","content":"hi"}]');
    page3.store.loadHistory();
    assert.equal(page3.messages[0].voice, false);
  });

}
