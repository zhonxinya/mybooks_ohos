#!/usr/bin/env node
/**
 * AI 助手离线回归（Node >= 22.6）：运行实际 ArkTS 服务和页面逻辑，不连接设备或模型。
 * 页面仅移除 ArkUI 声明式 build 部分、将 @State 擦为普通字段；SDK / 存储 / 剪贴板以本地桩替代。
 * 用法：node scripts/check_ai_assistant.mjs
 */
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, rmSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const ETS = join(ROOT, 'ohos/entry/src/main/ets');
const TMP = process.env.TMPDIR || '/vol3/1000/Public/Share/.tmp';
mkdirSync(TMP, { recursive: true });
const dir = mkdtempSync(join(TMP, 'ai-check-'));
const read = (path) => readFileSync(join(ETS, path), 'utf8');
const settingsDefaults = () => ({
  config: { providerId: 'deepseek', baseUrl: 'https://api.deepseek.com/v1', model: 'deepseek-chat',
    hasKey: true, temperature: 0.7 },
  providers: [
    { id: 'deepseek', name: 'DeepSeek', baseUrl: 'https://api.deepseek.com/v1', model: 'deepseek-chat', vision: false },
    { id: 'opencode', name: 'OpenCode (Go)', baseUrl: 'https://opencode.ai/inference/openai/v1', model: 'big-pickle', vision: false },
  ],
  keys: new Set(['deepseek']), saved: null, models: [], fetchError: '', completeReply: 'ok',
});
const state = {
  ready: true, handlers: null, copied: '', cancel: null,
  shelf: { books: [] }, search: async () => ({ body: { books: [] } }),
  recommend: async () => [], summary: async () => '', review: async () => '', meta: async () => ({}),
  settings: settingsDefaults(),
};
globalThis.__aiCheck = state;
// 设置页保存时会记一个配置版本号，桩掉避免 save() 抛错
globalThis.AppStorage = { setOrCreate: () => {} };
const shim = `
const state = globalThis.__aiCheck;
export const AiService = {
  isReady: () => state.ready,
  chatStream: (_messages, handlers) => {
    state.handlers = handlers;
    return { aborted: false, destroy: () => state.cancel?.(handlers) };
  },
  loadConfig: () => state.settings.config,
  listProviders: () => state.settings.providers.slice(),
  presetOf: (id) => state.settings.providers.find((p) => p.id === id) ??
    { id: 'custom', name: '自定义', baseUrl: '', model: '', vision: false },
  hasKeyFor: (id) => state.settings.keys.has(id),
  addCustomProvider: (name, baseUrl, model) => {
    const preset = { id: 'custom-' + Date.now(), name: name.trim(), baseUrl: baseUrl.trim(),
      model: model.trim(), vision: false };
    state.settings.providers.push(preset);
    return preset;
  },
  removeCustomProvider: (id) => {
    state.settings.providers = state.settings.providers.filter((p) => p.id !== id);
    state.settings.keys.delete(id);
  },
  fetchModels: async () => {
    if (state.settings.fetchError.length > 0) { throw new Error(state.settings.fetchError); }
    return state.settings.models.slice();
  },
  saveConfig: (providerId, baseUrl, model, apiKey, temperature) => {
    state.settings.saved = { providerId, baseUrl, model, apiKey, temperature };
    if (apiKey.length > 0) { state.settings.keys.add(providerId); }
    state.settings.config = { providerId, baseUrl, model,
      hasKey: state.settings.keys.has(providerId), temperature };
  },
  complete: async () => state.settings.completeReply,
};
export const AiBookService = {
  summarize: (...args) => state.summary(...args),
  review: (...args) => state.review(...args),
  suggestMeta: (...args) => state.meta(...args),
  recommend: (...args) => state.recommend(...args),
};
export const ShelfApi = { getShelf: async () => state.shelf };
export const TalebookService = { searchAsync: (...args) => state.search(...args) };
export const pasteboard = {
  MIMETYPE_TEXT_PLAIN: 'text/plain', createData: (_type, text) => text,
  getSystemPasteboard: () => ({ setData: (text) => { state.copied = text; return Promise.resolve(); } }),
};
export const AppRouter = { getParams: () => ({}) };
export const AI_PROVIDERS = [];
`;
writeFileSync(join(dir, 'shim.ts'), shim);

// 真实 AiService 的运行时依赖桩：内存存储 + 可编程的 SDK 假响应
writeFileSync(join(dir, 'aiServiceDeps.ts'), `
// Buffer.from(x).buffer 带池化填充，必须 slice 出精确字节（模拟 rcp 的紧凑 ArrayBuffer）
const enc = (s) => { const b = Buffer.from(s, 'utf8'); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); };
export const state = { store: new Map(), models: [], rcpResponse: null, rcpResponses: [], rcpError: null, lastRequest: null, requests: [], chatCalls: [] };
export const util = {
  TextDecoder: { create: () => ({ decodeToString: (u8) => Buffer.from(u8).toString('utf8') }) },
  generateRandomUUID: () => 'test-uuid-fixed-0001',
};
export class OpenAI {
  chat = { completions: { create: (body, options) => {
    state.chatCalls.push({ body, options });
    const ok = { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: 'ok' } }] })) };
    const resp = state.chatResponse ?? ok;
    return { session: { cancel: () => { state.chatCancelled = true; } }, response: Promise.resolve(resp) };
  } } };
  constructor(options) { state.lastOptions = options; }
}
export const rcp = {
  Request: class Request {
    constructor(url, method, headers, content) { this.url = url; this.method = method; this.headers = headers; this.content = content; }
  },
  createSession: () => ({
    fetch: async (request) => {
      state.lastRequest = request;
      state.requests.push(request);
      if (state.rcpError) { throw state.rcpError; }
      const queued = state.rcpResponses.length > 0 ? state.rcpResponses.shift() : null;
      return queued ?? state.rcpResponse ?? { statusCode: 200, body: enc(JSON.stringify({ data: state.models })) };
    },
    close: () => {},
  }),
};
export const TalebookService = {
  prefGet: (key, fallback = '') => state.store.has('p:' + key) ? state.store.get('p:' + key) : fallback,
  prefSet: (key, value) => { state.store.set('p:' + key, value); },
  secureGet: (key) => state.store.has('s:' + key) ? state.store.get('s:' + key) : '',
  secureSet: (key, value) => { if (value === '') { state.store.delete('s:' + key); } else { state.store.set('s:' + key, value); } },
};
`);

/** 把真实 AiService 落进临时目录：SDK / rcp 类型转 import type，运行时依赖换成桩。 */
function stageAiService() {
  let source = read('services/AiService.ets');
  for (const type of ['ChatCompletionChunk', 'ChatCompletionMessageParam', 'ChatCompletionCreateParamsBase']) {
    source = source.replace(`import { ${type} }`, `import type { ${type} }`);
  }
  source = source
    .replace(`import { AiTools, AiToolDefinition } from './AiTools';`,
      `import { AiTools } from './RealAiTools.ts';\nimport type { AiToolDefinition } from './RealAiTools.ts';`)
    .replace(`from '@iuroc/openai'`, `from './aiServiceDeps.ts'`)
    .replace(`from '@kit.ArkTS'`, `from './aiServiceDeps.ts'`)
    .replace(`from '@kit.RemoteCommunicationKit'`, `from './aiServiceDeps.ts'`)
    .replace(`from './TalebookService'`, `from './aiServiceDeps.ts'`);
  writeFileSync(join(dir, 'RealAiService.ts'), source);
}

// AiTools 的运行时依赖桩：书架/详情/笔记/历史全部可编程，不落真实服务
writeFileSync(join(dir, 'aiToolsDeps.ts'), `
export const toolsState = { search: null, detail: null, notes: [], notesError: '', history: [] };
export const TalebookApi = {
  search: async (q) => (toolsState.search ? await toolsState.search(q) : []),
  getBookDetail: async (id) => (toolsState.detail ? await toolsState.detail(id) : null),
};
export const TalebookService = { getReadingHistory: () => toolsState.history.slice() };
export const AnnotationApi = {
  listBookAnnotations: async (_id, _scope) => {
    if (toolsState.notesError.length > 0) { throw new Error(toolsState.notesError); }
    return toolsState.notes.slice();
  },
};
export const ANNOTATION_SCOPE_MINE = 'mine';
export function annotationTypeLabel(type) { return type === 'highlight' ? '高亮' : type === 'note' ? '笔记' : type; }
`);

function stageAiTools() {
  let source = read('services/AiTools.ets');
  source = source
    .replace(`from './TalebookApi'`, `from './aiToolsDeps.ts'`)
    .replace(`from './AnnotationApi'`, `from './aiToolsDeps.ts'`)
    .replace(`from './TalebookService'`, `from './aiToolsDeps.ts'`);
  writeFileSync(join(dir, 'RealAiTools.ts'), source);
}

function stagePure(name, path, typeNames) {
  let source = read(path).replace(/from '\.\.\/services\/BookModels'/g, "from './BookModels.ts'");
  for (const type of typeNames) {
    source = source.replace(`import { ${type} }`, `import type { ${type} }`);
  }
  writeFileSync(join(dir, `${name}.ts`), source);
}

function stagePage(name) {
  let source = read(`pages/${name}.ets`);
  source = source.substring(0, source.indexOf('\n  build() {'));
  const shims = new Set();
  source = source.replace(/^import \{([^}]+)\} from '([^']+)';\n/gm, (_all, clause, path) => {
    if (path === '../services/AiSkills') {
      const names = clause.split(',').map((part) => part.trim());
      const values = names.filter((name) => name !== 'AiSkill');
      return `import { ${values.join(', ')} } from './AiSkills.ts';\nimport type { AiSkill } from './AiSkills.ts';\n`;
    }
    if (path === '../utils/LibraryMatch' || path === '../services/BookModels') {
      const names = clause.split(',').map((part) => part.trim()).filter((name) => name !== 'BookItem');
      return `import { ${names.join(', ')} } from './${path.split('/').at(-1)}.ts';\n`;
    }
    for (const name of clause.split(',').map((part) => part.trim())) {
      if (['AiService', 'AiBookService', 'ShelfApi', 'TalebookService', 'pasteboard', 'AppRouter', 'AI_PROVIDERS'].includes(name)) {
        shims.add(name);
      }
    }
    return '';
  });
  source = source.replace(/^@(?:Entry|Component)\n/gm, '')
    .replace(`struct ${name}`, `export class ${name}`)
    .replace(/@State /g, '')
    .replace(/private scroller: Scroller = new Scroller\(\);/, 'private scroller: Object = {};')
    .replace(/\n  private scrollToEnd\(\): void \{[\s\S]*?\n  \}/, '\n  private scrollToEnd(): void {}');
  writeFileSync(join(dir, `${name}.ts`), `import { ${[...shims].join(', ')} } from './shim.ts';\n${source}\n}\n`);
}

const cases = [];
const test = (name, run) => cases.push({ name, run });
const deferred = () => {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
};
const tick = () => new Promise((resolve) => setImmediate(resolve));
// 工具回路是多轮 await，微任务队列跑干净需要连续 tick
const flush = async () => { for (let i = 0; i < 24; i++) await tick(); };
const enc = (s) => { const b = Buffer.from(s, 'utf8'); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); };

try {
  stagePure('BookModels', 'services/BookModels.ets', []);
  stagePure('LibraryMatch', 'utils/LibraryMatch.ets', ['BookItem']);
  stagePure('MdParse', 'services/MdParse.ets', []);
  stagePure('AiSkills', 'services/AiSkills.ets', []);
  for (const name of ['AiAssistantPage', 'AiBookPanelPage', 'AiRecommendPage', 'AiSettingsPage']) {
    stagePage(name);
  }
  stageAiService();
  stageAiTools();
  const load = async (name) => import(pathToFileURL(join(dir, `${name}.ts`)).href);
  const { AiAssistantPage } = await load('AiAssistantPage');
  const { AiBookPanelPage } = await load('AiBookPanelPage');
  const { AiRecommendPage } = await load('AiRecommendPage');
  const { AiSettingsPage } = await load('AiSettingsPage');
  const deps = await load('aiServiceDeps');
  const { AiService: RealAiService } = await load('RealAiService');
  const { AiTools: RealAiTools } = await load('RealAiTools');
  const { toolsState } = await load('aiToolsDeps');
  const { mdParseBlocks, mdParseInline } = await load('MdParse');
  const { AI_SKILLS } = await load('AiSkills');
  const resetSettings = () => { state.settings = settingsDefaults(); };
  const settingsPage = () => {
    const page = new AiSettingsPage();
    page.toast = () => {};
    page.aboutToAppear();
    return page;
  };
  const chat = () => {
    const page = new AiAssistantPage();
    page.toast = () => {};
    state.ready = true;
    state.cancel = null;
    return page;
  };

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
  test('停止生成会结束当前气泡，保留已收到文本', () => {
    const page = chat();
    page.send('问题');
    state.handlers.onDelta('部分回答');
    page.stopStreaming();
    assert.equal(page.thinking, false);
    assert.equal(page.messages.at(-1).streaming, false);
    assert.equal(page.messages.at(-1).content, '部分回答');
  });
  test('清空后迟到的流式回调不会污染新对话', () => {
    const page = chat();
    page.send('旧问题');
    const old = state.handlers;
    page.clearChat();
    old.onDone('旧回答');
    assert.deepEqual(page.messages, []);
    page.send('新问题');
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
    assert.equal(page.modelIndex, -1);
    page.model = page.modelOptions[1];
    state.settings.models = [];
    state.settings.fetchError = 'API Key 无效或已过期（HTTP 401）';
    await page.fetchModelList();
    assert.equal(page.testOk, false);
    assert.match(page.testResult, /401/);
    assert.equal(page.fetchingModels, false);
  });

  test('AiTools：只读工具返回精简文本（搜索/详情/笔记/历史/未知工具/失败包装）', async () => {
    toolsState.search = async (q) => (q === '三体' ? [{ id: 12, title: '三体', authors: ['刘慈欣', '某某'] }] : []);
    assert.ok((await RealAiTools.execute('search_books', '{"query":"三体"}')).includes('id=12 《三体》（刘慈欣、某某）'));
    assert.ok((await RealAiTools.execute('search_books', '{"query":"鲁滨逊"}')).includes('没有找到'));
    assert.ok((await RealAiTools.execute('search_books', '')).includes('query'));
    toolsState.detail = async (id) => (id === 12
      ? { id: 12, title: '三体', authors: ['刘慈欣'], rating: 9.2, tags: ['科幻'],
        files: [{ format: 'epub', size: 1 }, { format: 'mobi', size: 2 }],
        comments: 'x'.repeat(600), coverUrl: '', downloadUrl: '' }
      : null);
    const detailText = await RealAiTools.execute('book_detail', '{"book_id":12}');
    assert.ok(detailText.includes('《三体》（刘慈欣）') && detailText.includes('epub、mobi') && detailText.includes('…'));
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
    RealAiService.chatStream([{ role: 'user', content: '书架上有三体吗' }], {
      onDelta: (t) => { full += t; }, onDone: () => {}, onError: (m) => { error = m; },
      onTool: (l) => { toolLabels.push(l); },
    }, 256);
    await flush();
    assert.equal(error, '');
    assert.deepEqual(toolLabels, ['搜索书架']);
    assert.equal(deps.state.requests.length, 2);
    const b1 = JSON.parse(deps.state.requests[0].content);
    assert.equal(b1.stream, false);
    assert.ok(Array.isArray(b1.tools) && b1.tools.length === 4 && b1.tools[0].function.name === 'search_books');
    assert.equal(deps.state.requests[0].headers['x-opencode-session'], 'test-uuid-fixed-0001');
    const b2 = JSON.parse(deps.state.requests[1].content);
    const assistant = b2.messages.find((m) => m.role === 'assistant');
    assert.equal(assistant.tool_calls[0].function.name, 'search_books');
    const toolMsg = b2.messages.find((m) => m.role === 'tool');
    assert.equal(toolMsg.tool_call_id, 'call_1');
    assert.ok(toolMsg.content.includes('id=12 《三体》'));
    assert.equal(full, '帮你查到了《三体》，id=12。');
  });

  test('技能：四个内置技能均带工具指引，点击填入输入框', () => {
    assert.equal(AI_SKILLS.length, 4);
    const prompts = AI_SKILLS.map((s) => s.prompt);
    for (const tool of ['search_books', 'book_detail', 'book_notes', 'reading_history']) {
      assert.ok(prompts.some((p) => p.includes(tool)), `缺工具 ${tool}`);
    }
    for (const s of AI_SKILLS) {
      assert.ok(s.label.length > 0 && s.hint.length > 0, s.label);
      assert.ok(s.prompt.includes('《'), s.label);
    }
    const page = chat();
    page.applySkill(AI_SKILLS[0]);
    assert.equal(page.input, AI_SKILLS[0].prompt);
  });

  test('网关工具回路：超过轮数上限报错收场，最后一轮不挂 tools', async () => {
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
    assert.equal(deps.state.requests.length, 5);
    assert.ok(!('tools' in JSON.parse(deps.state.requests[4].content)), '最后一轮不挂工具');
    assert.match(error, /上限/);
    deps.state.rcpResponse = null;
  });

  let failures = 0;
  for (const { name, run } of cases) {
    try {
      await run();
      console.log(`PASS ${name}`);
    } catch (error) {
      failures++;
      console.error(`FAIL ${name}\n${error.stack}`);
    }
  }
  console.log(`\n${cases.length - failures}/${cases.length} 通过`);
  process.exitCode = failures > 0 ? 1 : 0;
} finally {
  delete globalThis.__aiCheck;
  rmSync(dir, { recursive: true, force: true });
}
