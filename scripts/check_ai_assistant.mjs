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
    hasKey: true, temperature: 0.7, vision: false, visionOverride: '', contextLength: 8 },
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
  settings: settingsDefaults(), prefs: new Map(), lastMessages: null,
};
globalThis.__aiCheck = state;
// 设置页保存时会记一个配置版本号，桩掉避免 save() 抛错
globalThis.AppStorage = { setOrCreate: () => {} };
const shim = `
const state = globalThis.__aiCheck;
export const AiService = {
  isReady: () => state.ready,
  chatStream: (messages, handlers) => {
    state.handlers = handlers;
    state.lastMessages = messages;
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
  saveConfig: (providerId, baseUrl, model, apiKey, temperature, visionOverride, contextLength) => {
    state.settings.saved = { providerId, baseUrl, model, apiKey, temperature, visionOverride, contextLength };
    if (apiKey.length > 0) { state.settings.keys.add(providerId); }
    state.settings.config = { providerId, baseUrl, model,
      hasKey: state.settings.keys.has(providerId), temperature,
      visionOverride, contextLength,
      vision: visionOverride === 'on' ? true : visionOverride === 'off' ? false :
        /vl|vision|4o|omni|gemini|claude|llava|qvq/i.test(model) };
  },
  detectVision: (model) => /vl|vision|4o|omni|gemini|claude|llava|qvq/i.test(model),
  contextRounds: (k) => (k <= 4 ? 4 : k <= 8 ? 8 : k <= 32 ? 16 : k <= 128 ? 30 : 50),
  complete: async () => state.settings.completeReply,
};
export const AiBookService = {
  summarize: (...args) => state.summary(...args),
  review: (...args) => state.review(...args),
  suggestMeta: (...args) => state.meta(...args),
  recommend: (...args) => state.recommend(...args),
};
export const ShelfApi = { getShelf: async () => state.shelf };
export const TalebookService = {
  searchAsync: (...args) => state.search(...args),
  prefGet: (key, def) => (state.prefs.has(key) ? state.prefs.get(key) : (def ?? '')),
  prefSet: (key, value) => { state.prefs.set(key, value); },
};
export const pasteboard = {
  MIMETYPE_TEXT_PLAIN: 'text/plain', createData: (_type, text) => text,
  getSystemPasteboard: () => ({ setData: (text) => { state.copied = text; return Promise.resolve(); } }),
};
export const AppRouter = { getParams: () => ({}) };
export const AI_PROVIDERS = [];
export const CONTEXT_LENGTH_OPTIONS = [4, 8, 32, 128, 200];
// 对话页附图管线的 kit 桩：回归只测协议形状与状态流转，真实编码上板验证
export const common = {};
export const fileIo = {
  accessSync: () => true, mkdirSync: () => {}, statSync: () => ({ size: 0 }),
  openSync: () => ({ fd: 0 }), closeSync: () => {}, readSync: () => {}, copyFileSync: () => {},
};
export const photoAccessHelper = {
  PhotoViewPicker: class { async select() { return { photoUris: [] }; } },
  PhotoViewMIMETypes: { IMAGE_TYPE: 'image/*' },
};
export const image = { createImageSource: () => null, createImagePacker: () => null };
export const util = { Base64Helper: class { encodeToStringSync() { return ''; } } };
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
  for (const type of ['ChatCompletionChunk', 'ChatCompletionMessageParam', 'ChatCompletionCreateParamsBase',
    'ChatCompletionContentPart', 'ChatCompletionContentPartText', 'ChatCompletionContentPartImage']) {
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
export const toolsState = {
  search: null, detail: null, notes: [], notesError: '', history: [],
  sonovelEnvelope: null, tasks: [], processed: 0,
  booklistCreateResult: null, booklistAddResult: null, booklistCreateCalls: [], booklistAddCalls: [],
  bookDetailAsync: null, editCalls: [], editResult: null,
  referBooks: null, referSearchCalls: [], applyReferCalls: [], applyReferResult: null,
};
// 仅作类型标注用的名字（strip-types 后仍走值 import），占位防命名导出缺失
export const SoNovelBookPayload = undefined;
export const DownloadTask = undefined;
export const SoNovelSearchItem = undefined;
export const BookListAddResponse = undefined;
export const BookListMutationResponse = undefined;
export const SoNovelService = {
  search: async (_q) => toolsState.sonovelEnvelope ?? { status: 0, body: null, error: '未配置 SoNovel 服务地址' },
};
export const SoNovelMerge = {
  fromRecord: (raw) => ({
    sourceId: Number(raw['sourceId'] ?? 0), sourceName: String(raw['sourceName'] ?? ''),
    url: String(raw['url'] ?? ''), bookName: String(raw['bookName'] ?? ''), author: String(raw['author'] ?? ''),
    category: '', latestChapter: String(raw['latestChapter'] ?? ''), lastUpdateTime: '', status: String(raw['status'] ?? ''),
  }),
};
export const DownloadTaskService = {
  getTasks: () => toolsState.tasks.slice(),
  enqueue: (payload) => {
    const task = { id: 't' + (toolsState.tasks.length + 1), kind: 'sonovel', title: payload.bookName,
      author: payload.author, sourceName: payload.sourceName, status: 'pending', error: '', filePath: '',
      format: (payload.format ?? 'epub').toUpperCase(), bookId: 'sonovel_stub', progress: 0, message: '等待中',
      createdAt: 0, updatedAt: 0, payload };
    toolsState.tasks.push(task);
    return task;
  },
  processQueue: () => { toolsState.processed += 1; },
  statusLabel: (s) => ({ pending: '等待中', downloading: '下载中', completed: '已完成', failed: '失败' }[s] ?? s),
};
export const BookListApi = {
  createBooklist: async (name, description, color, isPublic) => {
    toolsState.booklistCreateCalls.push({ name, description, color, isPublic });
    return toolsState.booklistCreateResult ?? { err: 'ok', booklist: { id: 77 } };
  },
  addBooks: async (id, ids) => {
    toolsState.booklistAddCalls.push({ id, ids });
    return toolsState.booklistAddResult ?? { err: 'ok', added: ids.length, book_count: ids.length };
  },
};
export const TalebookApi = {
  search: async (q) => (toolsState.search ? await toolsState.search(q) : []),
  getBookDetail: async (id) => (toolsState.detail ? await toolsState.detail(id) : null),
  searchRefer: async (id, opts) => {
    toolsState.referSearchCalls.push({ id, opts });
    return { books: toolsState.referBooks ?? [] };
  },
  applyRefer: async (id, entry, onlyMeta, onlyCover) => {
    toolsState.applyReferCalls.push({ id, entry, onlyMeta, onlyCover });
    return toolsState.applyReferResult ?? { err: 'ok' };
  },
};
export const ReferBook = undefined;
export const ReferSearchOpts = undefined;
export const ReferSearchResponse = undefined;
export const TalebookService = {
  getReadingHistory: () => toolsState.history.slice(),
  getBookDetailAsync: async (id) => (toolsState.bookDetailAsync
    ? await toolsState.bookDetailAsync(id) : { status: 404, body: null, error: 'stub: 未设置' }),
  editBookAsync: async (id, payload) => {
    toolsState.editCalls.push({ id, payload });
    return toolsState.editResult ?? { status: 200, body: { err: 'ok' }, error: '' };
  },
};
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
    .replace(`from './TalebookService'`, `from './aiToolsDeps.ts'`)
    .replace(`from './SoNovelService'`, `from './aiToolsDeps.ts'`)
    .replace(`from '../utils/SoNovelMerge'`, `from './aiToolsDeps.ts'`)
    .replace(`from './DownloadTaskService'`, `from './aiToolsDeps.ts'`)
    .replace(`from './BookListApi'`, `from './aiToolsDeps.ts'`);
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
    if (path === '../services/AiTools') {
      const names = clause.split(',').map((part) => part.trim());
      const values = names.filter((name) => name !== 'ToolBookLine');
      return `import { ${values.join(', ')} } from './RealAiTools.ts';\n` +
        "import type { ToolBookLine } from './RealAiTools.ts';\n";
    }
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
      if (['AiService', 'AiBookService', 'ShelfApi', 'TalebookService', 'pasteboard', 'AppRouter', 'AI_PROVIDERS',
        'CONTEXT_LENGTH_OPTIONS', 'fileIo as fs', 'photoAccessHelper', 'image', 'util', 'common'].includes(name)) {
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
  const { AiTools: RealAiTools, parseToolBookLines } = await load('RealAiTools');
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
    page.scrollToEnd = () => {};
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
  test('停止生成会结束当前气泡，保留已收到文本', async () => {
    const page = chat();
    await page.send('问题');
    state.handlers.onDelta('部分回答');
    page.stopStreaming();
    assert.equal(page.thinking, false);
    assert.equal(page.messages.at(-1).streaming, false);
    assert.equal(page.messages.at(-1).content, '部分回答');
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
    assert.ok(t.includes('已加入下载任务') && t.includes('格式 epub'));
    assert.equal(toolsState.tasks.length, 1);
    assert.equal(toolsState.processed, 1);
    const dup = await RealAiTools.execute('add_sonovel_task', '{"book_name":"夜的命名术","url":"http://x/book/1/"}');
    assert.ok(dup.includes('已在下载队列中'));
    assert.equal(toolsState.tasks.length, 1);
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
    assert.ok(Array.isArray(b1.tools) && b1.tools.length === 12 && b1.tools[0].function.name === 'search_books');
    assert.equal(deps.state.requests[0].headers['x-opencode-session'], 'test-uuid-fixed-0001');
    const b2 = JSON.parse(deps.state.requests[1].content);
    const assistant = b2.messages.find((m) => m.role === 'assistant');
    assert.equal(assistant.tool_calls[0].function.name, 'search_books');
    const toolMsg = b2.messages.find((m) => m.role === 'tool');
    assert.equal(toolMsg.tool_call_id, 'call_1');
    assert.ok(toolMsg.content.includes('- 《三体》（刘慈欣） id=12'));
    assert.equal(full, '帮你查到了《三体》，id=12。');
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
    page.beginActivity('search_books', '搜索书架');
    assert.equal(page.liveActivities.length, 1);
    assert.equal(page.liveActivities[0].state, 'doing');
    page.endActivity('search_books', '搜索书架', '书架上找到 2 本：\n- 《三体》（刘慈欣） id=12\n- 《三体全集》（刘慈欣） id=444');
    assert.equal(page.liveActivities[0].state, 'done');
    assert.equal(page.liveActivities[0].books.length, 2);
    assert.equal(page.liveActivities[0].books[0].title, '《三体》');
    assert.equal(page.liveActivities[0].summary, '');
    page.beginActivity('create_booklist', '创建书单');
    page.endActivity('create_booklist', '创建书单', '用户拒绝了该操作');
    const lastAct = page.liveActivities[1];
    assert.equal(lastAct.state, 'rejected');
    assert.equal(lastAct.books.length, 0);
    assert.equal(lastAct.summary, '用户拒绝了该操作');
    // 同名多条 doing：只翻最后一条
    page.beginActivity('search_sonovel', '搜索网络小说书源');
    page.beginActivity('search_sonovel', '搜索网络小说书源');
    page.endActivity('search_sonovel', '搜索网络小说书源', '各书源没有相关小说');
    assert.equal(page.liveActivities[2].state, 'doing');
    assert.equal(page.liveActivities[3].state, 'done');
    assert.equal(page.liveActivities[3].summary, '各书源没有相关小说');
    // 闸门拒绝的工具不走 beginActivity：endActivity 须补记 ✕ 行（上板发现：拒绝不可见）
    page.endActivity('add_sonovel_task', '添加 so-novel 下载任务', '用户拒绝了该操作');
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

  test('update_book_meta：读-合并-写，只覆盖点名字段；空改动与失败路径', async () => {
    toolsState.bookDetailAsync = async () => ({ status: 200, body: { book: {
      title: '三体', authors: ['刘慈欣'], tags: ['科幻'], publisher: 'so-novel', comments: '旧简介',
      isbn: '', series: '', languages: ['zh'], translators: [], series_index: 1, rating: null } } });
    toolsState.editCalls.length = 0;
    const out = await RealAiTools.execute('update_book_meta', '{"book_id":1481,"title":"三体（新版）"}');
    assert.ok(out.includes('已更新'), out);
    assert.ok(out.includes('「三体」→「三体（新版）」'));
    const p = toolsState.editCalls[0].payload;
    assert.equal(p.title, '三体（新版）');
    assert.deepEqual(p.authors, ['刘慈欣'], '未传 authors 保持原值');
    assert.deepEqual(p.tags, ['科幻']);
    assert.equal(p.publisher, 'so-novel');
    assert.equal(p.series_index, 1);
    assert.ok(!('rating' in p), '原值 null 且未传时不发 rating');
    // 逗号分隔多值
    const multi = await RealAiTools.execute('update_book_meta', '{"book_id":1481,"authors":"刘慈欣, 某某","tags":"科幻, 经典"}');
    assert.ok(multi.includes('作者 →「刘慈欣、某某」') && multi.includes('标签 →「科幻、经典」'));
    assert.deepEqual(toolsState.editCalls[1].payload.authors, ['刘慈欣', '某某']);
    // 全空参数：不发请求
    const noop = await RealAiTools.execute('update_book_meta', '{"book_id":1481}');
    assert.ok(noop.includes('没有要修改'), noop);
    assert.equal(toolsState.editCalls.length, 2);
    // 书不存在 / 编辑失败
    toolsState.bookDetailAsync = async () => ({ status: 200, body: { book: {} } });
    assert.ok((await RealAiTools.execute('update_book_meta', '{"book_id":999,"title":"x"}')).includes('没有找到'));
    toolsState.bookDetailAsync = async () => ({ status: 200, body: { book: { title: '三体', authors: [] } } });
    toolsState.editResult = { status: 500, body: null, error: '服务端炸了' };
    assert.ok((await RealAiTools.execute('update_book_meta', '{"book_id":1481,"title":"x"}')).includes('更新失败'));
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
    assert.deepEqual([4, 8, 32, 128, 200].map((k) => RealAiService.contextRounds(k)), [4, 8, 16, 30, 50]);
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
    page.refreshSettings();
    page.encodeImage = async (p) => `data:image/jpeg;base64#${p}`;
    page.pendingImages = ['/f/a.jpg'];
    await page.send('看图');
    assert.deepEqual(page.messages[0].images, ['/f/a.jpg']);
    assert.equal(page.pendingImages.length, 0, '发送即清待发图');
    const sent = state.lastMessages.find((m) => m.role === 'user' && m.content === '看图');
    assert.deepEqual(sent.images, ['data:image/jpeg;base64#/f/a.jpg'], '发送时编码为 data URL');
    // 历史恢复图片路径（不存 data URL，避免 preferences 膨胀）
    const raw = state.prefs.get('ai_chat_history');
    assert.ok(raw.includes('/f/a.jpg') && !raw.includes('base64'), '历史只存沙箱路径');
    const page2 = chat();
    page2.loadHistory();
    assert.deepEqual(page2.messages[0].images, ['/f/a.jpg']);
    // vision 关闭：待发图被丢弃、消息不带图
    state.settings.config.vision = false;
    state.prefs.clear();
    const off = chat();
    off.refreshSettings();
    off.pendingImages = ['/f/b.jpg'];
    await off.send('关闭后发送');
    assert.deepEqual(off.messages[0].images, []);
    // 档位裁剪：4K=4 轮 → system + 最近 8 条气泡
    state.settings.config.contextLength = 4;
    state.prefs.clear();
    const trim = chat();
    trim.refreshSettings();
    for (let i = 0; i < 12; i++) {
      trim.messages.push({ role: i % 2 === 0 ? 'user' : 'assistant', content: `c${i}`,
        streaming: false, error: false, activities: [] });
    }
    const ctx = await trim.buildContext();
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
    assert.ok(page.contextSelectItems().length === 5);
    page.contextLength = 128;
    assert.equal(page.contextSelectIndex(), 3);
  });

  test('对话页历史持久化：finishBubble 落盘、loadHistory 恢复、clearChat 清空', () => {
    state.prefs.clear();
    const page = chat();
    page.messages.push({ role: 'user', content: '你好', streaming: false, error: false, activities: [] });
    page.messages.push({ role: 'assistant', content: '', streaming: true, error: false, activities: [] });
    page.finishBubble('你好，有什么可以帮你？', false);
    const saved = JSON.parse(state.prefs.get('ai_chat_history'));
    assert.equal(saved.length, 2);
    assert.equal(saved[1].content, '你好，有什么可以帮你？');
    const page2 = chat();
    page2.loadHistory();
    assert.equal(page2.messages.length, 2);
    assert.equal(page2.messages[0].content, '你好');
    assert.equal(page2.messages[1].streaming, false);
    // 坏条目丢弃：手写一条缺 role 的记录
    state.prefs.set('ai_chat_history', '[{"content":"x"},{"role":"user","content":"好"}]');
    const page3 = chat();
    page3.loadHistory();
    assert.equal(page3.messages.length, 1);
    page3.clearChat();
    assert.equal(state.prefs.get('ai_chat_history'), '[]');
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
