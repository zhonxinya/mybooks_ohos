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
  voiceProviderId: '', voiceModel: '', voiceConfig: null, lastCompleteConfig: null, lastCompleteMessages: null,
  speakEngine: 'system', speakCalls: [], speakStops: 0, callMode: 'realtime',
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
// bindMenu 构造器（权限/模型菜单）运行时引用 $r 取资源；测试不渲染，桩成资源名即可
globalThis.$r = (name) => name;
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
  loadVoiceConfig: () => {
    if (state.settings.voiceProviderId.length > 0) {
      const p = state.settings.providers.find((x) => x.id === state.settings.voiceProviderId);
      if (p !== undefined && p.id !== state.settings.config.providerId) {
        return { providerId: p.id, baseUrl: p.baseUrl,
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
export const state = { store: new Map(), models: [], rcpResponse: null, rcpResponses: [], rcpThrowQueue: [], rcpError: null, lastRequest: null, requests: [], chatCalls: [], chatStreamRounds: null, chatResponse: null, chatResponses: [], sourceJson: null, written: [], ttsFiles: [], lastOpenedPath: '' };
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
        try { options.onData(chunks); } catch (e) { console.log('FEEDERR', e.message); }
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
  resolveCoverUrl: (c) => (c.startsWith('http') ? c : 'https://stub.example/' + c),
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

/** EncyclopediaService 真实入检：rcp/util 复用 aiServiceDeps 桩（双通道都走 fetchText）。 */
function stageEncyclopedia() {
  let source = read('services/EncyclopediaService.ets');
  source = source
    .replace(`from '@kit.RemoteCommunicationKit'`, `from './aiServiceDeps.ts'`)
    .replace(`from '@kit.ArkTS'`, `from './aiServiceDeps.ts'`);
  writeFileSync(join(dir, 'RealEncyclopedia.ts'), source);
}

/** QwenAudioService 真实入检：rcp/fs/存储复用 aiServiceDeps 桩；audio/media 空壳（不测录音/播放）。 */
function stageQwenAudio() {
  let source = read('services/QwenAudioService.ets');
  source = source
    .replace(`from '@kit.RemoteCommunicationKit'`, `from './aiServiceDeps.ts'`)
    .replace(`from '@kit.ArkTS'`, `from './aiServiceDeps.ts'`)
    .replace(`from '@kit.AudioKit'`, `from './aiServiceDeps.ts'`)
    .replace(`from '@kit.MediaKit'`, `from './aiServiceDeps.ts'`)
    .replace(`from '@kit.CoreFileKit'`, `from './aiServiceDeps.ts'`)
    .replace(`from '@kit.PerformanceAnalysisKit'`, `from './aiServiceDeps.ts'`)
    .replace(`from '@kit.BasicServicesKit'`, `from './aiServiceDeps.ts'`)
    .replace(`from './TalebookService'`, `from './aiServiceDeps.ts'`)
    .replace(`from './AiService'`, `from './RealAiService.ts'`);
  writeFileSync(join(dir, 'RealQwenAudio.ts'), source);
  // SpeakService 真实入检：ReaderTtsService 用可编程桩（失败注入/完成回调手动触发）
  writeFileSync(join(dir, 'readerTtsDeps.ts'), [
    'export const ttsState = { starts: [], stops: 0, failEngine: false };',
    'export class ReaderTtsService {',
    '  err = null;',
    '  setCallbacks(_a, b, _c) { this.err = b; }',
    '  async start(chunks, speed, onDone) {',
    '    ttsState.starts.push({ chunks: chunks, onDone: onDone });',
    '    if (ttsState.failEngine) {',
    "      if (this.err !== null) { this.err('Creating the engine timed out'); }",
    '      return false;',
    '    }',
    '    return true;',
    '  }',
    '  stop() { ttsState.stops++; }',
    '}',
    '',
  ].join('\n'));
  let speak = read('services/SpeakService.ets');
  speak = speak
    .replace(`from './AiService'`, `from './RealAiService.ts'`)
    .replace(`from './QwenAudioService'`, `from './RealQwenAudio.ts'`)
    .replace(`from './ReaderTtsService'`, `from './readerTtsDeps.ts'`);
  writeFileSync(join(dir, 'RealSpeakService.ts'), speak);
  // RealtimeCallService 真实入检：webSocket/capturer/renderer/base64 全可编程桩
  writeFileSync(join(dir, 'realtimeDeps.ts'), [
    'export const rtState = { sends: [], lastUrl: "", lastOptions: null, socket: null, capturer: null, renderer: null };',
    'class FakeSocket {',
    '  constructor() { rtState.socket = this; this.handlers = {}; }',
    '  on(type, cb) { this.handlers[type] = cb; }',
    '  off(type) { delete this.handlers[type]; }',
    '  connect(url, options, cb) { rtState.lastUrl = url; rtState.lastOptions = options; this.connectCb = cb; }',
    '  send(data, cb) { rtState.sends.push(data); if (cb !== undefined) { cb(null); } }',
    '  close(cb) { this.closedFlag = true; if (cb !== undefined) { cb(null); } }',
    '  fireOpen() { if (this.connectCb !== undefined) { this.connectCb(null); } }',
    '  emitEvent(text) { if (this.handlers.message !== undefined) { this.handlers.message(null, text); } }',
    '}',
    'export const webSocket = { createWebSocket: () => new FakeSocket() };',
    'class FakeCapturer {',
    '  constructor() { rtState.capturer = this; this.events = {}; this.starts = 0; this.pauses = 0; }',
    '  on(type, cb) { this.events[type] = cb; }',
    '  async start() { this.starts++; return; }',
    '  async pause() { this.pauses++; return; }',
    '  async stop() { return; }',
    '  async release() { return; }',
    '  feedMic(bytes) { if (this.events.readData !== undefined) { this.events.readData(bytes.buffer); } }',
    '}',
    'class FakeRenderer {',
    '  constructor() { rtState.renderer = this; this.events = {}; }',
    '  on(type, cb) { this.events[type] = cb; }',
    '  async start() { return; }',
    '  async stop() { return; }',
    '  async release() { return; }',
    '  pull(arrayBuffer) { if (this.events.writeData !== undefined) { this.events.writeData(arrayBuffer); } }',
    '}',
    'export const audio = {',
    '  AudioSamplingRate: { SAMPLE_RATE_16000: 16000, SAMPLE_RATE_24000: 24000 },',
    '  AudioChannel: { CHANNEL_1: 1 },',
    '  AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 },',
    '  AudioEncodingType: { ENCODING_TYPE_RAW: 0 },',
    '  SourceType: { SOURCE_TYPE_VOICE_COMMUNICATION: 5 },',
    '  StreamUsage: { STREAM_USAGE_VOICE_COMMUNICATION: 7 },',
    '  createAudioCapturer: async () => new FakeCapturer(),',
    '  createAudioRenderer: async () => new FakeRenderer(),',
    '};',
    'export const util = {',
    '  Base64Helper: class {',
    '    encodeToStringSync(u8) { return btoa(String.fromCharCode.apply(null, Array.from(u8))); }',
    '    decodeSync(s) { const bin = atob(s); const out = new Uint8Array(bin.length);',
    '      for (let i = 0; i < bin.length; i++) { out[i] = bin.charCodeAt(i); } return out; }',
    '  },',
    '  TextDecoder: { create: () => ({ decodeToString: (u8) => new TextDecoder().decode(u8) }) },',
    '};',
    'export const hilog = { info: () => {}, warn: () => {}, error: () => {} };',
    'export class BusinessError extends Error {}',
    '',
  ].join('\n'));
  let rt = read('services/RealtimeCallService.ets');
  rt = rt
    .replace(`from '@kit.NetworkKit'`, `from './realtimeDeps.ts'`)
    .replace(`from '@kit.ArkTS'`, `from './realtimeDeps.ts'`)
    .replace(`from '@kit.AudioKit'`, `from './realtimeDeps.ts'`)
    .replace(`from '@kit.PerformanceAnalysisKit'`, `from './realtimeDeps.ts'`)
    .replace(`from '@kit.BasicServicesKit'`, `from './realtimeDeps.ts'`)
    .replace(`from './AiService'`, `from './RealAiService.ts'`);
  writeFileSync(join(dir, 'RealtimeCall.ts'), rt);
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
    .replace(`import { EncyclopediaHit, EncyclopediaService, WebSearchHit, WebSearchResult } from './EncyclopediaService';`,
      `import { EncyclopediaService } from './RealEncyclopedia.ts';`)
    .replace(`from './AiPersona'`, `from './RealAiPersona.ts'`)
    .replace(`from './TalebookApi'`, `from './aiToolsDeps.ts'`)
    .replace(`from './AnnotationApi'`, `from './aiToolsDeps.ts'`)
    .replace(`from './TalebookService'`, `from './aiToolsDeps.ts'`)
    .replace(`from './SoNovelService'`, `from './aiToolsDeps.ts'`)
    .replace(`from '../utils/SoNovelMerge'`, `from './aiToolsDeps.ts'`)
    .replace(`from './DownloadTaskService'`, `from './aiToolsDeps.ts'`)
    .replace(`from './BookListApi'`, `from './aiToolsDeps.ts'`)
    .replace(`from './BookModels'`, `from './aiToolsDeps.ts'`)
    .replace(`from './ServerProfile'`, `from './aiToolsDeps.ts'`)
    .replace(`from './AccountManager'`, `from './aiToolsDeps.ts'`)
    .replace(`from '@kit.CoreFileKit'`, `from './aiToolsDeps.ts'`)
    .replace(`import { BookListSummary, parseBookListSummary, parseBookListSummaries } from '../models/BookListModels';`,
      `import type { BookListSummary } from './BookListModels.ts';\nimport { parseBookListSummary, parseBookListSummaries } from './BookListModels.ts';`)
    .replace(`import { ReadingDevice, deviceTypeLabel } from '../models/DeviceModels';`,
      `import type { ReadingDevice } from './DeviceModels.ts';\nimport { deviceTypeLabel } from './DeviceModels.ts';`)
    .replace(`import { HomeBook, ReadingStatsSummary } from '../models/HomeModels';`,
      `import type { HomeBook, ReadingStatsSummary } from './HomeModels.ts';`);
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
        'promptAction', 'SymbolGlyphModifier', 'QwenAudioService', 'SpeakService'].includes(name)) {
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
const flush = async () => { for (let i = 0; i < 96; i++) await tick(); };
const enc = (s) => { const b = Buffer.from(s, 'utf8'); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); };
const rtB64 = (bytes) => Buffer.from(bytes).toString('base64');

try {
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
  stageQwenAudio();
  stageReader3();
  stageAiTools();
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
      deps.state.chatCalls[0].body.tools.length === 27, 'SDK 通道请求体须挂全量 tools');
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
    // so-novel 下载在服务器（云端）执行，完成后应用拉取落架——文案两头都要说准
    assert.ok(t.includes('已加入云端下载任务') && t.includes('格式 epub') &&
      t.includes('下载与转换在服务器进行') && t.includes('自动拉取到本地书架'), t);
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
    assert.ok(Array.isArray(b1.tools) && b1.tools.length === 27 && b1.tools[0].function.name === 'search_books');
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
    // ② 上限轮模型带正文+幻觉 tool_calls → 软着陆返回部分成果，不报废整条回复
    deps.state.requests.length = 0;
    deps.state.rcpResponses = [...Array(12).fill(0).map(mk),
      { statusCode: 200, body: enc(JSON.stringify({ choices: [{ message: { content: '已查到部分内容。',
        tool_calls: [{ id: 'y', type: 'function', function: { name: 'search_books', arguments: '{"query":"q"}' } }] } }] })) }];
    error = '';
    full = '';
    RealAiService.chatStream([{ role: 'user', content: '无限查' }], {
      onDelta: (t) => { full += t; }, onDone: () => {}, onError: (m) => { error = m; },
    }, 256);
    await flush();
    assert.equal(error, '', '上限轮有正文不得报错');
    assert.ok(full.includes('已查到部分内容。') && full.includes('12 轮上限'), full);
    // ③ 上限轮纯工具无正文 → 仍按旧语义报错（没有可交付内容）
    deps.state.requests.length = 0;
    deps.state.rcpResponses = [...Array(13).fill(0).map(mk)];
    error = '';
    RealAiService.chatStream([{ role: 'user', content: '光查不说' }], {
      onDelta: () => {}, onDone: () => {}, onError: (m) => { error = m; },
    }, 256);
    await flush();
    assert.match(error, /达到上限/, '无正文时仍提示达到上限');
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
    assert.equal(RealAiTools.definitions().length, 27);
    assert.equal(RealAiTools.definitions('confirm').length, 27);
    assert.equal(RealAiTools.definitions('auto').length, 27);
    const ro = RealAiTools.definitions('readonly');
    assert.equal(ro.length, 15);
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
    assert.equal(b1.tools.length, 15);
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
    assert.equal(b1.tools.length, 27, 'auto 模式写工具须在 tools 里');
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

  test('update_book_meta：读-合并-写，只覆盖点名字段；空改动与失败路径', async () => {
    toolsState.bookDetailAsync = async () => ({ status: 200, body: { book: {
      title: '三体', authors: ['刘慈欣'], tags: ['科幻'], publisher: 'so-novel', comments: '旧简介',
      category: '科幻时空',
      isbn: '', series: '', languages: ['zh'], translators: [], series_index: 1, rating: null } } });
    toolsState.editCalls.length = 0;
    const out = await RealAiTools.execute('update_book_meta', '{"book_id":1481,"title":"三体（新版）"}');
    assert.ok(out.includes('已更新'), out);
    assert.ok(out.includes('「三体」→「三体（新版）」'));
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

  test('Reader3 导入校验：坏 JSON 带开头片段 / 无 bookSourceUrl 对象 / 全无效 → 抛错不落盘；单书源对象可导入', async () => {
    const { Reader3Native } = await load('RealReader3');
    const before = deps.state.written.length;
    await assert.rejects(() => Reader3Native.importFromText('这不是JSON'), /不是有效的 JSON（开头：这不是JSON/);
    // URL 指到网页（书源站常见坑）：报错须能看出拿到的是 HTML
    await assert.rejects(() => Reader3Native.importFromText('<html><body>404</body></html>'), /开头：<html/);
    await assert.rejects(() => Reader3Native.importFromText('{"foo":1}'), /格式不支持/);
    await assert.rejects(() => Reader3Native.importFromText('[]'), /未解析到有效书源/);
    assert.strictEqual(deps.state.written.length, before, '失败导入不得写盘');
    // 单个书源对象（Legado 单本分享形态）= 1 条导入成功
    Reader3Native.loaded = false;
    assert.strictEqual(await Reader3Native.importFromText('{"bookSourceUrl":"https://one.example","bookSourceName":"单源"}'), 1);
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

  test('百科工具：SERP 百科卡解析、维基 snippet 去标签、通道独立容错与聚合文案', async () => {
    const { EncyclopediaService } = await load('RealEncyclopedia');
    deps.state.rcpThrowQueue.length = 0;
    deps.state.rcpError = null;
    const serp = '<html><body><script>x</script>' +
      '{"tools":{"title":"刘慈欣","url":"https://baike.baidu.com/item/%E5%88%98%E6%85%88%E6%AC%A3/142084"},' +
      '"source":"百度百科","baikeid":"142084","abstract":"刘慈欣,男,汉族,1963年生,高级工程师、科幻作家。"}' +
      '</body></html>';
    const wikiJson = JSON.stringify({ query: { search: [
      { title: '刘慈欣', snippet: '<b>刘慈欣</b>，1963年生中国科幻作家' }] } });
    // 1 百度百科卡
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(serp) }];
    let bk = await EncyclopediaService.searchBaike('刘慈欣');
    assert.ok(bk.ok && bk.title === '刘慈欣' && bk.abstract.includes('汉族') && bk.url.includes('baike.baidu.com'), JSON.stringify(bk));
    // 2 无百科卡 → 明确文案
    deps.state.rcpResponses = [{ statusCode: 200, body: enc('<html>no card</html>') }];
    bk = await EncyclopediaService.searchBaike('不存在的词');
    assert.ok(!bk.ok && bk.error.includes('没有百科词条'), bk.error);
    // 3 item 级拦截（403）转 ok=false 不外抛
    deps.state.rcpResponses = [{ statusCode: 403, body: enc('verify') }];
    bk = await EncyclopediaService.searchBaike('x');
    assert.ok(!bk.ok && bk.error.includes('403'), bk.error);
    // 4 维基 snippet 去标签 + 词条链接
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(wikiJson) }];
    const wk = await EncyclopediaService.searchWikipedia('刘慈欣');
    assert.ok(wk.ok && !wk.abstract.includes('<b>') && wk.abstract.includes('科幻作家'), JSON.stringify(wk));
    assert.equal(wk.url, 'https://zh.wikipedia.org/wiki/%E5%88%98%E6%85%88%E6%AC%A3');
    // 5 工具聚合：双通道都有
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(serp) }, { statusCode: 200, body: enc(wikiJson) }];
    let out = await RealAiTools.execute('search_encyclopedia', '{"query":"刘慈欣"}');
    assert.ok(out.includes('【百度百科】刘慈欣') && out.includes('【维基百科】刘慈欣') && out.includes('链接：'), out);
    // 6 维基不可达（被墙 403）仍给百度结果并如实标注
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(serp) }, { statusCode: 403, body: enc('blocked') }];
    out = await RealAiTools.execute('search_encyclopedia', '{"query":"刘慈欣"}');
    assert.ok(out.includes('【百度百科】刘慈欣') && out.includes('【维基百科】未获取到'), out);
    // 7 双通道全挂 → 汇总失败文案（不抛错，不触发无意义重试）
    deps.state.rcpResponses = [{ statusCode: 503, body: enc('down') }, { statusCode: 503, body: enc('down') }];
    out = await RealAiTools.execute('search_encyclopedia', '{"query":"x"}');
    assert.ok(out.includes('百科检索失败') && out.includes('503'), out);
    // 8 无 tools 卡时 fallback：纯词/整句 SERP 的 AI 问答卡引用项形态（板上真实踩坑）
    const serpCite = '<html><script>var x=1;</script>' +
      '{"url_no":2,"url":"https://baike.baidu.com/item/%E5%88%98%E6%85%88%E6%AC%A3/142084",' +
      '"text":"刘慈欣-高级工程师、科幻作家","source":"百度百科","publish_time":0,"icon":"https://i.png",' +
      '"abstract":"刘慈欣,男,汉族,1963年6月23日出生于北京,祖籍河南,高级工程师、科幻作家。"}' +
      '</html>';
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(serpCite) }];
    bk = await EncyclopediaService.searchBaike('刘慈欣是谁');
    assert.ok(bk.ok && bk.title === '刘慈欣-高级工程师、科幻作家' &&
      bk.abstract.includes('1963年') && bk.url.includes('baike.baidu.com'), JSON.stringify(bk));
    // 9 cite 形态但 abstract 距 source 超窗口 → 不误取无关摘要
    const serpFar = '<html>{"url":"https://baike.baidu.com/item/a","text":"词条","source":"百度百科"}' +
      'x'.repeat(1000) + '{"abstract":"太远的摘要不应该被取到内容内容内容。"}</html>';
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(serpFar) }];
    bk = await EncyclopediaService.searchBaike('y');
    assert.ok(!bk.ok && bk.error.includes('没有百科词条'), bk.error);
    deps.state.rcpError = null;
  });

  test('search_web：三引擎聚合（百度/Bing/360 解析、跨引擎去重、单通道失败降级）与容错', async () => {
    const { EncyclopediaService } = await load('RealEncyclopedia');
    deps.state.rcpThrowQueue.length = 0;
    deps.state.rcpError = null;
    // 百度结构取自 2026-11-21 真实 SERP 样本（c-container/mu/s-text/summary-text_<hash>）；
    // Bing=b_algo+h2 直链+b_lineclamp；360=res-list+h3 直链+res-list-summary
    const baiduHtml = '<html><body>' +
      '<div class="result c-container" mu="http://28616.recommend_list.baidu.com"' +
      '><h3><a><!--s-text-->榜单推广位<!--/s-text--></a></h3></div>' +
      '<div class="result c-container xpath-log new-pmd" mu="https://www.qidian.com/book/123">' +
      '<h3 class="cosc-title"><a><!--s-text--><em>三体</em>全集在线阅读-起点中文网<!--/s-text--></a></h3>' +
      '<span class="    summary-text_15QGa">《三体》表达了对宇宙的<em>敬畏</em>与想象。</span></div>' +
      '<div class="result c-container" mu="https://fanqienovel.com/page/698">' +
      '<h3><a><!--s-text-->三体全集免费阅读_番茄小说官网<!--/s-text--></a></h3></div>' +
      '<div class="result c-container" mu="https://baike.baidu.com/item/三体">' +
      '<h3><a>三体（长篇小说）</a></h3>' +
      '<span class="summary-text_9AbCd">《三体》是刘慈欣创作的长篇科幻小说。</span></div>' +
      '</body></html>';
    const bingHtml = '<ol id="b_results">' +
      '<li class="b_algo"><h2><a href="https://weread.qq.com/web/reader/ce03">三体全集免费阅读_番茄小说官网</a></h2>' +
      '<div class="b_caption"><p class="b_lineclamp2">2021年10月16日&#183;《三体》系列长篇。</p></div></li>' +
      '<li class="b_algo"><h2><a href="https://baike.baidu.com/item/%E4%B8%89%E4%BD%93/5739303">三体（刘慈欣创作的系列小说）_百度百科</a></h2>' +
      '<div class="b_caption"><p class="b_lineclamp2">雨果奖获奖作品。<a href="#">阅读更多</a>阅读更多</p></div></li>' +
      '</ol>';
    const so360Html = '<ul>' +
      '<li class="res-list"><h3><a href="https://www.so.com/link?m=abc">三体txt下载-青果书库</a></h3>' +
      '<p class="res-desc"><span class="res-list-summary" data-result-summary>《三体》<em>系列</em>作品介绍。</span></p></li>' +
      '<li class="res-list"><h3><a href="https://baike.so.com/doc/5330779">三体_360百科</a></h3></li>' +
      '</ul>';
    // 并发发起顺序 baidu→bing→360，rcpResponses 按序消费
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc(baiduHtml) },
      { statusCode: 200, body: enc(bingHtml) },
      { statusCode: 200, body: enc(so360Html) },
    ];
    const r = await EncyclopediaService.searchWeb('三体 小说');
    assert.ok(r.ok, r.error);
    assert.equal(r.items.length, 6, '3+2+1（Bing 首条与百度同名题去重）');
    assert.equal(r.items[0].source, '百度');
    assert.equal(r.items[0].title, '三体全集在线阅读-起点中文网', 'stripHtml 去标签不补空格（项目语义）');
    assert.equal(r.items[0].url, 'https://www.qidian.com/book/123');
    assert.ok(r.items[0].summary.includes('敬畏') && !r.items[0].summary.includes('<em>'), r.items[0].summary);
    assert.equal(r.items[1].summary, '', '纯标题卡片保留、摘要为空');
    assert.equal(r.items[2].title, '三体（长篇小说）', '无 s-text 时 h3 兜底');
    assert.equal(r.items[3].source, 'Bing', '去重后 Bing 第二条顶上');
    assert.ok(r.items[3].summary.includes('雨果奖') && !r.items[3].summary.endsWith('阅读更多'), r.items[3].summary);
    assert.equal(r.items[4].source, '360');
    assert.ok(r.items[4].summary.includes('系列'), r.items[4].summary);
    // 单通道非 2xx：跳过该引擎，其余照常
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc(baiduHtml) },
      { statusCode: 567, body: enc('rate limit') },
      { statusCode: 200, body: enc(so360Html) },
    ];
    const partial = await EncyclopediaService.searchWeb('三体');
    assert.ok(partial.ok && partial.items.every((x) => x.source !== 'Bing'), 'Bing 失败不影响整体');
    // 三通道全空 → 统一失败文案，不抛错
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc('<html>waf</html>') },
      { statusCode: 200, body: enc('<html>waf</html>') },
      { statusCode: 200, body: enc('<html>waf</html>') },
    ];
    const empty = await EncyclopediaService.searchWeb('不存在的东西');
    assert.ok(!empty.ok && empty.error.includes('均无结果'), empty.error);
    // 工具层：编号文案带来源标签，摘要缺省不占行
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc(baiduHtml) },
      { statusCode: 200, body: enc(bingHtml) },
      { statusCode: 200, body: enc(so360Html) },
    ];
    const out = await RealAiTools.execute('search_web', '{"query":"三体"}');
    assert.ok(out.includes('1. [百度] 三体全集在线阅读-起点中文网') &&
      out.includes('链接：https://www.qidian.com/book/123') &&
      out.includes('2. [百度] 三体全集免费阅读_番茄小说官网') &&
      out.includes('4. [Bing] 三体（刘慈欣创作的系列小说）_百度百科'), out);
    assert.ok(out.indexOf('2. [百度] 三体全集免费阅读_番茄小说官网\n链接：https://fanqienovel.com/page/698\n\n3') > 0,
      '第二条无摘要：链接行后空行接第三条');
    // 空 query 直接回文案
    const none = await RealAiTools.execute('search_web', '{"query":"  "}');
    assert.ok(none.includes('query 为空'), none);
    deps.state.rcpError = null;
  });

  test('对话页模型快切：徽标跟配置、菜单勾选+刷新、部分保存只动 model、失败退化重试', async () => {
    resetSettings(); // 前序语音用例把 config 改到 glm-4v，这里从默认配置起算
    const page = chat();
    state.settings.models = ['glm-4', 'glm-4-plus', 'deepseek-chat'];
    state.settings.fetchError = '';
    page.modelChoices = [];
    page.onPageShow();
    await flush();
    assert.equal(page.currentModel, 'deepseek-chat', '徽标跟随全局配置');
    assert.equal(page.modelChipLabel(), 'deepseek-chat');
    assert.deepEqual(page.modelChoices, ['glm-4', 'glm-4-plus', 'deepseek-chat']);
    const items = page.modelMenuItems();
    assert.equal(items.length, 4, '3 模型 + 刷新项');
    assert.ok(items[2].symbolIcon !== undefined, '当前模型带勾');
    assert.ok(items[0].symbolIcon === undefined);
    // 切换：部分保存原样回填 model 之外字段，apiKey 传空不覆盖已存 Key
    page.pickModel('glm-4-plus');
    const saved = state.settings.saved;
    assert.equal(saved.model, 'glm-4-plus');
    assert.equal(saved.apiKey, '', '部分保存不带 Key');
    assert.equal(saved.baseUrl, 'https://api.deepseek.com/v1');
    assert.equal(saved.contextLength, 8, '上下文档位等其他字段透传');
    assert.equal(page.currentModel, 'glm-4-plus');
    assert.equal(state.settings.config.model, 'glm-4-plus', '下一条消息即生效（配置已更新）');
    // 再点当前项不重复保存
    const savedBefore = state.settings.saved;
    page.pickModel('glm-4-plus');
    assert.equal(state.settings.saved, savedBefore, '同模型点击为 no-op');
    // 长名截断：切换后徽标 14 字 + 省略号
    page.pickModel('very-long-model-name-for-truncation-xyz');
    assert.equal(page.modelChipLabel(), 'very-long-mode…', '14 字 + 省略号');
    // 拉取失败：列表空、菜单退化为单个获取项，徽标仍显当前模型
    state.settings.fetchError = '服务商不支持模型列表';
    page.modelChoices = [];
    page.onPageShow();
    await flush();
    assert.deepEqual(page.modelChoices, []);
    const retry = page.modelMenuItems();
    assert.equal(retry.length, 1);
    assert.ok(retry[0].value.includes('获取模型列表'), retry[0].value);
    assert.equal(page.modelChipLabel(), 'very-long-mode…');
    state.settings.fetchError = '';
  });

  test('Token Plan 音频链路：ASR/TTS 请求形态、缓存清理与未配 Key 容错', async () => {
    const { QwenAudioService } = await load('RealQwenAudio');
    deps.state.rcpResponses.length = 0;
    deps.state.rcpThrowQueue.length = 0;
    deps.state.rcpError = null;
    deps.state.requests.length = 0;
    deps.state.ttsFiles.length = 0;
    const prevProvider = deps.state.store.get('p:ai_provider');
    // 前面设置页用例会把 ai_base_url 落盘覆盖 preset；origin() 派生自它，必须先清
    const prevBaseUrl = deps.state.store.get('s:ai_base_url');
    deps.state.store.delete('s:ai_base_url');
    deps.state.store.set('p:ai_provider', 'qwen-tokenplan');
    deps.state.store.set('s:ai_api_key_qwen-tokenplan', 'sk-test');
    // ① ASR：DashScope 原生路径 + data URI 前缀 + output.text 解析
    deps.state.rcpResponses = [{ statusCode: 200, body: enc(JSON.stringify({ output: { text: '推荐一本科幻' } })) }];
    assert.equal(await QwenAudioService.transcribe('QUJDRA=='), '推荐一本科幻');
    const asrReq = deps.state.requests[0];
    assert.equal(asrReq.url, 'https://token-plan.maas.qianwenaiapi.com/api/v1/services/aigc/multimodal-generation/generation');
    assert.equal(asrReq.headers['Authorization'], 'Bearer sk-test');
    const asrBody = JSON.parse(asrReq.content);
    assert.equal(asrBody.model, 'qwen-audio-3.0-asr-flash');
    assert.ok(asrBody.input.messages[0].content[0].input_audio.data.startsWith('data:audio/wav;base64,QUJDRA=='));
    assert.equal(asrBody.parameters.format, 'wav');
    // ② 空录音直接返回空串，不发请求（「没听清」分支的前提）
    const reqCount = deps.state.requests.length;
    assert.equal(await QwenAudioService.transcribe(''), '');
    assert.equal(deps.state.requests.length, reqCount);
    // ③ TTS：合成→OSS 下载→落盘 /tts/，缓存只留最近 5 个（先种 5 个旧的）
    for (let i = 0; i < 5; i++) { deps.state.ttsFiles.push(`tts_00${i}.mp3`); }
    deps.state.rcpResponses = [
      { statusCode: 200, body: enc(JSON.stringify({ output: { audio: { url: 'https://oss.example/a.mp3?Expires=1' } } })) },
      { statusCode: 200, body: enc('MP3DATA') },
    ];
    const path = await QwenAudioService.synthesize('你好');
    assert.ok(path.includes('/tts/tts_') && path.endsWith('.mp3'), path);
    const ttsReq = deps.state.requests[deps.state.requests.length - 2];
    assert.equal(ttsReq.url, 'https://token-plan.maas.qianwenaiapi.com/api/v1/services/audio/tts/SpeechSynthesizer');
    const ttsBody = JSON.parse(ttsReq.content);
    assert.equal(ttsBody.model, 'qwen-audio-3.0-tts-plus');
    assert.equal(ttsBody.input.voice, 'longanhuan_v3.6');
    assert.equal(ttsBody.input.sample_rate, 22050);
    assert.equal(deps.state.rcpResponses.length, 0);
    assert.equal(deps.state.ttsFiles.length, 5);
    assert.ok(!deps.state.ttsFiles.includes('tts_000.mp3') && deps.state.ttsFiles.includes(path.slice(path.lastIndexOf('/') + 1)));
    // ④ 非 2xx 透传状态码与响应体片段
    deps.state.rcpResponses = [{ statusCode: 401, body: enc('{"code":"InvalidApiKey"}') }];
    await assert.rejects(() => QwenAudioService.transcribe('QUJD'), /HTTP 401: \{"code":"InvalidApiKey"\}/);
    // ⑤ 未配 Key：明确指向设置页，不带网络错误
    deps.state.store.delete('s:ai_api_key_qwen-tokenplan');
    await assert.rejects(() => QwenAudioService.synthesize('x'), /未配置 Token Plan API Key/);
    if (prevProvider === undefined) { deps.state.store.delete('p:ai_provider'); } else { deps.state.store.set('p:ai_provider', prevProvider); }
    if (prevBaseUrl !== undefined) { deps.state.store.set('s:ai_base_url', prevBaseUrl); }
    deps.state.requests.length = 0;
    deps.state.ttsFiles.length = 0;
  });

  test('语音通话对话模型：跟随全局/独立服务商解析/complete 按 override 出请求', async () => {
    deps.state.store.clear();
    RealAiService.saveConfig('deepseek', 'https://api.deepseek.com/v1', 'deepseek-chat', 'sk-d', 0.5);
    // ① 未单独配置 → 跟随全局
    assert.equal(RealAiService.loadVoiceConfig().providerId, 'deepseek');
    assert.equal(RealAiService.hasVoiceProvider(), false);
    // ② 独立选 Token Plan：地址随预设解析，Key 单独判
    RealAiService.saveVoiceConfig('qwen-tokenplan', 'qwen3.6-flash');
    let v = RealAiService.loadVoiceConfig();
    assert.equal(v.providerId, 'qwen-tokenplan');
    assert.equal(v.model, 'qwen3.6-flash');
    assert.equal(v.baseUrl, 'https://token-plan.maas.qianwenaiapi.com/compatible-mode/v1');
    assert.equal(v.hasKey, false);
    assert.equal(RealAiService.loadVoiceProviderId(), 'qwen-tokenplan');
    RealAiService.saveVoiceConfig('qwen-tokenplan', '');
    assert.equal(RealAiService.loadVoiceConfig().model, 'qwen3.6-flash', 'model 空回落服务商默认');
    deps.state.store.set('s:ai_api_key_qwen-tokenplan', 'sk-tp');
    assert.equal(RealAiService.loadVoiceConfig().hasKey, true);
    // ③ 选了与全局相同的服务商 → 直接跟随全局值（忽略语音 model）
    RealAiService.saveVoiceConfig('deepseek', 'other-model');
    assert.equal(RealAiService.loadVoiceConfig().model, 'deepseek-chat');
    // ④ complete 带 override：请求用语音配置的地址/模型/Key
    RealAiService.saveVoiceConfig('opencode', 'voice-model');
    deps.state.store.set('s:ai_api_key_opencode', 'sk-oc');
    deps.state.rcpResponse = { statusCode: 200,
      body: enc(JSON.stringify({ choices: [{ message: { content: '好的' } }] })) };
    assert.equal(await RealAiService.complete([{ role: 'user', content: 'hi' }], 512,
      RealAiService.loadVoiceConfig()), '好的');
    const req = deps.state.lastRequest;
    assert.ok(req.url.startsWith('https://opencode.ai/zen/go/v1'), req.url);
    assert.equal(JSON.parse(req.content).model, 'voice-model');
    assert.equal(req.headers['Authorization'], 'Bearer sk-oc');
    // ⑤ 恢复跟随全局
    RealAiService.saveVoiceConfig('', '');
    assert.equal(RealAiService.hasVoiceProvider(), false);
    assert.equal(RealAiService.loadVoiceConfig().providerId, 'deepseek');
    deps.state.rcpResponse = null;
    deps.state.store.delete('s:ai_api_key_qwen-tokenplan');
    deps.state.store.delete('s:ai_api_key_opencode');
    deps.state.store.delete('s:ai_base_url');
  });

  test('设置页语音通话模型：进入读取、切换即存、跟随恢复、模型列表', async () => {
    resetSettings();
    let page = settingsPage();
    assert.equal(page.voiceFollow, true);
    assert.equal(page.voiceProviderSelectedIndex(), 0);
    assert.equal(page.voiceProviderItems().length, 3, '跟随全局 + 2 个服务商');
    // 选服务商（index 2 = opencode）→ 立即持久化、重置模型
    page.selectVoiceProvider(2);
    assert.equal(page.voiceFollow, false);
    assert.equal(state.settings.voiceProviderId, 'opencode');
    assert.equal(state.settings.voiceModel, '');
    // 模型列表：未拉取时给服务商默认；手动值也会补进列表
    assert.ok(page.voiceModelItems().some((it) => it.value === 'big-pickle'));
    state.settings.models = ['voice-m'];
    await page.fetchVoiceModels();
    assert.deepEqual(page.voiceModelOptions, ['voice-m']);
    // 切回跟随全局 → 清空配置
    page.selectVoiceProvider(0);
    assert.equal(page.voiceFollow, true);
    assert.equal(state.settings.voiceProviderId, '');
    // 重进页面读回已存配置
    state.settings.voiceProviderId = 'opencode';
    state.settings.voiceModel = 'voice-m';
    page = settingsPage();
    assert.equal(page.voiceFollow, false);
    assert.equal(page.voiceModel, 'voice-m');
    assert.equal(page.voiceProviderSelectedIndex(), 2);
    assert.ok(page.voiceSummary().includes('OpenCode'));
    resetSettings();
  });

  test('SpeakService 播报引擎：默认系统、播完/打断/无引擎三态与开关持久化', async () => {
    const { SpeakService: RealSpeakService } = await load('RealSpeakService');
    const { ttsState } = await load('readerTtsDeps');
    deps.state.store.clear();
    // ① 默认走系统引擎
    assert.equal(RealAiService.loadSpeakEngine(), 'system');
    ttsState.starts.length = 0;
    ttsState.stops = 0;
    ttsState.failEngine = false;
    const p1 = RealSpeakService.speak('第一句');
    await flush();
    assert.equal(ttsState.starts.length, 1);
    assert.deepEqual(ttsState.starts[0].chunks, ['第一句']);
    ttsState.starts[0].onDone();
    assert.equal(await p1, true);
    // ② stop 打断：未播完的 speak 以 false 结束，系统引擎被停
    const p2 = RealSpeakService.speak('第二句');
    await flush();
    RealSpeakService.stop();
    assert.equal(await p2, false);
    assert.ok(ttsState.stops >= 1);
    // ③ 引擎不可用（模拟器 50008 场景）：抛人话错误供页面 toast
    ttsState.failEngine = true;
    await assert.rejects(() => RealSpeakService.speak('第三句'), /Creating the engine timed out/);
    // ④ 引擎开关持久化：非法值回落 system
    RealAiService.saveSpeakEngine('cloud');
    assert.equal(RealAiService.loadSpeakEngine(), 'cloud');
    RealAiService.saveSpeakEngine('bogus');
    assert.equal(RealAiService.loadSpeakEngine(), 'system');
    deps.state.store.delete('p:ai_speak_engine');
    ttsState.starts.length = 0;
    ttsState.stops = 0;
    ttsState.failEngine = false;
  });

  test('RealtimeCallService 全双工：握手形态、append 上行、VAD 打断清队列、拉流消费与字幕事件', async () => {
    const { RealtimeCallService: Rt } = await load('RealtimeCall');
    const { rtState } = await load('realtimeDeps');
    deps.state.store.clear();
    RealAiService.saveConfig('qwen-tokenplan', 'https://token-plan.maas.qianwenaiapi.com/compatible-mode/v1', 'qwen3.6-flash', 'sk-tp', 0.5);
    rtState.sends.length = 0;
    const ev = [];
    const cb = {
      onUserText: (t) => ev.push('user:' + t),
      onAiTextDelta: (d) => ev.push('delta:' + d),
      onAiTextDone: (t) => ev.push('done:' + t),
      onSpeechStarted: () => ev.push('barge'),
      onSpeechStopped: () => ev.push('stopped'),
      onResponding: () => ev.push('responding'),
      onResponseDone: () => ev.push('resp_done'),
      onFunctionCall: (n, a, c) => ev.push('call:' + n + ':' + c),
      onError: (m) => ev.push('err:' + m),
      onClosed: () => ev.push('closed'),
    };
    const connecting = Rt.connect('人设指令', cb, [
      { type: 'function', function: { name: 'search_books', parameters: { type: 'object', properties: {} } } },
    ]);
    await flush();
    assert.equal(rtState.lastUrl, 'wss://token-plan.maas.qianwenaiapi.com/api-ws/v1/realtime?model=qwen-audio-3.0-realtime-plus');
    assert.equal(rtState.lastOptions.header.Authorization, 'Bearer sk-tp');
    rtState.socket.fireOpen();
    await flush();
    rtState.socket.emitEvent(JSON.stringify({ type: 'session.created' }));
    await flush();
    // session.update 时序与字段（docs §4 实测协议）
    const update = JSON.parse(rtState.sends[0]);
    assert.equal(update.type, 'session.update');
    assert.equal(update.session.voice, 'longanqian');
    assert.equal(update.session.turn_detection.type, 'server_vad');
    assert.equal(update.session.input_audio_format, 'pcm');
    assert.equal(update.session.output_audio_format, 'pcm');
    assert.equal(update.session.instructions, '人设指令');
    assert.equal(update.session.tools[0].function.name, 'search_books');
    // 麦克风帧 → base64 append
    const mic = new Uint8Array(3200);
    mic[0] = 42;
    rtState.capturer.feedMic(mic);
    await flush();
    const append = JSON.parse(rtState.sends[1]);
    assert.equal(append.type, 'input_audio_buffer.append');
    assert.equal(Buffer.from(append.audio, 'base64').length, 3200);
    assert.equal(Buffer.from(append.audio, 'base64')[0], 42);
    // 下行音频入队并触发 speaking
    const pcm = new Uint8Array(4800).fill(7);
    rtState.socket.emitEvent(JSON.stringify({ type: 'response.audio.delta', delta: rtB64(pcm) }));
    await flush();
    assert.ok(ev.includes('responding'));
    assert.equal(Rt.getPlayBytes(), 4800);
    // 拉模式消费 1600B
    const buf = new ArrayBuffer(1600);
    rtState.renderer.pull(buf);
    assert.equal(Rt.getPlayBytes(), 3200);
    assert.equal(new Uint8Array(buf)[0], 7);
    // speech_started 打断：队列清零
    rtState.socket.emitEvent(JSON.stringify({ type: 'input_audio_buffer.speech_started' }));
    await flush();
    assert.equal(Rt.getPlayBytes(), 0);
    assert.ok(ev.includes('barge'));
    rtState.socket.emitEvent(JSON.stringify({ type: 'input_audio_buffer.speech_stopped' }));
    // 字幕与错误事件链
    rtState.socket.emitEvent(JSON.stringify({ type: 'conversation.item.input_audio_transcription.completed', transcript: '你好呀' }));
    rtState.socket.emitEvent(JSON.stringify({ type: 'response.audio_transcript.delta', delta: 'He' }));
    rtState.socket.emitEvent(JSON.stringify({ type: 'response.audio_transcript.delta', delta: 'llo' }));
    rtState.socket.emitEvent(JSON.stringify({ type: 'response.audio_transcript.done', transcript: 'Hello' }));
    rtState.socket.emitEvent(JSON.stringify({ type: 'response.done' }));
    rtState.socket.emitEvent(JSON.stringify({ type: 'error', error: { message: '示例错误' } }));
    await flush();
    assert.ok(ev.includes('stopped'));
    assert.ok(ev.includes('user:你好呀'));
    assert.ok(ev.includes('delta:He'));
    assert.ok(ev.includes('done:Hello'));
    assert.ok(ev.includes('resp_done'));
    assert.ok(ev.includes('err:示例错误'));
    // 工具回路：function_call → 回调执行 → output 回填 + response.create 续流
    const sendsBeforeCall = rtState.sends.length;
    rtState.socket.emitEvent(JSON.stringify({ type: 'response.function_call_arguments.done',
      call_id: 'c1', name: 'search_books', arguments: '{"query":"三体"}' }));
    await flush();
    assert.ok(ev.includes('call:search_books:c1'));
    Rt.sendToolResult('c1', '找到《三体》');
    await flush();
    assert.equal(rtState.sends.length, sendsBeforeCall + 2);
    const toolOut = JSON.parse(rtState.sends[sendsBeforeCall]);
    assert.equal(toolOut.item.type, 'function_call_output');
    assert.equal(toolOut.item.call_id, 'c1');
    assert.equal(toolOut.item.output, '找到《三体》');
    assert.equal(JSON.parse(rtState.sends[sendsBeforeCall + 1]).type, 'response.create');
    // 工具执行期间用户开口：结果仍回填，但不再抢 response.create（VAD 自动起新轮）
    rtState.socket.emitEvent(JSON.stringify({ type: 'response.function_call_arguments.done',
      call_id: 'c2', name: 'search_books', arguments: '{}' }));
    await flush();
    rtState.socket.emitEvent(JSON.stringify({ type: 'input_audio_buffer.speech_started' }));
    await flush();
    const sendsBefore2 = rtState.sends.length;
    Rt.sendToolResult('c2', '结果');
    await flush();
    assert.equal(rtState.sends.length, sendsBefore2 + 1);
    assert.equal(JSON.parse(rtState.sends[sendsBefore2]).item.call_id, 'c2');
    // 静音=停上行帧（不断采集），取消静音恢复 append
    const sendsBefore = rtState.sends.length;
    Rt.setMuted(true);
    rtState.capturer.feedMic(mic);
    await flush();
    assert.equal(rtState.sends.length, sendsBefore);
    Rt.setMuted(false);
    rtState.capturer.feedMic(mic);
    await flush();
    assert.equal(rtState.sends.length, sendsBefore + 1);
    Rt.disconnect();
    await flush();
    await connecting;
    // 缺 Key：连接即抛（页面提示配置）
    deps.state.store.delete('s:ai_api_key_qwen-tokenplan');
    await assert.rejects(() => Rt.connect('x', cb, []), /Token Plan API Key/);
    deps.state.store.clear();
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
