import { TalebookCoreService } from './TalebookCoreService';

/**
 * MyBooks 专有接口：批量添加实体书（CSV）、有声书导入与连通性测试、TXT 阅读/解析、
 * 书籍文件路径查询与馆藏位置写入。
 *
 * 端点依据（逐项核对上游源码，勿凭印象改动）：
 * - 批量添加 / 音频导入：`docs/mybooks/webserver/handlers/scan.py`
 *   `BatchAddRun`(POST /api/admin/batch_add/run, multipart `csv_file`)
 *   `BatchAddStatus`(GET /api/admin/batch_add/status)
 *   `AudioImportRun`(POST /api/admin/audio_import/run)
 *   `AudioImportStatus`(GET /api/admin/audio_import/status)
 * - 音频连通性测试：`docs/mybooks/webserver/handlers/admin.py` `AudioTestConnection`
 *   (POST /api/admin/audio/test，JSON 体 `proxy` / `use_bookbarn_proxy`)
 * - TXT 阅读 / 解析、文件路径、位置：`docs/mybooks/webserver/handlers/book.py`
 *   `TxtRead`(GET /api/read/txt/{id}?start=&end=)
 *   `BookTxtParser`(GET /api/book/txt/parser?id=&test=)
 *   `BookFilePath`(GET /api/book/{id}/filepath?format=epub|pdf)
 *   `BookLocation`(POST /api/book/{id}/location，JSON 体 `location`，≤ 20 字符)
 */

/** 通用 `{err, msg}` 响应；`err === undefined || err === 'ok'` 视为成功。 */
export interface AdminApiResult {
  err?: string;
  msg?: string;
}

/** 批量添加进度（上游 `BatchAddService.static_status`）。 */
export interface BatchAddProgress {
  total?: number;
  processed?: number;
  success?: number;
  failed?: number;
  invalid?: number;
}

/** 扫描汇总（上游 `handlers/scan.py::Scanner.summary()`）。 */
export interface ScanSummary {
  total?: number;
  done?: number;
  todo?: number;
}

/** POST /api/admin/batch_add/run */
export interface BatchAddRunResponse extends AdminApiResult {
  total?: number;
}

/** GET /api/admin/batch_add/status */
export interface BatchAddStatusResponse extends AdminApiResult {
  status?: BatchAddProgress;
  summary?: ScanSummary;
  batch_adding?: boolean;
}

/** 有声书导入进度（上游 `AudioBookImporter.static_status`）。 */
export interface AudioImportProgress {
  total?: number;
  imported?: number;
  exist?: number;
  skipped?: number;
}

/** GET /api/admin/audio_import/status */
export interface AudioImportStatusResponse extends AdminApiResult {
  status?: AudioImportProgress;
  summary?: ScanSummary;
  audio_importing?: boolean;
}

/**
 * POST /api/admin/audio/test 请求体。
 * `proxy` 为空时服务端直连 EdgeTTS；`useBookbarnProxy` 为 true 时服务端走书栈代理并直接返回成功。
 */
export interface AudioTestOptions {
  proxy?: string;
  useBookbarnProxy?: boolean;
}

/** TXT 目录章节（上游 `plugins/parser/txt.py` 的 toc 项）。 */
export interface TxtTocChapter {
  id?: number;
  title?: string;
  start?: number;
  end?: number;
}

/**
 * GET /api/book/txt/parser 的 `data`。
 * 已解析：`content`（目录）+ `encoding` + `name`；
 * 未解析且 test=0（触发解析）：`wait` + `name` + `que`（+ `path`）。
 */
export interface TxtParserData {
  content?: TxtTocChapter[];
  encoding?: string;
  name?: string;
  wait?: number;
  path?: string;
  que?: number;
}

/** GET /api/book/txt/parser */
export interface TxtParserResponse extends AdminApiResult {
  data?: TxtParserData;
}

/** GET /api/read/txt/:id（服务端已把 `\r` 去掉、`\n` 替换为 `<br>`）。 */
export interface TxtReadResponse extends AdminApiResult {
  content?: string;
}

/** GET /api/book/:id/filepath?format= 的 `data`。 */
export interface BookFilePathData {
  path?: string;
}

/** GET /api/book/:id/filepath?format=epub|pdf */
export interface BookFilePathResponse extends AdminApiResult {
  data?: BookFilePathData;
}

/** POST /api/book/:id/location 请求体 */
interface BookLocationPayload {
  location: string;
}

/** 追加查询参数（与 `TalebookApi` 的 helper 保持同一拼装规则）。 */
function appendQuery(base: string, key: string, value: string | number): string {
  const sep = base.indexOf('?') >= 0 ? '&' : '?';
  return `${base}${sep}${encodeURIComponent(key)}=${encodeURIComponent(String(value))}`;
}

export class AdminImportApi {
  /** 响应是否成功（`err === undefined || err === 'ok'`）。 */
  static isOk(rsp: AdminApiResult): boolean {
    return rsp.err === undefined || rsp.err === 'ok';
  }

  /** 取服务端可用提示：优先 `msg`，回退 `err` 错误码。 */
  static errorText(rsp: AdminApiResult): string {
    if (rsp.msg !== undefined && rsp.msg.length > 0) {
      return rsp.msg;
    }
    return rsp.err !== undefined && rsp.err !== 'ok' ? rsp.err : '';
  }

  /**
   * 启动批量添加实体书（POST /api/admin/batch_add/run）。
   * 上游要求 multipart 字段名 `csv_file` 且文件名以 `.csv` 结尾，CSV 内必须有 `isbn` 字段（Tab 分隔）。
   * 响应 `err` 取值：`params.error`（未选文件 / 非 CSV / 缺 isbn / 无数据）、`server.error`。
   */
  static async runBatchAdd(localPath: string, fileName: string): Promise<BatchAddRunResponse> {
    const raw = await TalebookCoreService.talebookUploadFile(
      '/api/admin/batch_add/run', localPath, 'csv_file', fileName);
    return JSON.parse(raw) as BatchAddRunResponse;
  }

  /** 批量添加状态（GET /api/admin/batch_add/status）。未运行时 `status`/`summary` 为空对象。 */
  static async getBatchAddStatus(): Promise<BatchAddStatusResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/batch_add/status');
    return JSON.parse(raw) as BatchAddStatusResponse;
  }

  /**
   * 启动有声书导入（POST /api/admin/audio_import/run，无请求体）。
   * 已在运行时响应 `err === 'running'`。
   */
  static async runAudioImport(): Promise<AdminApiResult> {
    const raw = await TalebookCoreService.talebookPost('/api/admin/audio_import/run', '{}');
    return JSON.parse(raw) as AdminApiResult;
  }

  /** 有声书导入状态（GET /api/admin/audio_import/status）。未运行时 `status`/`summary` 为空对象。 */
  static async getAudioImportStatus(): Promise<AudioImportStatusResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/audio_import/status');
    return JSON.parse(raw) as AudioImportStatusResponse;
  }

  /**
   * 音频服务连通性测试（POST /api/admin/audio/test）。
   * 上游仅接受 `http://`/`https://` 开头且长度 ≥ 10 的代理地址，否则返回 `params.error.proxy`。
   */
  static async testAudioConnection(options: AudioTestOptions): Promise<AdminApiResult> {
    const body: Record<string, Object> = {
      'use_bookbarn_proxy': options.useBookbarnProxy === true,
    };
    const proxy = options.proxy !== undefined ? options.proxy.trim() : '';
    if (proxy.length > 0) {
      body['proxy'] = proxy;
    }
    const raw = await TalebookCoreService.talebookPost('/api/admin/audio/test', JSON.stringify(body));
    return JSON.parse(raw) as AdminApiResult;
  }

  /**
   * 读取 TXT 内容片段（GET /api/read/txt/:id?start=&end=，`end = -1` 表示读到文件末尾）。
   * 服务端按字节 seek/read，返回的 `content` 中换行已替换为 `<br>`。
   * 响应 `err` 取值：`params.book.invalid`、`format error`（非 txt / 空文件）、用户权限类错误。
   */
  static async readTxtContent(bookId: number, start: number = 0, end: number = -1): Promise<TxtReadResponse> {
    let path = `/api/read/txt/${bookId}`;
    path = appendQuery(path, 'start', start);
    path = appendQuery(path, 'end', end);
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as TxtReadResponse;
  }

  /**
   * TXT 解析状态查询 / 触发（GET /api/book/txt/parser?id=&test=）。
   * - `testReady = true`（test=1）：已解析返回目录，未解析仅返回 `msg = 'not parsed'`，不排队；
   * - `testReady = false`（test=0）：已解析同样返回目录，未解析则加入解析队列并返回 `wait`/`que`。
   */
  static async parseTxtBook(bookId: number, testReady: boolean = true): Promise<TxtParserResponse> {
    let path = '/api/book/txt/parser';
    path = appendQuery(path, 'id', bookId);
    path = appendQuery(path, 'test', testReady ? '1' : '0');
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as TxtParserResponse;
  }

  /**
   * 查询书籍在服务端的文件路径（GET /api/book/:id/filepath?format=epub|pdf）。
   * 服务端只接受 `epub` / `pdf`；不存在该格式时返回 `params.format.unavailable`。
   */
  static async getBookFilePath(bookId: number, format: string): Promise<BookFilePathResponse> {
    const path = appendQuery(`/api/book/${bookId}/filepath`, 'format', format);
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as BookFilePathResponse;
  }

  /**
   * 写入馆藏位置（POST /api/book/:id/location）。
   * 服务端要求管理员或书籍所有者，且 `location` 不超过 20 字符（超长返回 `params.location.invalid`）。
   */
  static async setBookLocation(bookId: number, location: string): Promise<AdminApiResult> {
    const payload: BookLocationPayload = { location: location };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/location`,
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminApiResult;
  }
}
