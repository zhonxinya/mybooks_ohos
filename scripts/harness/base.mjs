// harness 环境层（拆分自 check_ai_assistant.mjs）：state/shim/依赖桩、用例注册表、setup 装配
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { dir } from './paths.mjs';
import { stagePure, stagePage, stageAiService, stageChatStore, stageAiPersona, stageMetaSearch,
  stageEncyclopedia, stageWebFetch, stageMcp, stageQwenAudio, stageNovelMeta, stageReader3, stageAiTools,
  stageAiVoiceKit } from './stages.mjs';

export const settingsDefaults = () => ({
  config: { providerId: 'deepseek', baseUrl: 'https://api.deepseek.com/v1', model: 'deepseek-chat',
    hasKey: true, temperature: 0.7, vision: false, visionOverride: '', contextLength: 8 },
  providers: [
    { id: 'deepseek', name: 'DeepSeek', baseUrl: 'https://api.deepseek.com/v1', model: 'deepseek-chat', vision: false },
    { id: 'opencode', name: 'OpenCode (Go)', baseUrl: 'https://opencode.ai/inference/openai/v1', model: 'big-pickle', vision: false },
  ],
  keys: new Set(['deepseek']), saved: null, models: [], fetchError: '', completeReply: 'ok', mcpTools: [],
  providerModels: {},
  voiceProviderId: '', voiceModel: '', voiceConfig: null, lastCompleteConfig: null, lastCompleteMessages: null,
  speakEngine: 'system', speakCalls: [], speakStops: 0, callMode: 'realtime',
});
export const state = {
  ready: true, handlers: null, copied: '', cancel: null,
  shelf: { books: [] }, search: async () => ({ body: { books: [] } }),
  recommend: async () => [], summary: async () => '', review: async () => '', meta: async () => ({}),
  settings: settingsDefaults(), prefs: new Map(), lastMessages: null, lastToast: '',
};
globalThis.__aiCheck = state;
// 设置页保存时会记一个配置版本号，桩掉避免 save() 抛错
globalThis.AppStorage = { setOrCreate: () => {} };
// bindMenu 构造器（权限/模型菜单）运行时引用 $r 取资源；测试不渲染，桩成资源名即可
globalThis.$r = (name) => name;
// #1506 onListTouch 触控意图判定引用 TouchType；桩值与 ArkUI 枚举序号一致
globalThis.TouchType = { Down: 0, Up: 1, Move: 2, Cancel: 3, OutsideTrigger: 4 };
export function writeStubs() {
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
  loadProviderModels: (id) => (state.settings.providerModels[id] ?? []).slice(),
  saveProviderModels: (id, models) => { state.settings.providerModels[id] = models.slice(); },
  mcpToolset: async () => state.settings.mcpTools.slice(),
  saveConfig: (providerId, baseUrl, model, apiKey, temperature, visionOverride, contextLength) => {
    state.settings.saved = { providerId, baseUrl, model, apiKey, temperature, visionOverride, contextLength };
    if (apiKey.length > 0) { state.settings.keys.add(providerId); }
    // 与真实 AiServiceConfig 对齐：地址按服务商分槽，互不覆盖
    if (baseUrl.length > 0) {
      if (!state.settings.baseUrlByProvider) { state.settings.baseUrlByProvider = {}; }
      state.settings.baseUrlByProvider[providerId] = baseUrl;
    }
    state.settings.config = { providerId, baseUrl, model,
      hasKey: state.settings.keys.has(providerId), temperature,
      visionOverride, contextLength,
      vision: visionOverride === 'on' ? true : visionOverride === 'off' ? false :
        /vl|vision|4o|omni|gemini|claude|llava|qvq/i.test(model) };
  },
  baseUrlFor: (id) => {
    const saved = state.settings.baseUrlByProvider && state.settings.baseUrlByProvider[id];
    if (saved !== undefined && saved.length > 0) { return saved; }
    if (state.settings.config.providerId === id) { return state.settings.config.baseUrl; }
    const p = state.settings.providers.find((x) => x.id === id);
    return p !== undefined ? p.baseUrl : '';
  },
  detectVision: (model) => /vl|vision|4o|omni|gemini|claude|llava|qvq/i.test(model),
  supportsTools: () => (state.settings.config.baseUrl ?? '').indexOf('opencode.ai') >= 0,
  contextRounds: (k) => (k <= 4 ? 4 : k <= 8 ? 8 : k <= 32 ? 16 : k <= 128 ? 30 : 50),
  loadPermission: () => state.settings.permission ?? 'confirm',
  savePermission: (mode) => { state.settings.permission = mode; },
  complete: async (messages, maxTokens, config) => {
    state.settings.lastCompleteConfig = config === undefined ? state.settings.config : config;
    state.settings.lastCompleteMessages = messages;
    return state.settings.completeReply;
  },
  loadAutoSpeak: () => state.settings.autoSpeak === true,
  saveAutoSpeak: (v) => { state.settings.autoSpeak = v; },
  loadVoiceProviderId: () => state.settings.voiceProviderId,
  loadVoiceModel: () => state.settings.voiceModel,
  hasVoiceProvider: () => state.settings.voiceProviderId.length > 0,
  saveVoiceConfig: (providerId, model) => {
    state.settings.voiceProviderId = providerId;
    state.settings.voiceModel = model;
  },
  loadSpeakEngine: () => state.settings.speakEngine ?? 'system',
  saveSpeakEngine: (e) => { state.settings.speakEngine = e === 'cloud' ? 'cloud' : 'system'; },
  loadCallMode: () => state.settings.callMode ?? 'realtime',
  saveCallMode: (m) => { state.settings.callMode = m === 'turn' ? 'turn' : 'realtime'; },
  loadRealtimeTimbre: () => state.settings.rtTimbre ?? 'longanqian',
  saveRealtimeTimbre: (v) => { state.settings.rtTimbre = v; },
  loadTtsTimbre: () => state.settings.ttsTimbre ?? 'longanhuan_v3.6',
  saveTtsTimbre: (v) => { state.settings.ttsTimbre = v; },
  loadReasoningEffort: () => state.settings.reasoningEffort ?? 'default',
  saveReasoningEffort: (v) => { state.settings.reasoningEffort = v; },
  loadVoiceConfig: () => {
    if (state.settings.voiceProviderId.length > 0) {
      const p = state.settings.providers.find((x) => x.id === state.settings.voiceProviderId);
      // 与真实 AiServiceConfig 对齐：配了语音服务商就独立解析（同全局服务商也用语音档 model/地址）
      if (p !== undefined) {
        const savedBase = state.settings.baseUrlByProvider && state.settings.baseUrlByProvider[p.id];
        const baseUrl = savedBase && savedBase.length > 0 ? savedBase : p.baseUrl;
        return { providerId: p.id, baseUrl,
          model: state.settings.voiceModel.length > 0 ? state.settings.voiceModel : p.model,
          hasKey: state.settings.keys.has(p.id), temperature: state.settings.config.temperature,
          vision: false, visionOverride: '', contextLength: state.settings.config.contextLength };
      }
    }
    return state.settings.config;
  },
};
// 页面测试不触发真实播报，但 import 名要在（对话页 ttsAvailable 门控下调用不到）
export const QwenAudioService = {
  startRecording: async () => {}, stopRecording: async () => '', stopRecordingCleanup: () => {},
  transcribe: async () => '', synthesize: async () => '/tmp/tts_test.mp3', playFile: async () => true, stopPlayback: () => {},
};
export const SpeakService = {
  speak: async (text) => { state.settings.speakCalls.push(text); return true; },
  stop: () => { state.settings.speakStops++; },
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
export const AppRouter = { getParams: () => (globalThis.__aiCheck.routerParams ?? {}) };
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
// 隐藏渲染器（fetch_url 类浏览器降级）桩：页面测试不渲染 Web，符号可解析即可
export const webview = { WebviewController: class { loadUrl() {} runJavaScript() { return Promise.resolve(''); } } };
export const BrowserRenderService = {
  attach: () => {}, detach: () => {}, onPageEnd: () => {}, isReady: () => false, render: async () => '',
};
`;
writeFileSync(join(dir, 'shim.ts'), shim);

// 真实 AiService 的运行时依赖桩：内存存储 + 可编程的 SDK 假响应
writeFileSync(join(dir, 'aiServiceDeps.ts'), `
// Buffer.from(x).buffer 带池化填充，必须 slice 出精确字节（模拟 rcp 的紧凑 ArrayBuffer）
const enc = (s) => { const b = Buffer.from(s, 'utf8'); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); };
export const state = { store: new Map(), models: [], rcpResponse: null, rcpResponses: [], rcpThrowQueue: [], rcpError: null, lastRequest: null, requests: [], chatCalls: [], chatStreamRounds: null, chatResponse: null, chatResponses: [], sourceJson: null, written: [], ttsFiles: [], lastOpenedPath: '', feedErrors: [] };
export const util = {
  // 透传 encoding（gbk/gb2312 走 Node 内置 TextDecoder），utf-8 用法不受影响；
  // QwenAudioService 用 new util.TextDecoder()，AiService 用 create()，class 双形态兼容
  TextDecoder: class {
    static create(encoding, _options) { return new this(encoding); }
    constructor(encoding) { this.enc = encoding ?? 'utf-8'; }
    decodeToString(u8) { return new TextDecoder(this.enc).decode(u8); }
  },
  // Reader3Native http 桥用：utf-8 文本→字节→base64（与 ArkTS 语义一致）
  TextEncoder: class { encodeInto(s) { return new Uint8Array(Buffer.from(s ?? '', 'utf8')); } },
  Base64Helper: class { encodeToStringSync(u8) { return Buffer.from(u8).toString('base64'); } },
  generateRandomUUID: () => 'test-uuid-fixed-0001',
};
export class OpenAI {
  chat = { completions: { create: (body, options) => {
    state.chatCalls.push({ body, options });
    const ok = { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: 'ok' } }] })) };
    let resp = state.chatResponse ?? ok;
    if (Array.isArray(state.chatResponses) && state.chatResponses.length > 0) {
      resp = state.chatResponses.shift();
    }
    // 流式 tool_calls 回路用例：chatStreamRounds 按轮预置批次，每轮 create 消费一批（微任务内喂，
    // 必须在该轮 response 落定前送达——真实 SDK 亦如此）
    if (Array.isArray(state.chatStreamRounds) && state.chatStreamRounds.length > 0) {
      const chunks = state.chatStreamRounds.shift();
      Promise.resolve().then(() => {
        // 真实 SDK onData 一次收一批 chunks[]，喂单元素会因缺 length 静默空转
        // feedErrors 收集逃逸到回调外的异常——真机上这就等于 napi 栈崩溃、应用退出
        try { options.onData(chunks); } catch (e) { state.feedErrors.push(e.message); }
      });
    }
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
      if (state.rcpThrowQueue.length > 0) { throw state.rcpThrowQueue.shift(); }
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
  openSync: (p) => { state.lastOpenedPath = typeof p === 'string' ? p : ''; return { fd: 7 }; },
  readSync: (fd, buf) => { const b = Buffer.from(state.sourceJson ?? '', 'utf8'); b.copy(Buffer.from(buf)); return b.length; },
  // QwenAudioService 写 mp3 传 ArrayBuffer：非字符串不得污染 sourceJson；
  // /tts/ 路径的写入登记进 ttsFiles，让 cleanupTtsCache 的 list/unlink 有真实对象
  writeSync: (fd, data) => {
    state.written.push(data);
    if (typeof data === 'string') { state.sourceJson = data; }
    if (state.lastOpenedPath.includes('/tts/')) {
      const p = state.lastOpenedPath;
      state.ttsFiles.push(p.slice(p.lastIndexOf('/') + 1));
    }
  },
  closeSync: () => {},
  mkdirSync: () => {},
  listFileSync: (p) => p.endsWith('/tts') ? state.ttsFiles.slice() : [],
  unlinkSync: (p) => { const name = p.slice(p.lastIndexOf('/') + 1); const i = state.ttsFiles.indexOf(name); if (i >= 0) { state.ttsFiles.splice(i, 1); } },
  OpenMode: { READ_ONLY: 0, READ_WRITE: 2, CREATE: 64, TRUNC: 512 },
};
export { fs as fileIo };
export const hilog = { info: () => {}, warn: () => {}, error: () => {} };
// QwenAudioService 顶层 import 的名字必须齐全（录音/播放不在用例内走空壳即可）
export class BusinessError extends Error { code = 0; }
export const audio = {
  AudioSamplingRate: { SAMPLE_RATE_16000: 8 }, AudioChannel: { CHANNEL_1: 1 },
  AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 2 }, AudioEncodingType: { ENCODING_TYPE_RAW: 0 },
  SourceType: { SOURCE_TYPE_MIC: 6 },
  createAudioCapturer: async () => ({ on: () => {}, start: async () => {}, stop: async () => {}, release: async () => {} }),
};
export const media = {
  createAVPlayer: async () => ({ on: () => {}, off: () => {}, prepare: async () => {}, play: async () => {}, stop: async () => {}, release: async () => {} }),
};
export const TalebookService = {
  prefGet: (key, fallback = '') => state.store.has('p:' + key) ? state.store.get('p:' + key) : fallback,
  prefSet: (key, value) => { state.store.set('p:' + key, value); },
  secureGet: (key) => state.store.has('s:' + key) ? state.store.get('s:' + key) : '',
  secureSet: (key, value) => { if (value === '') { state.store.delete('s:' + key); } else { state.store.set('s:' + key, value); } },
  dataDir: () => '/data/storage/el2/base/haps/entry/files',
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


// AiTools 的运行时依赖桩：书架/详情/笔记/历史全部可编程，不落真实服务
writeFileSync(join(dir, 'aiToolsDeps.ts'), `
export const toolsState = {
  search: null, detail: null, notes: [], notesError: '', history: [],
  sonovelEnvelope: null, tasks: [], processed: 0,
  booklistCreateResult: null, booklistAddResult: null, booklistCreateCalls: [], booklistAddCalls: [],
  bookDetailAsync: null, editCalls: [], editResult: null, bookNavAsync: null,
  referBooks: null, referSearchCalls: [], applyReferCalls: [], applyReferResult: null,
  // add_to_shelf 用：登录态、配额检查可用性/结果、内存目录、talebook 入队记录
  authOk: true, quotaSupported: true, quotaResult: null, dirs: new Set(), talebookEnqueues: [],
  // 书单管理/推送/统计工具用：可编程响应 + 调用记录
  myBooklists: null, booklistDetail: null, booklistUpdateCalls: [], booklistDeleteCalls: [],
  booklistRemoveCalls: [], pushResult: null, pushCalls: [], devices: null,
  readingStats: null, currentReading: null,
  // 一次性抛错开关：非空则下一次调用抛该消息并自动复位（工具失败处理用例用）
  searchThrowOnce: '', createThrowOnce: '',
};
export const BookDetail = undefined;
export const ServerFeature = { DOWNLOAD_QUOTA: 'download_quota' };
export const ServerRegistry = {
  supports: (f) => (f === 'download_quota' ? toolsState.quotaSupported : true),
};
export const AccountManager = { booksDir: (dir) => dir + '/books' };
export const fs = {
  accessSync: (p) => toolsState.dirs.has(p),
  mkdirSync: (p) => { toolsState.dirs.add(p); },
};
export const fileIo = fs;
// 仅作类型标注用的名字（strip-types 后仍走值 import），占位防命名导出缺失
export const SoNovelBookPayload = undefined;
export const DownloadTask = undefined;
export const SoNovelSearchItem = undefined;
export const BookListAddResponse = undefined;
export const BookListMutationResponse = undefined;
export const BookListDetailResponse = undefined;
export const BookListUpdatePayload = undefined;
export const BookListsResponse = undefined;
export const ApiMessageResult = undefined;
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
  // 与真实实现同语义：同 bookId+format 的 pending/downloading 任务原样返回，不重复入队
  enqueueTalebook: (payload) => {
    toolsState.talebookEnqueues.push(payload);
    const dup = toolsState.tasks.find((t) => t.kind === 'talebook' && t.talebookPayload !== undefined &&
      t.talebookPayload.bookId === payload.bookId &&
      t.talebookPayload.format.toLowerCase() === payload.format.toLowerCase() &&
      (t.status === 'pending' || t.status === 'downloading'));
    if (dup !== undefined) { return dup; }
    const task = { id: 'tb' + (toolsState.tasks.length + 1), kind: 'talebook', title: payload.bookName,
      author: payload.author, sourceName: 'Talebook', status: 'pending', error: '', filePath: '',
      format: payload.format.toUpperCase(), bookId: String(payload.bookId), progress: 0, message: '等待中',
      createdAt: 0, updatedAt: 0, talebookPayload: payload };
    toolsState.tasks.push(task);
    return task;
  },
};
export const BookListApi = {
  createBooklist: async (name, description, color, isPublic) => {
    toolsState.booklistCreateCalls.push({ name, description, color, isPublic });
    if (toolsState.createThrowOnce.length > 0) {
      const e = toolsState.createThrowOnce; toolsState.createThrowOnce = ''; throw new Error(e);
    }
    return toolsState.booklistCreateResult ?? { err: 'ok', booklist: { id: 77 } };
  },
  addBooks: async (id, ids) => {
    toolsState.booklistAddCalls.push({ id, ids });
    return toolsState.booklistAddResult ?? { err: 'ok', added: ids.length, book_count: ids.length };
  },
  getMyBooklists: async () => toolsState.myBooklists ?? { err: 'ok', booklists: [] },
  getBooklistDetail: async (id) => (toolsState.booklistDetail !== null && toolsState.booklistDetail[id] !== undefined
    ? { err: 'ok', booklist: toolsState.booklistDetail[id] } : { err: 'notfound', msg: '书单不存在' }),
  updateBooklist: async (id, payload) => {
    toolsState.booklistUpdateCalls.push({ id, payload });
    return toolsState.booklistUpdateResult ?? { err: 'ok' };
  },
  deleteBooklist: async (id) => {
    toolsState.booklistDeleteCalls.push(id);
    return { err: 'ok' };
  },
  removeBook: async (id, bookId) => {
    toolsState.booklistRemoveCalls.push({ id, bookId });
    return { err: 'ok' };
  },
};
export const TalebookApi = {
  search: async (q) => {
    if (toolsState.searchThrowOnce.length > 0) {
      const e = toolsState.searchThrowOnce; toolsState.searchThrowOnce = ''; throw new Error(e);
    }
    return toolsState.search ? await toolsState.search(q) : [];
  },
  getBookDetail: async (id) => (toolsState.detail ? await toolsState.detail(id) : null),
  searchRefer: async (id, opts) => {
    toolsState.referSearchCalls.push({ id, opts });
    return { books: toolsState.referBooks ?? [] };
  },
  applyRefer: async (id, entry, onlyMeta, onlyCover) => {
    toolsState.applyReferCalls.push({ id, entry, onlyMeta, onlyCover });
    return toolsState.applyReferResult ?? { err: 'ok' };
  },
  getDownloadQuota: async () => toolsState.quotaResult ?? {},
  getUserDevices: async () => toolsState.devices ?? [],
  sendToDevice: async (bookId, type, url, mailbox, ftpUser, ftpPass, ftpPath) => {
    toolsState.pushCalls.push({ bookId, type, url, mailbox });
    return toolsState.pushResult ?? { err: 'ok', msg: '推送成功' };
  },
  getReadingStats: async () => toolsState.readingStats,
  getCurrentReadingBooks: async () => toolsState.currentReading ?? [],
};
export const ReferBook = undefined;
export const ReferSearchOpts = undefined;
export const ReferSearchResponse = undefined;
export const TalebookService = {
  getReadingHistory: () => toolsState.history.slice(),
  ensureAuthenticated: async () => toolsState.authOk,
  resolveCoverUrl: (c) => (c.length === 0 ? '' : c.startsWith('http') ? c : 'https://stub.example' + (c.startsWith('/') ? c : '/' + c)),
  dataDir: () => '/stub-files',
  getBookDetailAsync: async (id) => (toolsState.bookDetailAsync
    ? await toolsState.bookDetailAsync(id) : { status: 404, body: null, error: 'stub: 未设置' }),
  editBookAsync: async (id, payload) => {
    toolsState.editCalls.push({ id, payload });
    return toolsState.editResult ?? { status: 200, body: { err: 'ok' }, error: '' };
  },
  getBookNavCachedAsync: async () => (toolsState.bookNavAsync
    ? await toolsState.bookNavAsync() : { status: 200, body: null, error: 'stub: 未设置' }),
};
// TalebookApi 拆分域类：与门面共用同一桩对象（toolsState 可编程性不分家）
export const TalebookApiBooks = TalebookApi;
export const TalebookApiAdmin = TalebookApi;
export const TalebookApiToolbox = TalebookApi;
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
}
export const cases = [];
export const test = (name, run) => cases.push({ name, run });
export const deferred = () => {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
};
export const tick = () => new Promise((resolve) => setImmediate(resolve));
// 工具回路是多轮 await，微任务队列跑干净需要连续 tick
export const flush = async () => { for (let i = 0; i < 96; i++) await tick(); };
export const enc = (s) => { const b = Buffer.from(s, 'utf8'); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); };
export const rtB64 = (bytes) => Buffer.from(bytes).toString('base64');
export async function setup() {
  stagePure('BookModels', 'services/BookModels.ets', []);
  stagePure('BookListModels', 'models/BookListModels.ets', []);
  stagePure('DeviceModels', 'models/DeviceModels.ets', []);
  stagePure('HomeModels', 'models/HomeModels.ets', []);
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
  stageEncyclopedia();
  stageWebFetch();
  stageMcp();
  stageQwenAudio();
  stageReader3();
  stageAiTools();
  stageAiVoiceKit();
  const load = async (name) => {
    try {
      return await import(pathToFileURL(join(dir, `${name}.ts`)).href);
    } catch (e) {
      console.log('LOAD FAIL', name, String(e).slice(0, 300));
      throw e;
    }
  };
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
  const { AiTools: RealAiTools } = await load('RealAiTools');
  const { parseToolBookLines } = await load('AiToolsDefs');
  const { toolsState } = await load('aiToolsDeps');
  const { mdParseBlocks, mdParseInline, collectLinks, linkHost } = await load('MdParse');
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
    // #1508 acceptBookParams 直读路由参数：AppRouter shim 忽略 ui 实参，桩空对象即可
    page.getUIContext = () => ({});
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
    page.getUIContext = () => ({});
    page.aboutToAppear();
    return page;
  };
  return { load, deps, RealAiService, RealAiTools, parseToolBookLines, toolsState, mdParseBlocks, mdParseInline, collectLinks, linkHost, AI_SKILLS, AiAssistantPage, AiBookPanelPage, AiRecommendPage, AiSettingsPage, AiPersonaPage, AiPersona, DEFAULT_SOUL, AiChatStore, personaState, MetaSearchService, NovelMetaService, resetSettings, settingsPage, chat, reappear };
}

