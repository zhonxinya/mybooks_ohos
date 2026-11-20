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
  settings: settingsDefaults(), prefs: new Map(), lastMessages: null, lastToast: '',
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
  loadPermission: () => state.settings.permission ?? 'confirm',
  savePermission: (mode) => { state.settings.permission = mode; },
  complete: async () => state.settings.completeReply,
};
// bindMenu 当前项勾选用的符号修饰器桩（页面测试不渲染 UI，仅保证符号可解析）
export const SymbolGlyphModifier = class {
  constructor(_symbol) {}
  fontColor(_colors) { return this; }
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
export const promptAction = { showToast: (o) => { state.lastToast = o.message; } };
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
export const state = { store: new Map(), models: [], rcpResponse: null, rcpResponses: [], rcpError: null, lastRequest: null, requests: [], chatCalls: [], sourceJson: null, written: [] };
export const util = {
  // 透传 encoding（gbk/gb2312 走 Node 内置 TextDecoder），utf-8 用法不受影响
  TextDecoder: { create: (encoding) => ({ decodeToString: (u8) => new TextDecoder(encoding ?? 'utf-8').decode(u8) }) },
  // Reader3Native http 桥用：utf-8 文本→字节→base64（与 ArkTS 语义一致）
  TextEncoder: class { encodeInto(s) { return new Uint8Array(Buffer.from(s ?? '', 'utf8')); } },
  Base64Helper: class { encodeToStringSync(u8) { return Buffer.from(u8).toString('base64'); } },
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
// Reader3Native 书源库文件桩：state.sourceJson 非空即视为沙箱 files 目录存在 bookmeta_sources.json
export const fs = {
  accessSync: (p) => state.sourceJson !== null && p.endsWith('bookmeta_sources.json'),
  statSync: () => ({ size: state.sourceJson === null ? 0 : Buffer.byteLength(state.sourceJson, 'utf8') }),
  openSync: () => ({ fd: 7 }),
  readSync: (fd, buf) => { const b = Buffer.from(state.sourceJson ?? '', 'utf8'); b.copy(Buffer.from(buf)); return b.length; },
  writeSync: (fd, text) => { state.written.push(text); state.sourceJson = text; },
  closeSync: () => {},
  OpenMode: { READ_ONLY: 0, READ_WRITE: 2, CREATE: 64, TRUNC: 512 },
};
export { fs as fileIo };
export const hilog = { info: () => {}, warn: () => {}, error: () => {} };
export const TalebookService = {
  prefGet: (key, fallback = '') => state.store.has('p:' + key) ? state.store.get('p:' + key) : fallback,
  prefSet: (key, value) => { state.store.set('p:' + key, value); },
  secureGet: (key) => state.store.has('s:' + key) ? state.store.get('s:' + key) : '',
  secureSet: (key, value) => { if (value === '') { state.store.delete('s:' + key); } else { state.store.set('s:' + key, value); } },
};
`);

// libentry.so 桩：reader3 四函数经 globalThis 可编程（真实 Reader3Native 入检用）
writeFileSync(join(dir, 'reader3Entry.ts'), `
export default {
  reader3Available: () => globalThis.__r3Available ?? false,
  reader3SetHttpCallback: (cb) => { globalThis.__r3Cb = cb; return true; },
  reader3Deliver: (resp) => { globalThis.__r3Delivered = resp; return true; },
  reader3BookInfo: (srcJson, url) => {
    globalThis.__r3SourceArg = srcJson;
    globalThis.__r3UrlArg = url;
    return Promise.resolve(globalThis.__r3Payload ?? '{"status":"error","message":"stub"}');
  },
};
`);

// NovelMetaService 分派测试用的 Reader3Native 替身（meta 结果可编程；默认 null=不接管）
writeFileSync(join(dir, 'reader3Stub.ts'), `
export class Reader3Meta {}
export class Reader3Native {
  static result = null;
  static lastUrl = '';
  static async meta(url) { Reader3Native.lastUrl = url; return Reader3Native.result; }
}
`);

/** 把真实 AiService 落进临时目录：SDK / rcp 类型转 import type，运行时依赖换成桩。 */
function stageAiService() {
  let source = read('services/AiService.ets');
  for (const type of ['ChatCompletionChunk', 'ChatCompletionMessageParam', 'ChatCompletionCreateParamsBase',
    'ChatCompletionContentPart', 'ChatCompletionContentPartText', 'ChatCompletionContentPartImage']) {
    source = source.replace(`import { ${type} }`, `import type { ${type} }`);
  }
  source = source
    .replace(`import { AiTools, AiPermissionMode, AiToolDefinition } from './AiTools';`,
      `import { AiTools } from './RealAiTools.ts';\nimport type { AiPermissionMode, AiToolDefinition } from './RealAiTools.ts';`)
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
    category: String(raw['category'] ?? ''), latestChapter: String(raw['latestChapter'] ?? ''),
    lastUpdateTime: String(raw['lastUpdateTime'] ?? ''), status: String(raw['status'] ?? ''),
    wordCount: String(raw['wordCount'] ?? ''),
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

// AiPersona 的运行时依赖桩：内存文件系统 + dataDir，灵魂/记忆不落盘
writeFileSync(join(dir, 'personaDeps.ts'), `
export const personaState = { files: new Map(), dir: '/stub-files' };
export const fs = {
  OpenMode: { READ_ONLY: 1, READ_WRITE: 2, CREATE: 4, TRUNC: 8 },
  accessSync: (p) => personaState.files.has(p),
  mkdirSync: () => {},
  readTextSync: (p) => {
    if (!personaState.files.has(p)) { throw new Error('ENOENT ' + p); }
    return personaState.files.get(p);
  },
  openSync: (p) => ({ fd: p }),
  writeSync: (fd, text) => { personaState.files.set(fd, text); },
  closeSync: () => {},
};
// AiPersona 的 import 子句是 fileIo as fs，两个名字都指向同一桩对象
export const fileIo = fs;
export const TalebookService = { dataDir: () => personaState.dir };
`);

/** AiChatStore 真实入检：单例状态机是回归重点，AiService/TalebookService 走 shim 桩。 */
function stageChatStore() {
  let source = read('services/AiChatStore.ets');
  source = source
    .replace(`import { AiTools, AiPermissionMode, parseToolBookLines, ToolBookLine } from './AiTools';`,
      `import { AiTools, parseToolBookLines } from './RealAiTools.ts';\nimport type { AiPermissionMode, ToolBookLine } from './RealAiTools.ts';`)
    .replace(`import { AiService, AiConfig, AiMessage, AiStreamHandlers, AiAbortHandle } from './AiService';`,
      `import { AiService } from './shim.ts';`)
    .replace(`from './AiPersona'`, `from './RealAiPersona.ts'`)
    .replace(`from './TalebookService'`, `from './shim.ts'`)
    .replace(`from '@kit.CoreFileKit'`, `from './shim.ts'`)
    .replace(`from '@kit.ImageKit'`, `from './shim.ts'`)
    .replace(`from '@kit.ArkTS'`, `from './shim.ts'`);
  writeFileSync(join(dir, 'RealAiChatStore.ts'), source);
}

function stageAiPersona() {
  let source = read('services/AiPersona.ets');
  source = source
    .replace(`from '@kit.CoreFileKit'`, `from './personaDeps.ts'`)
    .replace(`from './TalebookService'`, `from './personaDeps.ts'`);
  writeFileSync(join(dir, 'RealAiPersona.ts'), source);
}

/** MetaSearchService 真实入检：rcp/util 复用 aiServiceDeps 桩（state.rcpResponse 可编程）。 */
function stageMetaSearch() {
  let source = read('services/MetaSearchService.ets');
  source = source
    .replace(`from '@kit.RemoteCommunicationKit'`, `from './aiServiceDeps.ts'`)
    .replace(`from '@kit.ArkTS'`, `from './aiServiceDeps.ts'`);
  writeFileSync(join(dir, 'RealMetaSearch.ts'), source);
}

/** NovelMetaService 真实入检：同样复用 rcp 桩；引擎分派点用 Reader3Native 替身。 */
function stageNovelMeta() {
  let source = read('services/NovelMetaService.ets');
  source = source
    .replace(`from '@kit.RemoteCommunicationKit'`, `from './aiServiceDeps.ts'`)
    .replace(`from '@kit.ArkTS'`, `from './aiServiceDeps.ts'`)
    .replace(`from './Reader3Native'`, `from './reader3Stub.ts'`);
  writeFileSync(join(dir, 'RealNovelMeta.ts'), source);
}

/** Reader3Native 真实入检：libentry/getContext 换桩，rcp/util 复用 aiServiceDeps。 */
function stageReader3() {
  let source = read('services/Reader3Native.ets');
  source = source
    .replace(`import entry from 'libentry.so';`, `import entry from './reader3Entry.ts';`)
    .replace(`from '@kit.RemoteCommunicationKit'`, `from './aiServiceDeps.ts'`)
    .replace(`from '@kit.ArkTS'`, `from './aiServiceDeps.ts'`)
    .replace(`from '@kit.CoreFileKit'`, `from './aiServiceDeps.ts'`)
    .replace(`from '@kit.PerformanceAnalysisKit'`, `from './aiServiceDeps.ts'`)
    .replace(`getContext().filesDir`, `(globalThis.__r3Ctx).filesDir`);
  writeFileSync(join(dir, 'RealReader3.ts'), source);
}

function stageAiTools() {
  let source = read('services/AiTools.ets');
  source = source
    // 类型注解用的 DoubanDetail/DoubanHit 被 strip-types 擦除，只需值导入 MetaSearchService
    .replace(`import { DoubanDetail, DoubanHit, MetaSearchService } from './MetaSearchService';`,
      `import { MetaSearchService } from './RealMetaSearch.ts';`)
    .replace(`import { NovelMeta, NovelMetaService } from './NovelMetaService';`,
      `import { NovelMetaService } from './RealNovelMeta.ts';`)
    .replace(`from './AiPersona'`, `from './RealAiPersona.ts'`)
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
      const values = names.filter((name) => name !== 'ToolBookLine' && name !== 'AiPermissionMode');
      return `import { ${values.join(', ')} } from './RealAiTools.ts';\n` +
        "import type { ToolBookLine } from './RealAiTools.ts';\n";
    }
    if (path === '../services/AiPersona') {
      return `import { AiPersona } from './RealAiPersona.ts';\n`;
    }
    if (path === '../services/AiChatStore') {
      return "import { AiChatStore } from './RealAiChatStore.ts';\n" +
        "import type { ChatActivity, ChatBubble } from './RealAiChatStore.ts';\n";
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
        'CONTEXT_LENGTH_OPTIONS', 'fileIo as fs', 'photoAccessHelper', 'image', 'util', 'common',
        'promptAction', 'SymbolGlyphModifier'].includes(name)) {
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
  for (const name of ['AiAssistantPage', 'AiBookPanelPage', 'AiRecommendPage', 'AiSettingsPage',
    'AiPersonaPage']) {
    stagePage(name);
  }
  stageAiService();
  stageAiPersona();
  stageChatStore();
  stageMetaSearch();
  stageNovelMeta();
  stageReader3();
  stageAiTools();
  const load = async (name) => import(pathToFileURL(join(dir, `${name}.ts`)).href);
  const { AiAssistantPage } = await load('AiAssistantPage');
  const { AiBookPanelPage } = await load('AiBookPanelPage');
  const { AiRecommendPage } = await load('AiRecommendPage');
  const { AiSettingsPage } = await load('AiSettingsPage');
  const { AiPersonaPage } = await load('AiPersonaPage');
  const { AiPersona, DEFAULT_SOUL } = await load('RealAiPersona');
  const { AiChatStore } = await load('RealAiChatStore');
  const { personaState } = await load('personaDeps');
  const { MetaSearchService } = await load('RealMetaSearch');
  const { NovelMetaService } = await load('RealNovelMeta');
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
    AiChatStore.instance().resetForTest();
    const page = new AiAssistantPage();
    page.toast = () => {};
    page.scrollToEnd = () => {};
    state.ready = true;
    state.cancel = null;
    page.aboutToAppear();
    return page;
  };
  // 重进页面（不重置 store，模拟真实路由返回）：手动装配即可
  const reappear = () => {
    const page = new AiAssistantPage();
    page.toast = () => {};
    page.scrollToEnd = () => {};
    page.aboutToAppear();
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
    assert.ok(Array.isArray(b1.tools) && b1.tools.length === 16 && b1.tools[0].function.name === 'search_books');
    assert.equal(deps.state.requests[0].headers['x-opencode-session'], 'test-uuid-fixed-0001');
    const b2 = JSON.parse(deps.state.requests[1].content);
    const assistant = b2.messages.find((m) => m.role === 'assistant');
    assert.equal(assistant.tool_calls[0].function.name, 'search_books');
    const toolMsg = b2.messages.find((m) => m.role === 'tool');
    assert.equal(toolMsg.tool_call_id, 'call_1');
    assert.ok(toolMsg.content.includes('- 《三体》（刘慈欣） id=12'));
    assert.equal(full, '帮你查到了《三体》，id=12。');
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
    const WRITE = ['create_booklist', 'add_books_to_booklist', 'add_sonovel_task',
      'update_book_meta', 'set_cover', 'forget_memory'];
    assert.equal(RealAiTools.definitions().length, 16);
    assert.equal(RealAiTools.definitions('confirm').length, 16);
    assert.equal(RealAiTools.definitions('auto').length, 16);
    const ro = RealAiTools.definitions('readonly');
    assert.equal(ro.length, 10);
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
    assert.equal(b1.tools.length, 10);
    assert.ok(!b1.tools.some((d) => d.function.name === 'create_booklist'));
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
    assert.equal(b1.tools.length, 16, 'auto 模式写工具须在 tools 里');
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

  test('系统提示词：不复述工具枚举、含中文思考约束，权限补注三档都用准确档位名', async () => {
    chat();
    const store = AiChatStore.instance();
    const sys = (await store.buildContext())[0].content;
    assert.ok(!sys.includes('（书籍详情，需 id）'), '旧版逐工具枚举未删净（与 tools payload 重复）');
    assert.ok(!sys.includes('写操作工具：create_booklist'), '写工具清单枚举未删净');
    assert.ok(sys.includes('回答与思考过程一律使用中文'), '缺中文约束');
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
    state.settings.permission = 'confirm';
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
    assert.ok(page.contextSelectItems().length === 5);
    page.contextLength = 128;
    assert.equal(page.contextSelectIndex(), 3);
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
    assert.equal(deps.state.requests.length, 13);
    assert.ok(!('tools' in JSON.parse(deps.state.requests[12].content)), '最后一轮不挂工具');
    assert.match(error, /上限/);
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
    assert.equal(RealAiTools.needsConfirm('save_memory'), false);
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

  const DOUBAN_PAGE = '<html><head></head><body><h1><span property="v:itemreviewed">三体</span></h1>' +
    '<strong class="ll rating_num" property="v:average"> 8.9 </strong>' +
    '<div id="info"><ul class="authors"><li>作者: <a>刘慈欣</a></li></ul>' +
    '<span>出版社:</span> 重庆出版社<br/><span>出版时间:</span> 2008-1<br/>' +
    '<span>ISBN:</span> 9787536692930<br/><span>页数:</span> 302<br/>' +
    '<span>装帧:</span> 平装<br/><span>定价:</span> 23.00<br/></div>' +
    '<div class="intro">文革期间军方探寻外星文明的红岸工程启动，叶文洁按下发射键改变了人类命运，' +
    '而三体世界的舰队已经在路上，人类的末日进入倒计时。</div></body></html>';

  test('MetaSearch：豆瓣 suggest 过滤非图书条目，subject 详情页解析评分/出版社/ISBN', async () => {
    deps.state.rcpResponse = { statusCode: 200, body: enc(JSON.stringify([
      { title: '三体', url: 'https://book.douban.com/subject/2567698/', pic: 'https://img/x.jpg',
        author_name: '刘慈欣', year: '2008', type: 'b', id: '2567698' },
      { title: '三体', type: 't', id: '999', author_name: '', year: '', pic: '', url: '' },
    ])) };
    const hits = await MetaSearchService.suggest('三体');
    assert.equal(hits.length, 1);
    assert.equal(hits[0].subjectId, '2567698');
    assert.equal(hits[0].author, '刘慈欣');
    deps.state.rcpResponse = { statusCode: 200, body: enc(DOUBAN_PAGE) };
    const d = await MetaSearchService.detail('2567698');
    assert.ok(d.ok);
    assert.equal(d.title, '三体');
    assert.equal(d.rating, '8.9');
    assert.equal(d.publisher, '重庆出版社');
    assert.equal(d.isbn, '9787536692930');
    assert.equal(d.pages, '302');
    assert.equal(d.author, '刘慈欣');
    assert.ok(d.intro.includes('红岸工程'));
    // 非数字 id 与 HTTP 错误都走 ok=false 分支
    const bad = await MetaSearchService.detail('abc');
    assert.ok(!bad.ok);
    deps.state.rcpResponse = { statusCode: 403, body: enc('') };
    const blocked = await MetaSearchService.detail('2567698');
    assert.ok(!blocked.ok && blocked.error.includes('403'));
    deps.state.rcpResponse = null;
  });

  // 17K 详情页样本节选（2026-11-19 www.17k.com/book/1018082.html 实测锚点）
  const K17_PAGE = `<html><head>
<title>武逆焚天_疯橘子_武逆焚天最新章节_在线阅读-17K小说网</title>
<meta property="og:image" content="https://cdn.static.17k.com/book/189x272/82/80/1018082.jpg-189x272?v=0" />
<meta property="og:description" content="  神奇的大陆，因神兽而支离破碎！！&lt;br&gt;  各方势力追寻多年的重宝出世……">
<script>window.$__BOOK = { type: 'book', bookId: 1018082, bookName: '武逆焚天',
  authorName: '疯橘子', authorId: 37093114, chapterId: 0, chapterName: '', vip: 1 }</script>
</head><body>
<div class="Header"><a href="/all/book/2_0_0_0_2_0_0_0_1.html">完本小说</a></div>
<div class="Info Sign"><h1><a href="/list/1018082.html">武逆焚天</a></h1>
<div class="label"><a title="连载小说" href="#"><span class="green">连载小说</span></a></div>
<table><tr><th>授权级别：</th><td><span class="red">签约作品</span></td>
<th>作品类别：</th><td><a href="/all/book/2_21_8______1.html">东方玄幻</a></td></tr></table>
</body></html>`;
  test('NovelMeta：17K 详情页解析全字段（导航「完本小说」不得误判状态）', () => {
    const m = NovelMetaService.parse17k(K17_PAGE);
    assert.ok(m.ok);
    assert.equal(m.title, '武逆焚天');
    assert.equal(m.author, '疯橘子');
    assert.equal(m.status, '连载中'); // 顶部导航也有「完本小说」，必须限定 .label 块
    assert.equal(m.category, '东方玄幻');
    assert.ok(m.cover.startsWith('https://cdn.static.17k.com/'));
    assert.ok(m.intro.includes('神奇的大陆') && m.intro.includes('重宝出世') && !m.intro.includes('&lt;'));
  });

  test('NovelMeta：通用 og 规则、相对封面补全、WAF 挑战页识别、非 http url', async () => {
    const gen = `<html><head><meta property="og:image" content="/files/article/image/2/2402/2402s.jpg">
<meta property="og:description" content="蒸汽与机械的浪潮中，谁能触及非凡？"></head>
<body><h1>诡秘之主</h1></body></html>`;
    deps.state.rcpResponse = { statusCode: 200, body: enc(gen) };
    const m = await NovelMetaService.fetchDetail('http://www.mcxs.info/book/2402/');
    assert.ok(m.ok && m.rule === '通用og');
    assert.equal(m.cover, 'http://www.mcxs.info/files/article/image/2/2402/2402s.jpg');
    assert.ok(m.intro.includes('蒸汽与机械'));
    // WAF 挑战页 → 明确报「换书源」，不能报解析失败
    deps.state.rcpResponse = { statusCode: 200, body: enc("<script>var arg1='AB';reload('acw_sc__v2')</script>") };
    const waf = await NovelMetaService.fetchDetail('https://search.17k.com/search.xhtml?c.q=x');
    assert.ok(!waf.ok && waf.error.includes('WAF'));
    deps.state.rcpResponse = null;
    const bad = await NovelMetaService.fetchDetail('javascript:alert(1)');
    assert.ok(!bad.ok && bad.error.includes('http'));
  });

  // og:novel 结构化样本（2026-11-20 实测 m.kujiang.com/book/91737、ciweimao.com/book/100506842）
  const KUJIANG_PAGE = `<html><head>
<meta property="og:title" content="灯下黑"/>
<meta property="og:description" content="       贺录对祝卿安说：“离开我，我倒要看看谁敢跟你同甘。”<br />
  单韩苼对祝卿安说：“别怕，你的窟窿我想填也不是一天两天。”">
<meta property="og:image" content="https://bs.kjcdn.com/i/pubwmrs/6o/8w/o2u1o.jpg"/>
<meta property="og:novel:author" content="鱼不语"/>
<meta property="og:novel:book_name" content="灯下黑"/>
<meta property="og:novel:status" content="完结"/>
<meta property="og:novel:latest_chapter_name" content="第三十六章  不再灯下黑"/>
</head><body></body></html>`;
  const CIWEIMAO_PAGE = `<html><head>
<meta property="og:title" content="型月模拟，雅典娜的头号走狗最新章节(幻想成为正义的伙伴),型月模拟，雅典娜的头号走狗无弹窗全文阅读-欢乐书客"/>
<meta property="og:description" content="穿越型月13年，间桐悠只想做两件事：
1，保护好弟弟妹妹。
2，弄死间桐脏砚。">
<meta property="og:image" content="https://e1.kuangxiangit.com/uploads/allimg/c261016/16-10-26135300-10127.jpg"/>
<meta property="og:novel:category" content="科幻无限"/>
<meta property="og:novel:author" content="幻想成为正义的伙伴"/>
<meta property="og:novel:book_name" content="型月模拟，雅典娜的头号走狗"/>
</head><body></body></html>`;
  test('NovelMeta：og:novel 结构化规则——书名去站名尾巴、状态归一、缺字段不崩', () => {
    const k = NovelMetaService.parseGeneric(KUJIANG_PAGE);
    assert.ok(k.ok && k.rule === 'og:novel');
    assert.equal(k.title, '灯下黑');
    assert.equal(k.author, '鱼不语');
    assert.equal(k.status, '已完本'); // 「完结」归一
    assert.ok(k.cover.startsWith('https://bs.kjcdn.com/'));
    assert.ok(k.intro.includes('贺录对祝卿安') && k.intro.includes('单韩苼')); // <br/> 转换行不断句
    const c = NovelMetaService.parseGeneric(CIWEIMAO_PAGE);
    assert.ok(c.ok && c.rule === 'og:novel');
    assert.equal(c.title, '型月模拟，雅典娜的头号走狗'); // og:title 带「无弹窗全文阅读-欢乐书客」尾巴，弃用
    assert.equal(c.category, '科幻无限');
    assert.equal(c.status, ''); // 该站无 status 字段，不得瞎猜
  });

  // 纵横 fixture：2026-11-20 www.zongheng.com/book/1435440.html 实测（Nuxt SSR，name= 写法，
  // 且 og:description 值被站点模板二次包壳成 content=&quot;…&quot;）
  const ZONGHENG_PAGE = `<html><head>
<meta data-n-head="ssr" name="og:title" content="齐天">
<meta data-n-head="ssr" name="og:description" content="content=&quot;纵横小说网提供作者(日落红尘)的经典小说《齐天》，《齐天》最新章节全文阅读服务，本站更新及时，无弹窗广告，欢迎光临(m.zongheng.com)观看小说：【大长篇爆火玄幻】【最强帝族崛起】齐麟家祖祠内，供奉着十尊古老的先祖灵牌。&quot;">
<meta data-n-head="ssr" property="og:image" content="//static.zongheng.com/upload/cover/43/10/431084171eca1f70f6c7809392ad72a51793265377769.jpeg">
<meta data-n-head="ssr" name="og:novel:book_name" content="齐天">
<meta data-n-head="ssr" name="og:novel:category" content="玄幻奇幻">
<meta data-n-head="ssr" name="og:novel:author" content="日落红尘">
<meta data-n-head="ssr" name="og:novel:status" content="连载中">
</head><body></body></html>`;
  test('NovelMeta：纵横 name= 写法命中 og:novel + 站点脏 description 脱壳', () => {
    const m = NovelMetaService.parseGeneric(ZONGHENG_PAGE);
    assert.ok(m.ok && m.rule === 'og:novel');
    assert.equal(m.title, '齐天');
    assert.equal(m.author, '日落红尘');
    assert.equal(m.category, '玄幻奇幻');
    assert.equal(m.status, '连载中');
    assert.ok(m.intro.startsWith('纵横小说网提供'), 'content=&quot; 包壳必须剥掉');
    assert.ok(m.intro.includes('齐麟家祖祠内') && !m.intro.endsWith('&quot;') && !m.intro.endsWith('"'));
  });

  // 起点移动版 fixture：2026-11-20 m.qidian.com/book/1050742867 实测（www 桌面端是 202 probe.js 风控）
  const QIDIAN_M_PAGE = `<html><head>
<meta property="og:title" content="美利坚：超凡入圣" />
<meta property="og:image" content="//bookcover.yuewen.com/qdbimg/349573/1050742867/180" />
<meta property="og:description" content="谢邀：人在白头鹰，标准炎黄纯血贵族。本想当好人，奈何超凡复苏，且自身灵根残破。故只能在这混乱渐起的动荡时代，杀出一条长生之路！【多女主】【超凡复苏】【半无敌】" />
<meta property="og:novel:category" content="异术超能" />
<meta property="og:novel:author" content="白魔星" />
<meta property="og:novel:book_name" content="美利坚：超凡入圣" />
<meta property="og:novel:status" content="连载" />
</head><body></body></html>`;
  test('起点：www 风控 url 重写到 m.qidian 后 og:novel 命中，协议相对封面补全', async () => {
    assert.equal(NovelMetaService.rewriteUrl('https://www.qidian.com/book/1050742867'),
      'https://m.qidian.com/book/1050742867/');
    assert.equal(NovelMetaService.rewriteUrl('https://book.qidian.com/info/1050742867/'),
      'https://m.qidian.com/book/1050742867/');
    assert.equal(NovelMetaService.rewriteUrl('https://www.ujxsw.org/book/90293/'),
      'http://www.ujxsw.org/book/90293/'); // ujxsw https 端口不通（curl 000），手贴 https 降到 http
    assert.equal(NovelMetaService.rewriteUrl('https://www.wtzw.com/book/224292.html'),
      'https://www.wtzw.com/book/224292.html');
    deps.state.rcpResponse = { statusCode: 200, body: enc(QIDIAN_M_PAGE) };
    const m = await NovelMetaService.fetchDetail('https://www.qidian.com/book/1050742867/');
    assert.ok(m.ok && m.rule === 'og:novel');
    assert.equal(m.title, '美利坚：超凡入圣');
    assert.equal(m.author, '白魔星');
    assert.equal(m.category, '异术超能');
    assert.equal(m.status, '连载中'); // 「连载」归一
    assert.equal(m.cover, 'https://bookcover.yuewen.com/qdbimg/349573/1050742867/180');
    assert.ok(m.intro.includes('超凡复苏'));
    deps.state.rcpResponse = null;
  });

  // 梧桐中文 fixture：2026-11-20 www.wtzw.com/book/224292.html 实测节选（无 og，类名锚点）
  const WTZW_PAGE = `<html><head><title>我的少年班全本小说-卿殇小说-无广告阅读(免费下载)-七猫中文网</title></head><body>
<h1>免费小说就在梧桐中文网（七猫中文网）</h1>
<li class="li_tit"><h1><a href="/chapter/224292-1176288.html" target="_blank">我的少年班</a><i class="tag">已完结</i></h1></li>
<div class="w_name"><span class="sName">卿殇</span></div>
<div class="w_pic"><img src="//cdn.qimao.com/bookimg/zww/upload/readerCover/75/224292.jpg?time=1638349502"></div>
<div class="pWorkInformation">空军青少年航空学校四期学员自述励志航空~追求卓越！这是属于我们的时代，属于我们的现在。</div>
</body></html>`;
  test('NovelMeta：梧桐中文类名锚点——书名取 li_tit 内 a（顶层 h1 是站名）、状态归一、类别缺不猜', () => {
    const m = NovelMetaService.parseWtzw(WTZW_PAGE);
    assert.ok(m.ok && m.rule === '梧桐中文');
    assert.equal(m.title, '我的少年班'); // 顶层 <h1> 是「免费小说就在梧桐中文网」，不得误取
    assert.equal(m.author, '卿殇');
    assert.equal(m.status, '已完本'); // 「已完结」归一
    assert.equal(m.category, '');
    assert.ok(m.intro.includes('空军青少年航空学校'));
    assert.ok(m.cover.startsWith('//cdn.qimao.com/')); // 协议相对，fetchDetail 里统一补全
  });

  // 万相书城 fixture：2026-11-20 www.wxscs.com/book/10212 实测 meta 节选。
  // 该站 Apache 按 UA 放行（桌面 403/移动 200），回归同时盯住 UA 特判不回退
  const WXSCS_PAGE = `<html><head>
<meta property="og:description" content="江湖上流传着一个传说：要自杀的人最好遇上杜云青。这虽是个传说，但却没有人怀疑，每一个曾经在江湖上混过了几年的人，都可以为你举出一大堆的例子。塞北五娘、江南七怪、南天一鹤、楼霞双仙等等，这些跺脚四海颤，名"/>
<meta property="og:image" content="/uploads/cover/pic10212.jpg"/>
<meta property="og:novel:category" content="玄幻奇幻"/>
<meta property="og:novel:author" content="司马紫烟"/>
<meta property="og:novel:book_name" content="新月剑"/>
<meta property="og:novel:status" content="完结"/>
</head><body></body></html>`;
  test('NovelMeta：wxscs 桌面 UA 403 教训——UA 按站点选择，移动 UA+相对封面补全', async () => {
    deps.state.rcpResponse = { statusCode: 200, body: enc(WXSCS_PAGE) };
    const m = await NovelMetaService.fetchDetail('https://www.wxscs.com/book/10212/');
    assert.ok(m.ok && m.rule === 'og:novel');
    assert.equal(m.title, '新月剑');
    assert.equal(m.status, '已完本'); // 「完结」归一
    assert.equal(m.cover, 'https://www.wxscs.com/uploads/cover/pic10212.jpg');
    assert.ok(String(deps.state.lastRequest.headers['User-Agent']).includes('Mobile'),
      'wxscs 必须用移动 UA（桌面 UA 实测 403）');
    deps.state.rcpResponse = { statusCode: 200, body: enc(QIDIAN_M_PAGE) };
    await NovelMetaService.fetchDetail('https://www.qidian.com/book/1050742867/');
    assert.ok(String(deps.state.lastRequest.headers['User-Agent']).includes('Windows NT'),
      '其他站保持桌面 UA');
    deps.state.rcpResponse = null;
  });

  // 晋江模板串：仿 2026-11-20 onebook.php?novelid=10035712 实测结构（schema.org itemprop），
  // 专防两坑：畸形 `_src` 属性（真实页 img 有 _src="…" src="…" 双属性）、简介 div 超 2000 字符
  test('NovelMeta.parseJjwxc：itemprop 锚点——防 _src 误取、长简介、状态归一、类别原样', () => {
    const long = 'A'.repeat(2500);
    const page = `<html><body>
<h1 itemprop="name"><span itemprop="articleSection">测试书名</span> </h1>
<h2>作者：<a href="#"><span style="font-size:12px" itemprop="author">测试作者</span></a></h2>
<li><span>文章类型：</span> <span style="color:#000;float:none" itemprop="genre"> 原创-言情-近代现代-爱情 </span> </li>
<li><span>文章进度：</span><span style="color:#000;float:none" itemprop="updataStatus">已完结</span></li>
<div class="smallreadbody"> <img class="noveldefaultimage" itemprop="image"_src="https://BAD.example/wrong.jpg" src="https://GOOD.example/right.jpg" width="200"><div id="novelintro" itemprop="description">文案开头${long}文案结尾</div>
</body></html>`;
    const m = NovelMetaService.parseJjwxc(page);
    assert.ok(m.ok && m.rule === '晋江');
    assert.equal(m.title, '测试书名');
    assert.equal(m.author, '测试作者');
    assert.equal(m.category, '原创-言情-近代现代-爱情'); // 四段串原样保留
    assert.equal(m.status, '已完本'); // 「已完结」归一
    assert.ok(m.cover.includes('right.jpg') && !m.cover.includes('wrong.jpg'),
      '必须取真实 src 而非畸形 _src');
    assert.ok(m.intro.startsWith('文案开头') && m.intro.length === 501,
      `>2000 字符简介也必须命中并截断，实际 ${m.intro.length}`);
  });

  // 晋江 gb18030 端到端：2026-11-20 onebook.php?novelid=10035712 真页关键区块节选
  test('NovelMeta：晋江 gb18030 页 fetchDetail 端到端——编码嗅探+itemprop 全字段', async () => {
    const JJWXC_B64 = 'PGh0bWw+PGhlYWQ+PG1ldGEgaHR0cC1lcXVpdj0iQ29udGVudC1UeXBlIiBjb250ZW50PSJ0ZXh0L2h0bWw7IGNoYXJzZXQ9Z2IxODAzMCI+PHRpdGxlPng8L3RpdGxlPjwvaGVhZD48Ym9keT4gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxzcGFuIGNsYXNzPSJiaWd0ZXh0Ij48aDEgaXRlbXByb3A9Im5hbWUiPjxzcGFuIGl0ZW1wcm9wPSJhcnRpY2xlU2VjdGlvbiI+uqO1usfzyfqjusn6u+7N5rzS1tbM77bau/U8L3NwYW4+IDwvaDE+PC9zcGFuPg0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8aW5wdXQgdHlwZT0iaGlkZGVuIg0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgdmFsdWU9IiVCQSVBMyVCNSVCQSVDNyVGMyVDOSVGQSVBMyVCQSVDOSVGQSVCQiVFRSVDRCVFNiVCQyVEMiVENiVENiVDQyVFRiVCNiVEQSVCQiVGNSINCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGlkPSJwdWJfcnNfbm92ZWxuYW1lIi8+DQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPGgyPg0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg1/fV36O6PGEgaHJlZj0iaHR0cDovL3d3dy5qand4Yy5uZXQvb25lYXV0aG9yLnBocD9hdXRob3JpZD03MDM5MTY3Ij48c3Bhbg0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgc3R5bGU9ImZvbnQtc2l6ZToxMnB4IiBpdGVtcHJvcD0iYXV0aG9yIj7ns9LEPC9zcGFuPjwvYT4NCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxzcGFuIHN0eWxlPSJjb2xvcjojMDAwO2Zsb2F0Om5vbmUiIGl0ZW1wcm9wPSJnZW5yZSI+DQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgINSttLQttL+wri27w8/rzrTAtC2+58fpICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvc3Bhbj4NCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvbGk+DQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBzdHlsZT0iY29sb3I6IzAwMDtmbG9hdDpub25lIiBpdGVtcHJvcD0idXBkYXRhU3RhdHVzIj7BrNTYPC9zcGFuPg0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9saT4NCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxsaT4NCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPGltZyBjbGFzcz0ibm92ZWxkZWZhdWx0aW1hZ2UiIGl0ZW1wcm9wPSJpbWFnZSJfc3JjPSJodHRwczovL2k5LXN0YXRpYy5qand4Yy5uZXQvbm92ZWxpbWFnZS5waHA/bm92ZWxpZD0xMDAzNTcxMiZjb3ZlcmlkPTE1NiZ2ZXI9ZmYzNjkwMWVhM2Y0ZmQyNmNlMTJiY2Q4MjZlMjVmNGUiIHNyYz0iaHR0cHM6Ly9pOS1zdGF0aWMuamp3eGMubmV0L25vdmVsaW1hZ2UucGhwP25vdmVsaWQ9MTAwMzU3MTImY292ZXJpZD0xNTYmdmVyPWZmMzY5MDFlYTNmNGZkMjZjZTEyYmNkODI2ZTI1ZjRlIiB3aWR0aD0iMjAwIiBoZWlnaHQ9IjI4MCIgYWxpZ249bGVmdCByZWZlcnJlcnBvbGljeT0ibm8tcmVmZXJyZXIiIHN0eWxlPSJtYXJnaW46MCAxMHB4IDAgMDsiIG9uZXJyb3I9ImxvYWREZWZhdWx0Tm92ZWxDb3Zlcih0aGlzKSI+PGRpdiBpZD0ibm92ZWxpbnRybyIgaXRlbXByb3A9ImRlc2NyaXB0aW9uIjxkaXYgaWQ9Im5vdmVsaW50cm8iIGl0ZW1wcm9wPSJkZXNjcmlwdGlvbiI+xM/B976w0ru+9dDRwLSjrL7NtcPWqtfUvLqxu9K7uPa90KG2uqO1usfzyfqht7XE0LC28dPOz7fPtc2zsPPGscHLoaO007TLus3AttDHy7XU2bz7o6y687Dryfq2vLnSv7/U2tK71/m54s26zbq1xNChtbrJz8HLoaM8YnI+yrLDtL3Qv6q+1tK71/m1uqOszu/Xysirv7+4zrChoaM8YnI+w+a21MTxsrvArcq6tcS7xLW6o6zBvcrWv9W/1bXExM/B976wttq79cant7jBy6GjPGJyPrK70NCjrLHY0Ou1w7jOxvDAtKOho6GjoTxicj7L+7jPuqOjrNbWtdijrNH4yrfAs8S3o6zSu9PQv9W+zb+qtKzMvcv318rUtLW6o6y6zdSt16HD8df2vbvS16GjPGJyPtPayse9pb2ltcSjrNCh0KG1xLW60+zSu9TZwKm9qKOsu8S12LHkwbzM76GjxMGzob+qxvDAtMHLo6y357O1vajG8MC0wcujrMTPwfe+sLK7ueLE3NfUuPjX1Nfjo6y7ucTctqjG2sil1K3XocPxtcS1usnPsNrMr8L0xam4sbL6xrejrNeswLS1xMeu16rK1r7NwvLBy7j8tuDKtdPDtcTBtr3wtcC+36GjPGJyPtfUtq+9vcuuxvejv7rDtqvO96OswvLBy6OhPGJyPjMwzOy1xNDCytbG2rn9yKWjrNPOz7fVub+qwcvL/M/VtvG1xNXmw+bEv6GjzOzU1r3T9eC2+NbBo6y8q7quoaK4387CoaKxqdPqoaLTwNK5oa2hrcO/0ru49jMwzOy2vM6qzea80rT4wLTRz77+tcS/vNHpoaM8YnI+xM/B976w08DUtsrH17yxuNfus+TX47XExMfSu8X6oaM8YnI+sam359GpwLTB2aOsxM/B976w1/jU2s7Cxa+1xMWpyeHA76Osv77XxcWvyNrI2rXEsdrCr6Os0rux38P+18W0883Iyc/Lr7PJ0rvNxbXEw6jSu7HfusjXxcjIv8m/yaGjPGJyPrCmo6zQ0rijoaM8YnI+087Pt7K7ysfDu9PQ1b22t9Sqy9ijrLWryfq77s3mvNKyu7CuuOPEx9CptPK08smxybG1xKGjPGJyPrWxyLvBy6OsyOe5+9PQxMS49rK7s6TR27XEtai40sC0tPLIxcv71ta12KOsxM/B976w0rK74brBsru/zcb4tcShraGtsNHL+9bWtb212MDvoaM8YnI+PGJyPtbY0qrLtcP3o7qxvs7Eyei2qMHpuNDAtNfUtuCyv8TBs6HO79Pv087Pt6OsyOfT0MDXzayjrMTH0ru2qMrHztLU2tbCvrSjoTxicj6hqqGqoaqhqjxicj7Qob7ns6Gjujxicj5Bo7q458PHo6zE49XitqvO97K7tO2woaOsxMTC8rXEo788YnI+QqO6srvWqrW6oaM8YnI+QaO6ztLOysTjyse008TEtvnC8rXEo6GjoTxicj5Co7rO0su1wcujobK71qq1urCho6GjoTxicj48YnI+PGJyPqGqoaqhqqGqoaqhqs/Ct73Kx9SkytWjoTxicj6htsrAvee52r78tNPQodPEwem/qsq8obc8YnI+PGJyPqGhoaHV4srH0ru49sjL0+u7w8HpubLJ+rXEysC956GjPGJyPqGhoaHCvdXV0MfS8s6q0ru33c38tPi72LzStcS+7dfTt7W72NGn0KOjrMi01OK1vcHL0rDJ+rvDwem1xM+uu/ejrLK70KHQxLX0vfjBy7vDwem1xMrAveehsLa0v9+hsaOssu6147b5xdzLwNTawO/D5qGjPGJyPqGhoaHQ0rrDzOzO3r74yMvWrsK3o6zU2rG70rDJ+rvDwem89LX0srHX08ewo6zCvdXV0Me6zcbVzai8trvDwenQodPEwenP4NP2wcuhozxicj6hoaGh1NrG1c2ovLa7w8Hp1tDSssrH1+7I9dK7tbW1xNCh08TB6b7Ny+O9+LuvwcvSsrrcyPXQoaOs0/nB6cqmw8e1q7ey09C149e3x/O2vLK7u+HRodTxxvXUvNCh08TB6aOstavU2s6ju/rWrtbQo6zWu9PQy/y21MK91dXQx8nss/bBy8rWoaM8YnI+oaGhocK91dXQx7rBsrvTzNSltdjO1cHLyc/IpaGjPGJyPqGhoaGhsNfuyPXQobXE08TB6c+1u8PB6aGx09bU9dH5o7/CvdXV0MfX1NDFxr696NfUvLq1xNW9yvXWuLvTus3Ep7nt0bXBt6Os1NnF5LrP0KHTxMHps6zHv7XE1b22t9Li1r6jrMv7w8fSu7aoxNzU2se/1d/I59TGtcS7w8HpttTVvdbQybGz9tK7zPXRqsK3wLShozxicj6hoaGhxL+x6srHyKu5+rnavvyjoTxicj48YnI+oaGhoaGqoaqhqqGqPGJyPqGhICAgsb7OxMHpuNDAtNfUoba+q8Hpsaa/ycPOobehoqG2yv3C67GmsbSht7XI0fiz6LbU1b3Tzs+3o6zI59PQwNfNrKOst8ezo9X9s6OjoTxicj6hoaGhsb7OxMTayN2w/MCoo7rG9dS8u8PB6aGiu8PB6dG1wbehosn9vLahora0v9/Mvc/VoaK7w8HpttTVvaOotaXIyy/Nxczlo6k8YnI+oaGhobG+zsTW973Ho7rH7rfowcu1q7bUu8PB6brctPO3vbXE1b22t7/xQmtpbme6zcv7sK62usOotcTE6snPttTP8zxicj4gICAgICAgysC959fux7/Lq7TytO61tSArIM31sru8+831tcS1pbTyvqK10Dxicj6hoaGhyf28tsH3oaK087OkxqqhosTauqzDyLPoo6zH67TzvNLWp7PW0KHTxMHpo6HWp7PWzrTAtLXEysC957navvzQocK9o6E8YnI+PGJyPqGqoaqhqqGqoaqhqjxicj48YnI+oba087q9uqOjurTT0KG3q7Ssv6rKvKG3PGJyPtC7wdbSu9ax0tTAtLa8vvW1w6Os19S8ur7NysfG1crA0uLS5cnPtcS1ucO5tbChozxicj6438vZuavCt8nPMTGztcGsu7fXt86yo6zGq8arvs3Iw8v7uM/Jz8HLo6zGq8arvs3Kx8v7w8e1xLO1v6jU2rWx1tCjrMarxqu+zcrHy/vU2sTHwO/Kp8ilwcvSu8fQoaM8YnI+s7W79sjDy/u1xNK7zPXNyLfby+nQ1LnH1dujrLu509DSu7j5wN+5x7TMxsbBy7fOoaOyu732v+DBt7bgxOq1xPXMyK21wLuv1/fF3dOwo6y7ucjDy/u007TLuOax8NX9s6PIy7XEyfq77qOss8nBy8rAyMvR29bQtcT1y9fTo6yx8Mu1xdzBy6OstuDX38G9sr22vNKqtPO0rcb4oaM8YnI+1NnDu9PQyMuxyMv7uPy1ucO5wcuhozxicj48YnI+tvjSsr7NysfV4tH5tcTL+6Os1Nmxu8CtyOvIq8Pxx/PJ+tPOz7e686Osu/G1w8HLsbvPtc2zx9W2qLXETHVja3kgRG9nzOy4s6GjPGJyPsuto7/O0sLwo788YnI+vLTKub71tcPPtc2ztcTF0LbPxsS+37fttMzS4s62o6zQu8HW0rLDu9PQyM66zrDst6iho8vXu7DLtbjssrLFobK7uf20883Io6zE3LDRyKvAttDHtrzArTwvZGl2PjwvYm9keT48L2h0bWw+';
    const raw = Buffer.from(JJWXC_B64, 'base64');
    deps.state.rcpResponse = { statusCode: 200,
      body: raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) };
    const m = await NovelMetaService.fetchDetail('http://www.jjwxc.net/onebook.php?novelid=10035712');
    assert.ok(m.ok && m.rule === '晋江');
    assert.equal(m.title, '海岛求生：生活玩家种田囤货');
    assert.equal(m.author, '绯夷');
    assert.equal(m.category, '原创-纯爱-幻想未来-剧情');
    assert.equal(m.status, '连载中');
    assert.ok(m.intro.startsWith('南流景一觉醒来') && !m.intro.includes('\uFFFD'),
      'gb18030 解码简介须可读不乱码');
    assert.ok(m.cover.startsWith('https://i9-static.jjwxc.net/novelimage.php'));
    deps.state.rcpResponse = null;
  });

  // 悠久书城 fixture：2026-11-20 www.ujxsw.org/book/90293 实测节选（无 og，正文锚点）
  const UJXSW_PAGE = `<html><head><meta name="description" content="剑仙最新章节由网友提供，是作者兵围城下创作的小说，悠久小说网免费提供剑仙在线全文阅读,剑仙TXT电子书全集免费下载。" /></head><body><h1>悠久小说网</h1><div id="bookinfo"><div class="bookleft"><div id="bookimg">                    <a href="/read/90293/" target="_blank" class="img">                    <img alt="剑仙" title="剑仙" src="http://www.ujxsw.org/files/article/image/90/90293/90293s.jpg" width="152" height="195" />                    <div class="no</div></div><div class="bookright"><div class="d_title">                	<h1>剑仙<em>作者：<a href="/author/%B1%F8%CE%A7%B3%C7%CF%C2" target="_blank">兵围城下</a></em></h1><div id="count"> 分 类：<span class="pd_r">仙侠修真</span> 点 击：<span class="pd_r" id="Hits">0</span> </div></body></html>`;
  test('NovelMeta：悠久书城——书名取 d_title 内 h1（顶层 h1 是站名）、无状态留空不猜', () => {
    const m = NovelMetaService.parseUjxsw(UJXSW_PAGE);
    assert.ok(m.ok && m.rule === '悠久书城');
    assert.equal(m.title, '剑仙'); // 顶层 <h1> 是「悠久小说网」站名，不得误取
    assert.equal(m.author, '兵围城下');
    assert.equal(m.category, '仙侠修真');
    assert.equal(m.status, ''); // 页面无状态字段——留空不猜
    assert.equal(m.cover, 'http://www.ujxsw.org/files/article/image/90/90293/90293s.jpg');
    assert.ok(m.intro.startsWith('剑仙最新章节由网友提供'));
  });

  // 棉花书吧 fixture：2026-11-20 www.mianhuaks.com/book/94801+15091 实测节选（无 og:novel，主区锚点）
  const MH_PAGE = `<html><head><meta name="description" content="快来棉花看书体验俺打的去埃及创作的《渣受重生》，无删减版本，最新章节更新，让你一站式畅享所有精彩！" /></head><body><a href="/tags.html" class="text-sm text-gray-700 hover:text-blue-600">分类</a><main class="bg-white max-w-screen-xl mx-auto p-2 space-y-3"><section class="bg-white p-3 rounded-lg shadow shadow hover:shadow-md flex items-start"><img src="/asset/default.jpg" alt="渣受重生" class="max-w-[90px] mr-4"><div><h1 class="text-2xl font-semibold text-gray-800 mb-2">渣受重生</h1><p class="text-sm text-gray-500">作者：<a href="/profile/62500/" class="hover:text-blue-600">俺打的去埃及</a></p><p class="text-xs text-gray-500 mt-1">更新时间：2026-07-06 19:22:20</p><p class="text-xs text-gray-500 mt-1">状态：连载</p></div></section><section class="p-3 rounded-lg shadow hover:shadow-md"><h2 class="text-xl font-semibold text-gray-800 mb-2">简介</h2><div id="desc" class="text-sm text-gray-600 max-h-40 overflow-y-auto text-justify "><p></p><p>谁说只有男人能重生，左拥右抱好不逍遥．女人照样可以，混娱乐卖<img src='/asset/fonts/45.png'>行，天下大事照样参与！</p></div></section><section class="p-3"><img src="/thumb/94/94801.jpg" alt="别书" class="max-w-[90px]"></section></body></html>`;
  test('NovelMeta：棉花书吧——主区锚点+状态归一；默认图/无类别留空，推荐区封面不误取', async () => {
    const m = NovelMetaService.parseMianhua(MH_PAGE);
    assert.ok(m.ok && m.rule === '棉花书吧');
    assert.equal(m.title, '渣受重生');
    assert.equal(m.author, '俺打的去埃及');
    assert.equal(m.status, '连载中');
    assert.equal(NovelMetaService.parseMianhua(MH_PAGE.replace('状态：连载', '状态：完结')).status,
      '已完本', '完结→已完本归一');
    assert.equal(m.category, ''); // 页面无类别字段，导航「分类」是 /tags.html 链接——留空不猜
    assert.equal(m.cover, ''); // 主区封面是站默认图 /asset/default.jpg，不算封面；推荐区 /thumb/ 不误取
    assert.ok(m.intro.includes('混娱乐卖') && m.intro.includes('行，') &&
      !m.intro.includes('45.png'), '防盗图 img 须剥除且前后文连贯');
    deps.state.rcpResponse = { statusCode: 200, body: enc(MH_PAGE) };
    const d = await NovelMetaService.fetchDetail('https://www.mianhuaks.com/book/94801/');
    assert.ok(d.rule === '棉花书吧' && d.title === '渣受重生', 'fetchDetail 分派命中');
    deps.state.rcpResponse = null;
  });

  // 番茄 fixture：2026-11-20 /api/book/info?bookId=7064405896540982309 真实响应（categoryV2 截首元素）
  const FQ_INFO_B64 = 'eyJjb2RlIjogMCwgIm1lc3NhZ2UiOiAic3VjY2VzcyIsICJkYXRhIjogeyJib29rTmFtZSI6ICLmrabnoo7mmJ/msrMiLCAiYXV0aG9yTmFtZSI6ICLlppblpJwiLCAiY3JlYXRpb25TdGF0dXMiOiAiMCIsICJjYXRlZ29yeVYyIjogIlt7XCJPYmplY3RJZFwiOiAyNTgsIFwiRGltXCI6IDEwLCBcIk5hbWVcIjogXCLkvKDnu5/njoTlubtcIiwgXCJFeHRlcm5hbERlc2NcIjogXCLlhaXlnZHnjoTlubvnmoTnu4/lhbjlsI/or7RcIiwgXCJHZW5kZXJcIjogMSwgXCJTdGF0dXNcIjogMSwgXCJBcHBJZFwiOiAxOTY3LCBcIkV4dHJhXCI6IFwie1xcXCJmb3JfcHVibGljYXRpb25cXFwiOjAsXFxcImljb25cXFwiOlxcXCJodHRwOi8vcDMtbm92ZWwuYnl0ZWltZy5jb20vbm92ZWwtc3RhdGljLzUzYjVlZGE0ODdjZGM5NzQzNzU1NDQ5NmM1NmY0ODFmfnRwbHYtbm9vcC5pbWFnZVxcXCJ9XCIsIFwiSW5FeHBlcmltZW50XCI6IGZhbHNlLCBcIk1haW5DYXRlZ29yeVwiOiB0cnVlLCBcIkNyZWF0ZVRpbWVcIjogMTYxMDAwMTA0Nn1dIiwgImFic3RyYWN0IjogIuaWsOS5puOAiuivm+WkqeWIgOOAi+W3suWPkeW4g++8ge+8ge+8gVxu56We5piO5Zyo5pif56m65L+v556w77yM5oG26a2U5Zyo5Zyw54ux5ZKG5ZOu44CCXG7ov5nmmK/kuIDkuKrkuIfml4/kuonpm4TvvIznpZ7prZTkubHoiJ7nmoTlpYflubvkuJbnlYzjgIJcbuS4gOS4quWvkumXqOWwkeW5tOaMgeWIgOiAjOihjO+8jOmAhua1geiAjOS4iu+8jOS7luimgeaIkOS4uui/meS4quS4lueVjOeahOeOi++8gVxu44CQ5pys5Lmm5pS557yW5Yqo55S744CK5q2m56KO5pif5rKz44CL5q2j5Zyo54Ot5pig44CRIiwgInRodW1iVXJsIjogImh0dHBzOi8vcDMtbm92ZWwtc2lnbi5ieXRlaW1nLmNvbS9ub3ZlbC1waWMvcDJvYTg4YjRmMGY5YjcwMmIzYzBlYjk0YzViYmQyMDY0Nzl+dHBsdi1yZXNpemU6MjI1OjMwMC5pbWFnZT9sazNzPTE5MWMxZWNjJngtZXhwaXJlcz0xNzk1MjA4ODI3Jngtc2lnbmF0dXJlPVMwVVNCSXBMaEZJd1NTam5YbyUyQnczVWRwanFrJTNEIn19Cg==';
  test('NovelMeta：番茄——rewriteUrl 走 info API 端到端，creationStatus 0/1 归一，categoryV2 首元素', async () => {
    assert.equal(NovelMetaService.rewriteUrl('https://fanqienovel.com/page/7064405896540982309'),
      'https://fanqienovel.com/api/book/info?bookId=7064405896540982309');
    const body = Buffer.from(FQ_INFO_B64, 'base64').toString('utf-8');
    const m = NovelMetaService.parseFanqie(body);
    assert.ok(m.ok && m.rule === '番茄小说');
    assert.equal(m.title, '武碎星河');
    assert.equal(m.author, '妖夜');
    assert.equal(m.category, '传统玄幻'); // categoryV2 首元素（Dim=10 主分类）
    assert.equal(m.status, '已完本'); // creationStatus "0"=完结（终章真页交叉验证）
    assert.ok(m.cover.startsWith('https://p3-novel-sign.byteimg.com/novel-pic/'));
    assert.ok(m.intro.includes('寒门少年持刀') && m.intro.length <= 500);
    assert.equal(NovelMetaService.parseFanqie(body.replace('"creationStatus": "0"',
      '"creationStatus": "1"')).status, '连载中');
    assert.equal(NovelMetaService.parseFanqie('not json').error.includes('不是 JSON'), true);
    const err = NovelMetaService.parseFanqie('{"code":-1,"message":"没有bookId"}');
    assert.ok(!err.ok && err.error.includes('没有bookId'));
    deps.state.rcpResponse = { statusCode: 200, body: enc(body) };
    const d = await NovelMetaService.fetchDetail('https://fanqienovel.com/page/7064405896540982309');
    assert.ok(d.ok && d.rule === '番茄小说' && d.title === '武碎星河', '详情页 url 重写后端到端命中');
    deps.state.rcpResponse = null;
  });

  // 潇湘 fixture：2026-11-20 www.xxsy.net/book/37389130704030609 实测节选（Vue SSR 无 og）
  const XXSY_PAGE = `<html><head><title>《星际？不慌，我有万界位面！》小说在线阅读_全文免费完结无删减 – 潇湘书院</title></head><body><dl class="bookprofile"><dt><div class="book-cover" style="width:210px;"><img src="//bookcover.yuewen.com/qdbimg/349573/c_37389130704030609/180" alt="星际？不慌，我有万界位面！" class="object-cover"></div></dt><dd><div class="title"><a href="javascript:;" class="read-by-phone"><i class="iconfont"></i>手机阅读</a><h1 style="font-size:23px;">星际？不慌，我有万界位面！</h1><span>文 / 挣脱蛛网的蝴蝶</span></div><p class="sub-cols"><span>会员作品</span><span>连载中</span><span>类别：科幻空间</span><span>发布：2026-11-07</span></p></dd></dl><div id="book_intro" class="book-profile" style="white-space:pre-line;">唐砚秋穿越星际，手握重宝，能够穿越位面。 一切的悲伤已经过去。</div></body></html>`;
  test('NovelMeta：潇湘书院——title 块内 h1 书名（前有手机阅读链接）、文/作者、sub-cols 跳会员标签、协议相对封面', async () => {
    const m = NovelMetaService.parseXxsy(XXSY_PAGE);
    assert.ok(m.ok && m.rule === '潇湘书院');
    assert.equal(m.title, '星际？不慌，我有万界位面！');
    assert.equal(m.author, '挣脱蛛网的蝴蝶');
    assert.equal(m.status, '连载中'); // sub-cols 首 span 是「会员作品」，状态取 连载|完结
    assert.equal(m.category, '科幻空间');
    assert.equal(m.cover, '//bookcover.yuewen.com/qdbimg/349573/c_37389130704030609/180');
    assert.ok(m.intro.startsWith('唐砚秋穿越星际'));
    deps.state.rcpResponse = { statusCode: 200, body: enc(XXSY_PAGE) };
    const d = await NovelMetaService.fetchDetail('https://www.xxsy.net/book/37389130704030609');
    assert.ok(d.rule === '潇湘书院' && d.cover.startsWith('https://bookcover.yuewen.com'),
      '分派命中+协议相对封面升 https');
    deps.state.rcpResponse = null;
  });

  // 掌阅 fixture：2026-11-20 m.zhangyue.com/detail/10161848 实测节选（无 og，SSR 正文；
  // 含「同类好书」推荐区 li 与 goCategory JS 绑定串两个干扰源）
  const ZY_PAGE = `<html><head><title>《雪落红炉[精品]》最新章节_第三十章 此生相许_似水无痕著_完结小说_都市免费小说_掌阅小说网</title><meta name="description" content="衣香鬓影，十里洋场。"></head><body><div class="cover"><div class="bookview"><div class="side"><img class="bookcover" data-js="book" src="https://bookbk.img.zhangyue01.com/idc_1/m_1,w_200,h_266/9f6a600f/group6/M00/20/F4/CmQUN1X1h8aEJMP9AAAAAJoALRc898462364.jpg?v=47ZDQw9E" alt="雪落红炉"></div><dl class="main"><dt class="ellipsis2">雪落红炉</dt>
<dd><span class="stars white"><span class="cur r9"></span></span> <span class="yellow">9.0</span> | <span class="f10">593人评分</span></dd>
<dd class="ellipsis">
<span class="">春芒文化</span> |
<span class="it red">似水无痕</span></dd>
<dd class="lastline"><span>15.3万字 </dd>
<dd class="tagbtn"><span data-js="goCategory" data-id="74" data-url="https://m.zhangyue.com/category/68/74">古代言情</span><span class="dec_triangle"></span></dd>
</dl></div></div><div class="brief_intro" data-js="brief_intro"><p data-js="brief_intro_txt">内容简介：衣香鬓影，十里洋场。在那个动荡的年代，因为父母之间的约定，她嫁入豪门。</p><div class="triangle_c">...<span class="dec_triangle"></span></div></div><div class="guess"><ul>
<li><a data-js="goRecommendBook" data-id="11282628" data-name="鬼医嫡女之毒妃倾城" href="https://m.zhangyue.com/detail/11282628"><div class="c flex"><div class="book_cover"><img src="https://bookbk.img.zhangyue01.com/idc_1/m_1,w_200,h_266/51100c86/group6/M00/41/EF/CmRaIVjdCxqEaj3GAAAAAA7gt5I355205448.jpg?v=BWWIvM2c" alt="鬼医嫡女之毒妃倾城"></div><dl class="book_info flex_item"><dt class="flex"><div class="flex_item ellipsis">鬼医嫡女之毒妃倾城</div>
<div class="score">9.5分</div>
</dt><dd class="author ellipsis">Echo涂涂</dd><dd class="content ellipsis2">想她戎马一生，剑下斩过多少宵小。</dd><dd><span class="tag">古代言情</span> <span class="tag">已完结</span></dd></dl></div></a></li> </ul></div><script>$("span[data-js=goCategory]").on("click", function(e){dataPointUrl({'page_type':'detail'});});</script></body></html>`;
  test('NovelMeta：掌阅——bookview 块限定主区（推荐区同名 tag/他书信息不干扰），title SEO 模板不当状态', () => {
    const m = NovelMetaService.parseZhangyue(ZY_PAGE);
    assert.ok(m.ok && m.rule === '掌阅小说网');
    assert.equal(m.title, '雪落红炉'); // 不取推荐区《鬼医嫡女》与带[精品]的 keywords
    assert.equal(m.author, '似水无痕'); // 同行前置「春芒文化」是出版方
    assert.equal(m.category, '古代言情');
    assert.equal(m.status, ''); // <title> 的「完结小说」是 SEO 固定模板，主区无状态字段
    assert.ok(m.intro.startsWith('衣香鬓影'), '剥「内容简介：」前缀');
    assert.ok(m.cover.startsWith('https://bookbk.img.zhangyue01.com'));
  });
  test('NovelMeta：掌阅端到端分派 m.zhangyue.com/detail', async () => {
    deps.state.rcpResponse = { statusCode: 200, body: enc(ZY_PAGE) };
    const d = await NovelMetaService.fetchDetail('https://m.zhangyue.com/detail/10161848');
    assert.ok(d.ok && d.rule === '掌阅小说网' && d.title === '雪落红炉');
    deps.state.rcpResponse = null;
  });

  // 群小说/一页书 fixture：2026-11-20 实测节选（qunxs.com/xiaoshuo_<id>、yiyeshu.cc/aibooks/<id>，
  // 均 og:novel 全量=通用零改动；一页书 legado 规则只写简介/封面是偷懒，og 实际齐全）
  const QX_PAGE = `<html><head><meta property="og:type" content="novel"/><meta property="og:title" content="COD乙女：被覆面们盯上了"/><meta property="og:image" content="http://www.qunxs.com//images/14/14014/14014s.png"/><meta property="og:description" content="【覆面＋乙女＋1vn＋第二人称＋偏真实＋HE】男主:konig keegan ghost"/><meta property="og:novel:category" content="都市言情小说"/><meta property="og:novel:author" content="小桃是甜妹"/><meta property="og:novel:book_name" content="COD乙女：被覆面们盯上了"/><meta property="og:novel:status" content="连载"/></head><body></body></html>`;
  const YE_PAGE = `<html><head><meta property="og:type" content="novel"><meta property="og:title" content="重生之宠妻手册云惘然免费阅读 - 一页书小说"><meta property="og:image" content="https://www.yiyeshu.cc/files/article/image/14/14104/14104s.jpg"><meta property="og:description" content="重生之宠妻手册小说阅读,三岁卫卯卯（含泪握拳）"><meta property="og:novel:category" content="其他类型"><meta property="og:novel:author" content="云惘然"><meta property="og:novel:book_name" content="重生之宠妻手册"><meta property="og:novel:status" content="连载"></head><body></body></html>`;
  test('NovelMeta：群小说/一页书——legado 语料下一批镜像站 og:novel 通用零改动命中（脏 og:title 去尾、双斜杠封面保留）', async () => {
    deps.state.rcpResponse = { statusCode: 200, body: enc(QX_PAGE) };
    const q = await NovelMetaService.fetchDetail('http://www.qunxs.com/xiaoshuo_14014.html');
    assert.ok(q.ok && q.rule === 'og:novel' && q.title === 'COD乙女：被覆面们盯上了'
      && q.author === '小桃是甜妹' && q.category === '都市言情小说' && q.status === '连载中',
      'qunxs 通用命中+双斜杠封面 url 原样');
    assert.ok(q.cover.indexOf('qunxs.com//images/') > 0, '双斜杠封面 GET 实测 200 可加载，不改写');
    deps.state.rcpResponse = { statusCode: 200, body: enc(YE_PAGE) };
    const y = await NovelMetaService.fetchDetail('https://www.yiyeshu.cc/aibooks/14104.html');
    assert.ok(y.ok && y.title === '重生之宠妻手册', '一页书脏 og:title 由 book_name 去尾');
    assert.ok(y.author === '云惘然' && y.status === '连载中' && y.category === '其他类型');
    deps.state.rcpResponse = null;
  });

  // 书坊/顶点 fixture：2026-11-20 实测节选（sfwx.com/\d+/\d+/ 与 dingdians.com/index/<id>/，
  // 均 og:novel 全量；顶点状态值是「全本」；sfwx 封面协议相对；sfwx 语料写 @get 而实页有 og）
  const SF_PAGE = `<html><head><meta property="og:type" content="novel" /><meta property="og:title" content="大明第一国舅最新章节" /><meta property="og:description" content="洪武二年春，一青年牵驴扶棺来到了新丰里。" /><meta property="og:image" content="//www.sfwx.com/images/10/10202/10202s.jpg" /><meta property="og:novel:category" content="历史小说" /><meta property="og:novel:author" content="黑胖的老鼠" /><meta property="og:novel:book_name" content="大明第一国舅" /><meta property="og:novel:status" content="连载" /></head><body></body></html>`;
  const DD_PAGE = `<html><head><meta property="og:type" content="novel"><meta property="og:title" content="我真不是邪神走狗"><meta property="og:description" content="《我真不是邪神走狗》穿越者林介经营着一家书店。"><meta property="og:image" content="http://www.dingdians.com/images/104975/104975639/104975639s.jpg"><meta property="og:novel:category" content="奇幻"><meta property="og:novel:author" content="万劫火"><meta property="og:novel:book_name" content="我真不是邪神走狗"><meta property="og:novel:status" content="全本"></head><body></body></html>`;
  test('NovelMeta：书坊/顶点——消耗期第二批 og:novel 通用命中，顶点「全本」归一已完本、协议相对封面升 https', async () => {
    deps.state.rcpResponse = { statusCode: 200, body: enc(SF_PAGE) };
    const s = await NovelMetaService.fetchDetail('http://www.sfwx.com/10/10202/');
    assert.ok(s.ok && s.rule === 'og:novel' && s.title === '大明第一国舅'
      && s.author === '黑胖的老鼠' && s.category === '历史小说' && s.status === '连载中');
    assert.ok(/^https?:\/\/www\.sfwx\.com\/images\//.test(s.cover), '协议相对封面按页面协议补全为绝对 url');
    deps.state.rcpResponse = { statusCode: 200, body: enc(DD_PAGE) };
    const d = await NovelMetaService.fetchDetail('https://www.dingdians.com/index/104975639/');
    assert.ok(d.ok && d.title === '我真不是邪神走狗' && d.status === '已完本', '「全本」→已完本');
    assert.ok(d.author === '万劫火' && d.category === '奇幻');
    assert.ok(String(deps.state.lastRequest.headers['User-Agent']).includes('Mobile'),
      '顶点按桌面 OS 特征拦 UA（Windows NT 完整串返回身份验证壳），必须移动 UA');
    assert.equal(String(deps.state.lastRequest.headers['User-Agent']).includes('Windows NT'), false,
      '他站不受影响由上方 qidian 用例断言');
    deps.state.rcpResponse = null;
  });

  // 云起/塔读 fixture：2026-11-20 实测（云起 read 壳无 og→detail og:novel；塔读 og 全量含脏 title/双斜杠封面）
  const YQ_DETAIL = `<html><head><meta property="og:type" content="novel"><meta property="og:novel:book_name" content="粟粟"><meta property="og:novel:author" content="荆棘之歌"><meta property="og:novel:category" content="古代言情"><meta property="og:novel:status" content="连载"><meta property="og:image" content="https://wfqqreader-1252317822.image.myqcloud.com/cover/857/59718575/s_59718575.jpg"><meta property="og:description" content="山洪冲下来一个白里透红的小娃娃。"></head><body></body></html>`;
  test('NovelMeta：云起 read→detail 重写 + 塔读式脏 og:title 由 book_name 去尾——通用 og:novel 覆盖阅文/掌阅系', async () => {
    assert.equal(NovelMetaService.rewriteUrl('https://yunqi.qq.com/read/59718575/'),
      'https://yunqi.qq.com/detail/59718575');
    assert.equal(NovelMetaService.rewriteUrl('https://www.xxsy.net/book/37389130704030609'),
      'https://www.xxsy.net/book/37389130704030609'); // 他站不受影响
    deps.state.rcpResponse = { statusCode: 200, body: enc(YQ_DETAIL) };
    const d = await NovelMetaService.fetchDetail('https://yunqi.qq.com/read/59718575/');
    assert.ok(d.ok && d.rule === 'og:novel' && d.title === '粟粟' && d.status === '连载中'
      && d.category === '古代言情');
    deps.state.rcpResponse = null;
    const td = NovelMetaService.parseGeneric(`<html><head><meta property="og:title" content="仕途风云小说_阿诸_仕途风云最新章节_仕途风云无弹窗免费阅读_塔读免费小说,塔读"><meta property="og:novel:book_name" content="仕途风云"><meta property="og:novel:author" content="阿诸"><meta property="og:novel:category" content="现代都市"><meta property="og:novel:status" content="连载"><meta property="og:image" content="https://media3.tadu.com//2023/05/18/19/02/353ff3f10ca8409095452f668244e5a5.jpg"><meta property="og:description" content="简介：省督查室副主任荆涛。"></head><body></body></html>`);
    assert.ok(td.rule === 'og:novel' && td.title === '仕途风云' && td.status === '连载中');
  });

  // 飞卢 gb2312 fixture：2026-11-20 b.faloo.com/1484744.html 实测 meta 行，GBK 字节 base64
  test('NovelMeta：charset 嗅探+GBK 解码——飞卢老站不乱码，utf-8 页不受影响', async () => {
    const FALOO_B64 = 'PGh0bWw+PGhlYWQ+PG1ldGEgaHR0cC1lcXVpdj0iQ29udGVudC1UeXBlIiBjb250ZW50PSJ0ZXh0L2h0bWw7IGNoYXJzZXQ9Z2IyMzEyIj4KPG1ldGEgcHJvcGVydHk9Im9nOnRpdGxlIiBjb250ZW50PSLFzLXjzfK959W9waa1yLy2o6zC283iz8XE8tbuzOzX7tDC1cK92ijC283iz8XE8tbuzOwp1NrP39TEtsFft8nCrNChy7XN+CI+CjxtZXRhIHByb3BlcnR5PSJvZzpkZXNjcmlwdGlvbiIgY29udGVudD0iob63ycKs0KHLtc34tsC80sep1LzQocu1o7rFzLXjzfK959W9waa1yLy2o6zC283iz8XE8tbuzOyhv8zsxLu9tcHZ1u7M7KOsv6q+1sXMtePN8r3n1b3BpsG/vLaho7TTsazXqby2o6yxrMe9vLahraGtsazQx7y2o6y649DHvLajrNDHz7W8tqOs0MfPtc3FvLajrLWlzOXT7tbmvLajrLbg1KrT7tbmvLajrM7ez9624NSq0+7W5qGtoa3O3s/eutDX06Os1rjK/cv+o6yzrNa4yv3L/qOssru/ybTvu/nK/aGtoa3V5s/WyrWjrLW9Ij4KPG1ldGEgcHJvcGVydHk9Im9nOmltYWdlIiBjb250ZW50PSJodHRwOi8vaW1nLmZhbG9vLmNvbS9Ob3ZlbC80OTh4NzA1LzEvMTU5NS8wMDE1OTU5NTcuanBnIj4KPC9oZWFkPjxib2R5PjxoMT7FzLXjzfK959W9waa1yLy2o6zC283iz8XE8tbuzOw8L2gxPjwvYm9keT48L2h0bWw+';
    const raw = Buffer.from(FALOO_B64, 'base64');
    deps.state.rcpResponse = { statusCode: 200,
      body: raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) };
    const m = await NovelMetaService.fetchDetail('https://b.faloo.com/1484744.html');
    assert.ok(m.ok && m.rule === '通用og');
    assert.ok(m.intro.includes('飞卢小说网独家签约小说') && m.intro.includes('无限多元宇宙') &&
      !m.intro.includes('\uFFFD'), 'GBK 简介须可读不乱码');
    assert.equal(m.cover, 'http://img.faloo.com/Novel/498x705/1/1595/001595957.jpg');
    deps.state.rcpResponse = null;
    assert.ok(NovelMetaService.decodeBody(enc('<meta charset="utf-8">中文正常'))
      .includes('中文正常'), 'utf-8 页解码不受嗅探影响');
    // 飞卢真实布局：charset 声明在字节 ~2413（2KB 窗口会漏，4KB 才够）
    const late = Buffer.from(FALOO_B64, 'base64');
    const pad = Buffer.concat([Buffer.from('<html><head>' + 'x'.repeat(1000)), late.slice(12)]);
    const padBuf = pad.buffer.slice(pad.byteOffset, pad.byteOffset + pad.byteLength);
    assert.ok(NovelMetaService.decodeBody(padBuf).includes('charset=gb2312'),
      'charset 声明落在 2KB~4KB 窗口也必须被嗅到');
  });

  test('NovelMeta 分派：书源引擎命中即优先，不再走站点规则重抓', async () => {
    const { NovelMetaService } = await load('RealNovelMeta');
    const { Reader3Native } = await load('reader3Stub');
    Reader3Native.result = { ok: true, error: '', rule: '测试书源', name: '引擎书', author: '作者甲',
      kind: '都市·完结', intro: '引擎简介', coverUrl: 'https://cdn.example/c.jpg',
      tocUrl: 'https://s.example/book/1/', lastChapter: '第2章' };
    const prev = deps.state.requests.length;
    const meta = await NovelMetaService.fetchDetail('https://www.17k.com/book/123.html');
    Reader3Native.result = null;
    assert.strictEqual(meta.ok, true);
    assert.strictEqual(meta.rule, '书源:测试书源');
    assert.strictEqual(meta.title, '引擎书');
    assert.strictEqual(meta.status, '已完本', 'kind 里的完结词归一为状态');
    assert.strictEqual(meta.intro, '引擎简介');
    assert.strictEqual(meta.cover, 'https://cdn.example/c.jpg');
    assert.strictEqual(deps.state.requests.length, prev, '引擎命中不得再 rcp 抓页');
  });

  test('NovelMeta 分派：引擎提取失败→现有站点规则兜底（再抓一次）', async () => {
    const { NovelMetaService } = await load('RealNovelMeta');
    const { Reader3Native } = await load('reader3Stub');
    Reader3Native.result = { ok: false, error: '书源规则未提取到书名/简介/封面', rule: '失效源',
      name: '', author: '', kind: '', intro: '', coverUrl: '', tocUrl: '', lastChapter: '' };
    deps.state.rcpResponse = { statusCode: 200,
      body: enc('<meta property="og:description" content="兜底简介"/>') };
    const meta = await NovelMetaService.fetchDetail('https://example.com/book/9/');
    Reader3Native.result = null;
    deps.state.rcpResponse = null;
    assert.strictEqual(meta.ok, true);
    assert.strictEqual(meta.rule, '通用og');
    assert.strictEqual(meta.intro, '兜底简介');
  });

  const R3_SOURCES = JSON.stringify([
    { bookSourceUrl: 'https://bad.example@.*', bookSourceName: '禁用源', enabled: false,
      bookUrlPattern: '.*bad\\.example/book/.*', ruleBookInfo: { name: 'h1@text' } },
    { bookSourceUrl: 'https://pat.example', bookSourceName: '模式源', enabled: true,
      bookUrlPattern: '.*pat\\.example/book/\\d+', ruleBookInfo: { name: 'h1@text' } },
    { bookSourceUrl: '全本小说5@https://at.example', bookSourceName: 'at源', enabled: true,
      bookUrlPattern: '', ruleBookInfo: { name: 'h1@text' } },
    { bookSourceUrl: 'https://url.example/a/b', bookSourceName: 'url源', enabled: true,
      bookUrlPattern: '', ruleBookInfo: { name: 'h1@text' } },
  ]);

  test('Reader3.matchSource：pattern 优先；@ 约定取右侧 baseUrl 匹配；禁用源跳过', async () => {
    const { Reader3Native } = await load('RealReader3');
    const sources = JSON.parse(R3_SOURCES);
    assert.strictEqual(Reader3Native.matchSource(sources, 'https://pat.example/book/123.html').bookSourceName, '模式源');
    assert.strictEqual(Reader3Native.matchSource(sources, 'https://at.example/xs-1/du-2.html').bookSourceName, 'at源',
      'legado「源名@baseUrl」必须按右侧站点地址匹配（左侧是中文源名，永不命中）');
    assert.strictEqual(Reader3Native.matchSource(sources, '全本小说5@https://at.example').bookSourceName, 'at源');
    assert.strictEqual(Reader3Native.matchSource(sources, 'https://url.example/a/b/x/1').bookSourceName, 'url源');
    assert.strictEqual(Reader3Native.matchSource(sources, 'https://bad.example/book/1'), null,
      'enabled=false 的书源 pattern/url 两条通道都不得命中');
  });

  test('Reader3.meta 全链路：rawfile 装载→匹配书源→引擎外层协议→字段映射', async () => {
    const { Reader3Native } = await load('RealReader3');
    globalThis.__r3Available = true;
    globalThis.__r3Ctx = { filesDir: '/data/app' };
    deps.state.sourceJson = R3_SOURCES;
    globalThis.__r3Payload = '{"status":"ok","result":{"field":"ruleBookInfo","data":' +
      '"{\\"name\\":\\"书甲\\",\\"author\\":\\"作者乙\\",\\"kind\\":\\"连载中\\",\\"intro\\":\\"简介丙\\",' +
      '\\"coverUrl\\":\\"https://pat.example/c.jpg\\"}"}}';
    const m = await Reader3Native.meta('https://pat.example/book/123.html');
    assert.strictEqual(m.ok, true);
    assert.strictEqual(m.name, '书甲');
    assert.strictEqual(m.kind, '连载中');
    assert.strictEqual(m.coverUrl, 'https://pat.example/c.jpg');
    assert.strictEqual(m.rule, '模式源');
    assert.strictEqual(JSON.parse(globalThis.__r3SourceArg).bookSourceName, '模式源',
      '传给引擎的必须是命中的整条书源规则');
  });

  test('Reader3.meta：无匹配书源返回 null（调用方走站点规则）；引擎 error 带原文', async () => {
    const { Reader3Native } = await load('RealReader3');
    assert.strictEqual(await Reader3Native.meta('https://none.example/book/1'), null);
    globalThis.__r3Payload = '{"status":"error","message":"引擎错误 -6"}';
    const m = await Reader3Native.meta('https://pat.example/book/9.html');
    assert.strictEqual(m.ok, false);
    assert.strictEqual(m.error, '引擎错误 -6');
    globalThis.__r3Available = false;
  });

  test('Reader3 http 桥：rcp 抓取→utf-8 base64 按协议回填，书源 headers 透传', async () => {
    const { Reader3Native } = await load('RealReader3');
    globalThis.__r3Available = true;
    globalThis.__r3Payload = '{"status":"ok","result":{"data":"{\\"name\\":\\"x\\"}"}}';
    await Reader3Native.meta('https://pat.example/book/123.html'); // 建立回调注册
    deps.state.rcpResponse = { statusCode: 200,
      headers: { 'content-type': 'text/html; charset=utf-8' }, body: enc('<h1>标题页</h1>') };
    globalThis.__r3Delivered = null;
    globalThis.__r3Cb(JSON.stringify({ kind: 'http', method: 'GET',
      url: 'https://pat.example/book/123.html', headers: { 'User-Agent': 'SrcUA/1.0' } }));
    await flush();
    const d = JSON.parse(globalThis.__r3Delivered);
    assert.strictEqual(d.status_code, 200);
    assert.strictEqual(d.body_b64, Buffer.from('<h1>标题页</h1>', 'utf8').toString('base64'),
      'body_b64 必须是 UTF-8 字节的 base64');
    assert.deepStrictEqual(d.headers['content-type'], ['text/html; charset=utf-8']);
    assert.strictEqual(d.transport_error, undefined);
    assert.strictEqual(deps.state.lastRequest.headers['User-Agent'], 'SrcUA/1.0', '书源自带 UA 必须透传');
    deps.state.rcpResponse = null;
  });

  test('Reader3 http 桥：抓取异常也必须 deliver transport_error（引擎线程不能挂等）', async () => {
    const { Reader3Native } = await load('RealReader3');
    deps.state.rcpError = new Error('connection reset');
    globalThis.__r3Delivered = null;
    globalThis.__r3Cb(JSON.stringify({ kind: 'http', method: 'GET', url: 'https://x.example/', headers: {} }));
    await flush();
    const d = JSON.parse(globalThis.__r3Delivered);
    assert.strictEqual(d.status_code, 0);
    assert.strictEqual(d.transport_error, 'connection reset');
    deps.state.rcpError = null;
  });

  test('Reader3 书源库不随包分发：两处候选路径都无文件时 meta 返回 null（全走兜底）', async () => {
    const { Reader3Native } = await load('RealReader3');
    Reader3Native.loaded = false; // 清类缓存（strip-types 擦除 private，测试可重置）
    deps.state.sourceJson = null;
    assert.strictEqual(await Reader3Native.meta('https://pat.example/book/123.html'), null,
      '未导入书源时不得误接管 url');
  });

  test('Reader3 书源导入通道：沙箱 files 读不到时从 /data/local/tmp 候选位装载', async () => {
    const { Reader3Native } = await load('RealReader3');
    Reader3Native.loaded = false;
    deps.state.sourceJson = R3_SOURCES;
    globalThis.__r3Ctx = { filesDir: '/no/such/dir' }; // 模拟 SELinux 挡住的沙箱位
    globalThis.__r3Payload = '{"status":"ok","result":{"data":"{\\"name\\":\\"tmp书\\"}"}}';
    const m = await Reader3Native.meta('https://pat.example/book/123.html');
    assert.strictEqual(m !== null && m.ok, true, 'tmp 候选位命中即接管');
    assert.strictEqual(m.name, 'tmp书');
  });

  test('Reader3 导入：Legado 数组校验（无效条目过滤）→ 写沙箱并即时刷新缓存', async () => {
    const { Reader3Native } = await load('RealReader3');
    Reader3Native.loaded = false;
    deps.state.sourceJson = null;
    globalThis.__r3Ctx = { filesDir: '/data/app' };
    globalThis.__r3Available = true;
    const text = JSON.stringify([
      { bookSourceUrl: '全本小说9@https://imp.example', bookSourceName: '导入源', ruleBookInfo: { name: 'h1@text' } },
      { bookSourceName: '无URL条目' },
    ]);
    const n = await Reader3Native.importFromText(text);
    assert.strictEqual(n, 1, '无 bookSourceUrl 的条目被过滤');
    assert.strictEqual(JSON.parse(deps.state.written[deps.state.written.length - 1]).length, 1,
      '落盘文本必须也是过滤后的');
    assert.strictEqual(await Reader3Native.count(), 1);
    // 导入后 meta() 立即用新缓存（无需重读文件）
    globalThis.__r3Payload = '{"status":"ok","result":{"data":"{\\"name\\":\\"导入书\\"}"}}';
    const m = await Reader3Native.meta('https://imp.example/book/1.html');
    assert.strictEqual(m.rule, '导入源');
    assert.strictEqual(m.name, '导入书');
  });

  test('Reader3 导入校验：坏 JSON / 非数组 / 全无效条目 → 抛错且不落盘', async () => {
    const { Reader3Native } = await load('RealReader3');
    const before = deps.state.written.length;
    await assert.rejects(() => Reader3Native.importFromText('这不是JSON'), /不是有效的 JSON/);
    await assert.rejects(() => Reader3Native.importFromText('{"bookSourceUrl":"x"}'), /JSON 数组/);
    await assert.rejects(() => Reader3Native.importFromText('[]'), /未解析到有效书源/);
    assert.strictEqual(deps.state.written.length, before, '失败导入不得写盘');
  });

  test('Reader3 导入：URL 通道 rcp 抓取（非 200 报错）走同一校验落盘', async () => {
    const { Reader3Native } = await load('RealReader3');
    Reader3Native.loaded = false;
    const good = JSON.stringify([{ bookSourceUrl: 'https://u.example', bookSourceName: 'URL源' }]);
    deps.state.rcpResponse = { statusCode: 200, headers: { 'content-type': 'application/json' }, body: enc(good) };
    assert.strictEqual(await Reader3Native.importFromUrl('https://host/bookmeta_sources.json'), 1);
    deps.state.rcpResponse = { statusCode: 404, headers: {}, body: enc('') };
    await assert.rejects(() => Reader3Native.importFromUrl('https://host/none.json'), /HTTP 404/);
    deps.state.rcpResponse = null;
  });

  test('get_novel_meta：17K url 走工具输出简介/封面，读工具不过闸门，行模板带类别/状态/字数', async () => {
    deps.state.rcpResponse = { statusCode: 200, body: enc(K17_PAGE) };
    const s = await RealAiTools.execute('get_novel_meta', '{"url":"https://www.17k.com/book/1018082.html"}');
    assert.ok(s.includes('书名：武逆焚天') && s.includes('作者：疯橘子') &&
      s.includes('类别：东方玄幻') && s.includes('状态：连载中') &&
      s.includes('简介：') && s.includes('神奇的大陆'));
    assert.equal(RealAiTools.needsConfirm('get_novel_meta'), false);
    const empty = await RealAiTools.execute('get_novel_meta', '{}');
    assert.ok(empty.includes('url 必填'));
    deps.state.rcpResponse = { statusCode: 200, body: enc(KUJIANG_PAGE) };
    const kj = await RealAiTools.execute('get_novel_meta', '{"url":"https://m.kujiang.com/book/91737"}');
    assert.ok(kj.includes('规则：og:novel') && kj.includes('书名：灯下黑') && kj.includes('状态：已完本'));
    deps.state.rcpResponse = null;
    // search_sonovel 行模板增强：JSON 里已有的类别/状态/字数要上屏，并提示 get_novel_meta
    toolsState.sonovelEnvelope = { status: 200, error: '', body: { code: 200, message: '', data: [
      { sourceId: 4, sourceName: '全本小说网', url: 'http://www.quanben.io/n/gmzz/list.html',
        bookName: '诡秘之主', author: '爱潜水的乌贼', category: '玄幻', status: '已完结',
        wordCount: '956万字', latestChapter: '12月1日新番外' },
    ] } };
    const row = await RealAiTools.execute('search_sonovel', '{"query":"诡秘之主"}');
    assert.ok(row.includes('类别：玄幻') && row.includes('已完结') && row.includes('字数：956万字') &&
      row.includes('get_novel_meta'));
    toolsState.sonovelEnvelope = null;
  });

  test('search_meta：query/book_id 三通道聚合、subject_id 详情模式、读工具不过闸门', async () => {
    deps.state.rcpResponse = { statusCode: 200, body: enc(JSON.stringify([
      { title: '三体', author_name: '刘慈欣', year: '2008', type: 'b', id: '2567698',
        pic: 'https://img/x.jpg', url: 'https://book.douban.com/subject/2567698/' },
    ])) };
    toolsState.referBooks = [{ title: '三体全集', authors: ['刘慈欣'], publisher: '科幻世界',
      isbn: '9787536692930', source: '豆瓣', cover_url: 'https://img/cover.jpg' }];
    toolsState.sonovelEnvelope = { status: 200, error: '', body: { data: [
      { bookName: '三体', author: '刘慈欣', sourceName: '全本小说网', sourceId: 7,
        url: 'http://www.quanben.io/n/santi/', latestChapter: '第二百六十三章 尾声' },
    ] } };
    const out = await RealAiTools.execute('search_meta', JSON.stringify({ query: '三体', book_id: 1481 }));
    assert.ok(out.includes('subject_id=2567698'));
    assert.ok(out.includes('服务端多源候选'));
    assert.ok(out.includes('书源：全本小说网(id=7)'));
    assert.equal(RealAiTools.needsConfirm('search_meta'), false);
    // subject_id 详情模式（不触发 refer/sonovel）
    deps.state.rcpResponse = { statusCode: 200, body: enc(DOUBAN_PAGE) };
    const d2 = await RealAiTools.execute('search_meta', '{"subject_id":"2567698"}');
    assert.ok(d2.includes('豆瓣评分：8.9'));
    assert.ok(d2.includes('ISBN：9787536692930'));
    assert.ok(!d2.includes('服务端多源候选'));
    // 空参数引导
    const d3 = await RealAiTools.execute('search_meta', '{}');
    assert.ok(d3.includes('至少提供'));
    deps.state.rcpResponse = null;
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
