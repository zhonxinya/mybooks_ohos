import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { ApiEnvelope, SoNovelBookPayload, TalebookService } from './TalebookService';
import { ErrorFormat } from '../utils/ErrorFormat';

interface SoNovelSearchBody extends Record<string, Object> {
  code: number;
  message: string;
  data: Record<string, Object>[];
}

export type SoNovelDownloadStage = 'converting' | 'downloading' | 'completed';

export interface SoNovelDownloadProgress {
  stage: SoNovelDownloadStage;
  progress: number;
  message: string;
}

interface SseAbortHandle {
  aborted: boolean;
  destroy?: () => void;
}

export class SoNovelService {
  private static currentSseAbort: SseAbortHandle | null = null;
  /** SSE 行缓冲上限（字符数）：防御异常/恶意服务端持续发送无换行数据导致内存无界增长 */
  private static readonly SSE_BUFFER_MAX_CHARS: number = 1024 * 1024;
  /** 单行长度上限：超长行直接丢弃，避免解析开销与内存占用 */
  private static readonly SSE_LINE_MAX_CHARS: number = 64 * 1024;

  private static encodeKeyword(keyword: string): string {
    return encodeURIComponent(keyword);
  }

  private static getBaseUrl(): string {
    return TalebookService.secureGet('sonovel_url').replace(/\/+$/, '');
  }

  private static buildBookFetchUrl(base: string, payload: SoNovelBookPayload): string {
    // so-novel BookFetchServlet 只识别 url/format/language/concurrency，
    // 书源由服务端根据 url 自行解析（SourceUtils.getRule(bookUrl)）。
    const format = (payload.format ?? 'epub').toLowerCase();
    const language = payload.language ?? 'zh-CN';
    const parts: string[] = [
      `url=${encodeURIComponent(payload.url)}`,
      `format=${encodeURIComponent(format)}`,
      `language=${encodeURIComponent(language)}`,
    ];
    return `${base}/book-fetch?${parts.join('&')}`;
  }

  private static decodeChunk(data: ArrayBuffer): string {
    const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(new Uint8Array(data));
  }

  private static responseText(result: Object | string | ArrayBuffer | undefined): string {
    if (result === undefined || result === null) {
      return '';
    }
    if (typeof result === 'string') {
      return result;
    }
    if (result instanceof ArrayBuffer) {
      return SoNovelService.decodeChunk(result);
    }
    return ErrorFormat.message(result as Object);
  }

  private static httpErrorMessage(
    statusCode: number,
    result: Object | string | ArrayBuffer | undefined,
    action: string = '下载',
  ): string {
    const raw = SoNovelService.responseText(result).trim();
    if (raw.length > 0 && !raw.startsWith('<!DOCTYPE') && !raw.startsWith('<html') && !raw.startsWith('<HTML')) {
      return raw.length > 120 ? raw.substring(0, 120) : raw;
    }
    if (statusCode === 502) {
      return action === '搜索'
        ? '搜索服务暂时不可用（502），请稍后重试'
        : '书源暂时不可用（502），请换书源或稍后重试';
    }
    if (statusCode === 504) {
      return `${action}超时（504），请稍后重试`;
    }
    return `${action}失败（HTTP ${statusCode}）`;
  }

  private static handleSsePayload(
    payload: string,
    onProgress: (progress: SoNovelDownloadProgress) => void,
  ): boolean {
    try {
      const decoded = JSON.parse(payload) as Record<string, Object>;
      const type = String(decoded['type'] ?? '');
      if (type === 'download-complete' || type === 'complete' || type === 'done') {
        onProgress({
          stage: 'completed',
          progress: 100,
          message: '下载完成',
        });
        return true;
      }
      if (type !== 'download-progress') {
        return false;
      }
      const index = Number(decoded['index'] ?? 0);
      const total = Number(decoded['total'] ?? 0);
      const ratio = total > 0 ? Math.min(1, Math.max(0, index / total)) : 0;
      const completed = total > 0 && index >= total;
      onProgress({
        stage: completed ? 'completed' : 'downloading',
        progress: completed ? 100 : Math.round(ratio * 100),
        message: completed ? '下载完成' : `章节进度 ${index}/${total}`,
      });
      return completed;
    } catch (_error) {
      return false;
    }
  }

  private static abortActiveSse(): void {
    const active = SoNovelService.currentSseAbort;
    if (active === null) {
      return;
    }
    active.aborted = true;
    if (active.destroy !== undefined) {
      active.destroy();
    }
    SoNovelService.currentSseAbort = null;
  }

  private static listenDownloadProgress(
    base: string,
    onProgress: (progress: SoNovelDownloadProgress) => void,
    abort: SseAbortHandle,
  ): Promise<void> {
    return new Promise((resolve, reject) => {
      SoNovelService.abortActiveSse();
      SoNovelService.currentSseAbort = abort;

      const httpRequest = http.createHttp();
      abort.destroy = (): void => {
        try {
          httpRequest.destroy();
        } catch (_error) {
        }
      };

      let buffer = '';
      let settled = false;

      const finish = (error?: Error): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (SoNovelService.currentSseAbort === abort) {
          SoNovelService.currentSseAbort = null;
        }
        try {
          httpRequest.destroy();
        } catch (_error) {
        }
        if (error !== undefined) {
          reject(error);
        } else {
          resolve();
        }
      };

      httpRequest.on('dataReceive', (data: ArrayBuffer) => {
        if (abort.aborted) {
          finish();
          return;
        }
        buffer += SoNovelService.decodeChunk(data);
        if (buffer.length > SoNovelService.SSE_BUFFER_MAX_CHARS) {
          // 无换行数据堆积超限：视为异常流，中止以免内存耗尽
          finish(new Error('进度流数据异常'));
          return;
        }
        let newline = buffer.indexOf('\n');
        while (newline >= 0) {
          const line = buffer.substring(0, newline).trim();
          buffer = buffer.substring(newline + 1);
          if (line.length > SoNovelService.SSE_LINE_MAX_CHARS) {
            newline = buffer.indexOf('\n');
            continue;
          }
          if (line.startsWith('data:')) {
            const payload = line.substring(5).trim();
            if (payload.length > 0) {
              SoNovelService.handleSsePayload(payload, onProgress);
            }
          }
          newline = buffer.indexOf('\n');
        }
      });

      httpRequest.on('dataEnd', () => {
        finish();
      });

      httpRequest.requestInStream(`${base}/download-progress`, {
        method: http.RequestMethod.GET,
        header: {
          'Accept': 'text/event-stream',
        },
        connectTimeout: 60000,
        readTimeout: 1800000,
      }, (err: BusinessError | null, _data: number) => {
        if (abort.aborted) {
          finish();
          return;
        }
        if (err !== null) {
          finish(new Error(ErrorFormat.message(err as Object)));
        }
      });
    });
  }

  static async fetchBookWithProgress(
    payload: SoNovelBookPayload,
    onProgress: (progress: SoNovelDownloadProgress) => void,
    enableSse: boolean = false,
  ): Promise<void> {
    try {
      await SoNovelService.fetchBookWithProgressInternal(payload, onProgress, enableSse);
    } catch (error) {
      throw new Error(ErrorFormat.message(error as Object));
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private static async fetchBookWithProgressInternal(
    payload: SoNovelBookPayload,
    onProgress: (progress: SoNovelDownloadProgress) => void,
    enableSse: boolean,
  ): Promise<void> {
    const base = SoNovelService.getBaseUrl();
    if (base.length === 0) {
      throw new Error('请先配置 SoNovel 服务地址');
    }

    const abort: SseAbortHandle = { aborted: false };
    onProgress({
      stage: 'converting',
      progress: enableSse ? 0 : -1,
      message: '正在书源获取与转换...',
    });

    const ssePromise = enableSse
      ? SoNovelService.listenDownloadProgress(base, onProgress, abort)
      : null;

    try {
      const fetchUrl = SoNovelService.buildBookFetchUrl(base, payload);
      const httpRequest = http.createHttp();
      try {
        const response = await httpRequest.request(fetchUrl, {
          method: http.RequestMethod.GET,
          header: {
            'Accept': '*/*',
          },
          connectTimeout: 60000,
          readTimeout: 1800000,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          usingProtocol: http.HttpProtocol.HTTP1_1,
        });
        if (response.responseCode < 200 || response.responseCode >= 300) {
          throw new Error(SoNovelService.httpErrorMessage(
            response.responseCode,
            response.result as Object | string | ArrayBuffer | undefined,
          ));
        }
      } finally {
        httpRequest.destroy();
      }
    } finally {
      abort.aborted = true;
      if (abort.destroy !== undefined) {
        abort.destroy();
      }
      if (ssePromise !== null) {
        try {
          await ssePromise;
        } catch (_error) {
        }
      }
    }

    onProgress({ stage: 'completed', progress: 100, message: '下载完成' });
  }

  private static normalizeResults(body: Record<string, Object> | null): Record<string, Object>[] {
    if (body === null) {
      return [];
    }
    const raw = body['data'];
    if (!Array.isArray(raw)) {
      return [];
    }
    const items: Record<string, Object>[] = [];
    for (let i = 0; i < raw.length && i < 500; i++) {
      const item: Object = raw[i] as Object;
      if (item !== null && typeof item === 'object') {
        items.push(item as Record<string, Object>);
      }
    }
    return items;
  }

  static async search(keyword: string): Promise<ApiEnvelope> {
    const trimmed = keyword.trim();
    if (trimmed.length === 0) {
      return { status: 0, body: null, error: '请输入搜索关键词' };
    }
    const base = SoNovelService.getBaseUrl();
    if (base.length === 0) {
      return { status: 0, body: null, error: '请先配置 SoNovel 服务地址' };
    }

    const url = `${base}/search/aggregated?kw=${SoNovelService.encodeKeyword(trimmed)}`;
    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'Accept': 'application/json',
        },
        connectTimeout: 60000,
        readTimeout: 120000,
        expectDataType: http.HttpDataType.STRING,
        usingProtocol: http.HttpProtocol.HTTP1_1,
      });
      const status = response.responseCode;
      const raw = SoNovelService.responseText(response.result as Object | string | ArrayBuffer | undefined);
      if (status < 200 || status >= 300) {
        return {
          status: status,
          body: null,
          error: SoNovelService.httpErrorMessage(status, raw, '搜索'),
        };
      }
      if (raw.length === 0) {
        return { status: status, body: null, error: '服务器返回空响应' };
      }
      let body: Record<string, Object>;
      try {
        body = JSON.parse(raw) as Record<string, Object>;
      } catch (_error) {
        return { status: status, body: null, error: '搜索结果解析失败' };
      }
      const code = Number(body['code'] ?? status);
      if (code !== 200) {
        return {
          status: status,
          body: body,
          error: String(body['message'] ?? '搜索失败'),
        };
      }
      const normalized: SoNovelSearchBody = {
        code: code,
        message: String(body['message'] ?? ''),
        data: SoNovelService.normalizeResults(body),
      };
      const envelope: ApiEnvelope = {
        status: status,
        body: normalized,
        error: '',
      };
      return envelope;
    } catch (error) {
      const message = ErrorFormat.message(error as Object);
      if (message.includes('Timeout') || message.includes('timeout') || message.includes('2300028')) {
        return { status: 0, body: null, error: '搜索超时，请稍后重试' };
      }
      if (message.includes('SSL') || message.includes('certificate')) {
        // 该通道走 NetworkKit，始终校验证书；「跳过 SSL 验证」仅作用于自建服务端通道，
        // 故此处引导用户改用受信任证书或局域网 http 地址，避免误关全局校验。
        return { status: 0, body: null, error: 'SSL 证书验证失败，请为服务端配置受信任证书，或改用 http:// 局域网地址' };
      }
      return { status: 0, body: null, error: message.length > 0 ? message : '网络请求失败' };
    } finally {
      httpRequest.destroy();
    }
  }
}
