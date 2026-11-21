// 用例组 9：对话 UI 精修 P2/P3 批（Token 用量/思考耗时/按住说话；自 cases_1 拆出以过 800 行门禁）
import assert from 'node:assert/strict';
import { test, state } from './base.mjs';

export function register(ctx) {
  const { load, AiChatStore, chat } = ctx;

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

}
