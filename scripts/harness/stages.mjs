// harness 源码 staging（拆分自 check_ai_assistant.mjs）：真实 ArkTS → 临时目录可 import 形态
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { dir, read } from './paths.mjs';

/** 把真实 AiService 四文件族落进临时目录：SDK / rcp 类型转 import type，运行时依赖换成桩。 */
export function stageAiService() {
  // 路径映射（含拆分家族互引）；SDK 深路径类型 import 保留（strip-types 擦除，不触发解析）
  const PATHS = [
    ["'@iuroc/openai'", "'./aiServiceDeps.ts'"],
    ["'@kit.ArkTS'", "'./aiServiceDeps.ts'"],
    ["'@kit.RemoteCommunicationKit'", "'./aiServiceDeps.ts'"],
    ["'./TalebookService'", "'./aiServiceDeps.ts'"],
    ["'./AiTools'", "'./RealAiTools.ts'"],
    ["'./AiToolsDefs'", "'./AiToolsDefs.ts'"],
    ["'./McpService'", "'./RealMcp.ts'"],
    ["'./AiService'", "'./RealAiService.ts'"],
    ["'./AiServiceConfig'", "'./RealAiServiceConfig.ts'"],
    ["'./AiServiceHttp'", "'./RealAiServiceHttp.ts'"],
    ["'./AiServiceGateway'", "'./RealAiServiceGateway.ts'"],
  ];
  const VALUE_NAMES = new Set(['OpenAI', 'util', 'rcp', 'TalebookService', 'AiTools', 'McpService',
    'AiServiceConfig', 'AiServiceHttp', 'AiServiceGateway', 'ChatCompletionChunk']);
  // Config 下沉的常量（KEY_*/DEFAULT_*/MAX_*/TIMEOUT_MS/AI_PROVIDERS）都是运行时值
  const isValue = (n) => VALUE_NAMES.has(n.replace(/.* as /, '')) ||
    /^(KEY_|DEFAULT_|MAX_|TIMEOUT_MS|CONTEXT_LENGTH_OPTIONS|AI_PROVIDERS)/.test(n);
  for (const [out, ets] of [['RealAiService.ts', 'services/AiService.ets'],
    ['RealAiServiceConfig.ts', 'services/AiServiceConfig.ets'],
    ['RealAiServiceHttp.ts', 'services/AiServiceHttp.ets'],
    ['RealAiServiceGateway.ts', 'services/AiServiceGateway.ets']]) {
    let source = read(ets).replace(/^(import|export) \{ ([^}]+) \} from '([^']+)';$/gm, (all, verb, clause, path) => {
      if (verb === 'export') {
        // 门面转发（export { CONTEXT_LENGTH_OPTIONS } from './AiServiceConfig'）同样要落扩展名
        const ex = PATHS.find((p) => p[0] === `'${path}'`);
        return ex === undefined ? all : `export { ${clause} } from ${ex[1]};`;
      }
      if (path.startsWith('@iuroc/openai/src/')) {
        // SDK 深路径全是类型：转 import type（运行时擦除，避免解析未安装的包）
        return `import type { ${clause} } from '${path}';`;
      }
      const hit = PATHS.find((p) => p[0] === `'${path}'`);
      if (hit === undefined) { return all; }
      const names = clause.split(',').map((s) => s.trim());
      const vals = names.filter(isValue);
      const tys = names.filter((n) => !vals.includes(n));
      const parts = [];
      if (vals.length > 0) { parts.push(`import { ${vals.join(', ')} } from ${hit[1]};`); }
      if (tys.length > 0) { parts.push(`import type { ${tys.join(', ')} } from ${hit[1]};`); }
      return parts.join('\n');
    });
    writeFileSync(join(dir, out), source);
  }
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
export function stageChatStore() {
  let source = read('services/AiChatStore.ets');
  source = source
    .replace(`import { AiTools, AiPermissionMode } from './AiTools';`,
      `import { AiTools } from './RealAiTools.ts';\nimport type { AiPermissionMode } from './RealAiTools.ts';`)
    .replace(`import { AiToolDefinition, parseToolBookLines, ToolBookLine } from './AiToolsDefs';`,
      `import { parseToolBookLines } from './AiToolsDefs.ts';\nimport type { AiToolDefinition, ToolBookLine } from './AiToolsDefs.ts';`)
    .replace(`import { AiService, AiConfig, AiMessage, AiStreamHandlers, AiAbortHandle } from './AiService';`,
      `import { AiService } from './shim.ts';`)
    .replace(`from './AiPersona'`, `from './RealAiPersona.ts'`)
    .replace(`from './TalebookService'`, `from './shim.ts'`)
    .replace(`from '@kit.CoreFileKit'`, `from './shim.ts'`)
    .replace(`from '@kit.ImageKit'`, `from './shim.ts'`)
    .replace(`from '@kit.ArkTS'`, `from './shim.ts'`);
  writeFileSync(join(dir, 'RealAiChatStore.ts'), source);
}

export function stageAiPersona() {
  let source = read('services/AiPersona.ets');
  source = source
    .replace(`from '@kit.CoreFileKit'`, `from './personaDeps.ts'`)
    .replace(`from './TalebookService'`, `from './personaDeps.ts'`);
  writeFileSync(join(dir, 'RealAiPersona.ts'), source);
}

/** MetaSearchService 真实入检：rcp/util 复用 aiServiceDeps 桩（state.rcpResponse 可编程）。 */
export function stageMetaSearch() {
  let source = read('services/MetaSearchService.ets');
  source = source
    .replace(`from '@kit.RemoteCommunicationKit'`, `from './aiServiceDeps.ts'`)
    .replace(`from '@kit.ArkTS'`, `from './aiServiceDeps.ts'`);
  writeFileSync(join(dir, 'RealMetaSearch.ts'), source);
}

/** EncyclopediaService 真实入检：rcp/util 复用 aiServiceDeps 桩（双通道都走 fetchText）。 */
export function stageEncyclopedia() {
  let source = read('services/EncyclopediaService.ets');
  source = source
    .replace(`from '@kit.RemoteCommunicationKit'`, `from './aiServiceDeps.ts'`)
    .replace(`from '@kit.ArkTS'`, `from './aiServiceDeps.ts'`);
  writeFileSync(join(dir, 'RealEncyclopedia.ts'), source);
}

/** McpService 真实入检：rcp/util 复用 aiServiceDeps 桩；AiTools 纯类型 import 擦除。 */
export function stageMcp() {
  let source = read('services/McpService.ets');
  source = source
    .replace(`from '@kit.RemoteCommunicationKit'`, `from './aiServiceDeps.ts'`)
    .replace(`from '@kit.ArkTS'`, `from './aiServiceDeps.ts'`)
    .replace(`import { AiToolDefinition, AiToolFunctionBody, AiToolParameters } from './AiToolsDefs';\n`, '');
  writeFileSync(join(dir, 'RealMcp.ts'), source);
}

/** QwenAudioService 真实入检：rcp/fs/存储复用 aiServiceDeps 桩；audio/media 空壳（不测录音/播放）。 */
export function stageQwenAudio() {
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
export function stageNovelMeta() {
  let source = read('services/NovelMetaService.ets');
  source = source
    .replace(`from '@kit.RemoteCommunicationKit'`, `from './aiServiceDeps.ts'`)
    .replace(`from '@kit.ArkTS'`, `from './aiServiceDeps.ts'`)
    .replace(`from './Reader3Native'`, `from './reader3Stub.ts'`);
  writeFileSync(join(dir, 'RealNovelMeta.ts'), source);
}

/** Reader3Native 真实入检：libentry/getContext 换桩，rcp/util 复用 aiServiceDeps。 */
export function stageReader3() {
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

export function stageAiTools() {
  /* AiTools 拆分家族（Defs/Core/Meta/Shelf/门面）统一 staging：
     import 路径映射到桩/已 staged 文件，并按 strip-types 语义拆 type/value 行
     （接口名在目标 .ts 里被擦除，混值 import 会挂）。 */
  const PATHS = [
    ["'./TalebookApi'", "'./aiToolsDeps.ts'"],
    ["'./AnnotationApi'", "'./aiToolsDeps.ts'"],
    ["'./TalebookService'", "'./aiToolsDeps.ts'"],
    ["'./SoNovelService'", "'./aiToolsDeps.ts'"],
    ["'../utils/SoNovelMerge'", "'./aiToolsDeps.ts'"],
    ["'./DownloadTaskService'", "'./aiToolsDeps.ts'"],
    ["'./BookListApi'", "'./aiToolsDeps.ts'"],
    ["'./BookModels'", "'./aiToolsDeps.ts'"],
    ["'./ServerProfile'", "'./aiToolsDeps.ts'"],
    ["'./AccountManager'", "'./aiToolsDeps.ts'"],
    ["'@kit.CoreFileKit'", "'./aiToolsDeps.ts'"],
    ["'./MetaSearchService'", "'./RealMetaSearch.ts'"],
    ["'./NovelMetaService'", "'./RealNovelMeta.ts'"],
    ["'./EncyclopediaService'", "'./RealEncyclopedia.ts'"],
    ["'./AiPersona'", "'./RealAiPersona.ts'"],
    ["'./AiService'", "'./RealAiService.ts'"],
    ["'../models/BookListModels'", "'./BookListModels.ts'"],
    ["'../models/DeviceModels'", "'./DeviceModels.ts'"],
    ["'../models/HomeModels'", "'./HomeModels.ts'"],
    ["'./AiTools'", "'./RealAiTools.ts'"],
    ["'./AiToolsDefs'", "'./AiToolsDefs.ts'"],
    ["'./AiToolsCore'", "'./AiToolsCore.ts'"],
    ["'./AiToolsExecMeta'", "'./RealAiToolsExecMeta.ts'"],
    ["'./AiToolsExecShelf'", "'./RealAiToolsExecShelf.ts'"],
  ];
  const TYPE_NAMES = new Set(['ApiMessageResult', 'ReferBook', 'ReferSearchOpts', 'ReferSearchResponse',
    'SoNovelBookPayload', 'DownloadTask', 'SoNovelSearchItem', 'BookListAddResponse', 'BookDetail',
    'BookListDetailResponse', 'BookListMutationResponse', 'BookListUpdatePayload', 'BookListsResponse',
    'BookListSummary', 'ReadingDevice', 'HomeBook', 'ReadingStatsSummary', 'DoubanDetail', 'DoubanHit',
    'NovelMeta', 'EncyclopediaHit', 'WebSearchHit', 'WebSearchResult', 'AiConfig', 'LlmSearchResult',
    'LlmSearchSource', 'ToolBookLine', 'AiToolDefinition', 'AiToolParameters', 'AiToolFunctionBody',
    'AiToolProperty', 'AiPermissionMode']);
  for (const [out, ets] of [['RealAiTools.ts', 'services/AiTools.ets'],
    ['AiToolsCore.ts', 'services/AiToolsCore.ets'],
    ['RealAiToolsExecMeta.ts', 'services/AiToolsExecMeta.ets'],
    ['RealAiToolsExecShelf.ts', 'services/AiToolsExecShelf.ets']]) {
    let source = read(ets).replace(/^import \{ ([^}]+) \} from '([^']+)';$/gm, (all, clause, path) => {
      const hit = PATHS.find((p) => p[0] === `'${path}'`);
      if (hit === undefined) { return all; }
      const names = clause.split(',').map((s) => s.trim());
      const types = names.filter((n) => TYPE_NAMES.has(n.split(' as ')[0]));
      const vals = names.filter((n) => !TYPE_NAMES.has(n.split(' as ')[0]));
      const parts = [];
      if (vals.length > 0) { parts.push(`import { ${vals.join(', ')} } from ${hit[1]};`); }
      if (types.length > 0) { parts.push(`import type { ${types.join(', ')} } from ${hit[1]};`); }
      return parts.join('\n');
    });
    writeFileSync(join(dir, out), source);
  }
  // 定义区纯数据无外部依赖，原样拷
  writeFileSync(join(dir, 'AiToolsDefs.ts'), read('services/AiToolsDefs.ets'));
}

export function stagePure(name, path, typeNames) {
  let source = read(path).replace(/from '\.\.\/services\/BookModels'/g, "from './BookModels.ts'");
  for (const type of typeNames) {
    source = source.replace(`import { ${type} }`, `import type { ${type} }`);
  }
  writeFileSync(join(dir, `${name}.ts`), source);
}

export function stagePage(name) {
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

