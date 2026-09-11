import { BusinessError, emitter } from '@kit.BasicServicesKit';
import { common, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ReadKitBookmark,
  ReadKitEventPayload,
  ReadKitOpenParams,
  ReadKitProgress,
  ReadKitSettings,
} from '../common/Models';
import { ReadKitEventChannel, READKIT_NATIVE_EVENT_ID } from './ReadKitEventChannel';
import { TalebookCoreService } from './TalebookCoreService';

export const READKIT_PROTOCOL_VERSION: number = 1;

export type ReadKitEventHandler = (event: ReadKitEventPayload) => void;

const TAG: string = 'ReadKitBridge';
const BUNDLE_NAME: string = 'com.zhonxinya.talebook';
const ABILITY_NAME: string = 'ReadKitAbility';

interface LocationJson {
  engine: string;
  resourceIndex: number;
  domPos: string;
}

interface HistoryRecord {
  book_id: string;
  chapter_index: number;
  current_page: number;
  total_pages: number;
  progress_percent: number;
  last_read_time: number;
  chapter_name: string;
  location: string;
}

interface AbilityParameters {
  readKitRequest: string;
  readKitSettings: string;
}

interface EmitterPayload {
  data: ReadKitEventPayload;
}

function toRecord(value: Object): Record<string, Object> {
  return JSON.parse(JSON.stringify(value)) as Record<string, Object>;
}
export class ReadKitBridge {
  private static activeSessionId: string | null = null;
  private static listeners: ReadKitEventHandler[] = [];
  private static globalHandlerInstalled: boolean = false;

  static installGlobalHandlers(): void {
    if (ReadKitBridge.globalHandlerInstalled) {
      return;
    }
    ReadKitBridge.globalHandlerInstalled = true;
    ReadKitBridge.onEvent((event: ReadKitEventPayload) => {
      ReadKitBridge.handlePersistence(event);
    });
  }

  private static handlePersistence(event: ReadKitEventPayload): void {
    if (event.type === 'progress' || event.type === 'closed') {
      if (event.progress === undefined || event.bookId === undefined || event.bookId.length === 0) {
        return;
      }
      const loc: LocationJson = {
        engine: 'readkit',
        resourceIndex: event.progress.resourceIndex,
        domPos: event.progress.location !== undefined ? event.progress.location.domPos : '',
      };
      const item: HistoryRecord = {
        book_id: event.bookId,
        chapter_index: event.progress.resourceIndex,
        current_page: event.progress.currentPage,
        total_pages: event.progress.totalPages,
        progress_percent: event.progress.progression * 100,
        last_read_time: Date.now(),
        chapter_name: event.progress.chapterName,
        location: JSON.stringify(loc),
      };
      TalebookCoreService.recordReadingHistory(toRecord(item)).catch((err: Error) => {
        hilog.warn(0x0000, TAG, 'recordReadingHistory failed: %{public}s', err.message);
      });
    }
    if (event.type === 'settingsChanged' && event.settings !== undefined) {
      TalebookCoreService.saveReaderConfig(event.settings as Record<string, Object>).catch(() => {
      });
    }
    if (event.type === 'closed' && event.sessionId !== undefined) {
      ReadKitBridge.clearSession(event.sessionId);
    }
  }

  static openReader(
    context: common.UIAbilityContext,
    params: ReadKitOpenParams,
    settings: ReadKitSettings,
  ): Promise<void> {
    if (params.filePath === undefined || params.filePath.length === 0 ||
      params.sessionId === undefined || params.sessionId.length === 0) {
      return Promise.reject(new Error('ReadKit 请求参数无效'));
    }
    if (ReadKitBridge.activeSessionId !== null) {
      return Promise.reject(new Error('已有阅读会话正在运行'));
    }
    const requestObj: Record<string, Object> = {};
    requestObj['version'] = READKIT_PROTOCOL_VERSION;
    requestObj['sessionId'] = params.sessionId;
    requestObj['filePath'] = params.filePath;
    requestObj['format'] = params.format ?? '';
    requestObj['bookId'] = params.bookId ?? '';
    requestObj['bookTitle'] = params.bookTitle ?? '';
    requestObj['downloadUrl'] = params.downloadUrl ?? '';
    requestObj['resourceIndex'] = params.resourceIndex ?? 0;
    requestObj['domPos'] = params.domPos ?? '';
    requestObj['bookmarks'] = params.bookmarks ?? [];
    const request = JSON.stringify(requestObj);
    const settingsJson = JSON.stringify(settings);
    ReadKitBridge.activeSessionId = params.sessionId;
    const abilityParams: AbilityParameters = {
      readKitRequest: request,
      readKitSettings: settingsJson,
    };
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: ABILITY_NAME,
      parameters: toRecord(abilityParams),
    };
    return context.startAbility(want).then(() => {
    }).catch((error: BusinessError) => {
      ReadKitBridge.activeSessionId = null;
      return Promise.reject(error);
    });
  }

  static clearSession(sessionId: string): void {
    if (ReadKitBridge.activeSessionId === sessionId) {
      ReadKitBridge.activeSessionId = null;
    }
  }

  static emitProgress(sessionId: string, bookId: string, progress: ReadKitProgress): void {
    const event: ReadKitEventPayload = {
      version: READKIT_PROTOCOL_VERSION,
      sessionId: sessionId,
      bookId: bookId,
      type: 'progress',
      progress: progress,
    };
    ReadKitBridge.emit(event);
  }

  static emitBookmark(
    sessionId: string,
    bookId: string,
    type: 'bookmarkAdded' | 'bookmarkRemoved',
    bookmark: ReadKitBookmark,
  ): void {
    const event: ReadKitEventPayload = {
      version: READKIT_PROTOCOL_VERSION,
      sessionId: sessionId,
      bookId: bookId,
      type: type,
      bookmark: bookmark,
    };
    ReadKitBridge.emit(event);
  }

  static emit(event: ReadKitEventPayload): void {
    const payload: EmitterPayload = { data: event };
    emitter.emit(READKIT_NATIVE_EVENT_ID, payload);
    ReadKitEventChannel.emit(event);
  }

  static onEvent(handler: ReadKitEventHandler): void {
    ReadKitBridge.listeners.push(handler);
    if (ReadKitBridge.listeners.length === 1) {
      emitter.on(READKIT_NATIVE_EVENT_ID, ReadKitBridge.dispatch);
    }
  }

  static offEvent(handler: ReadKitEventHandler): void {
    ReadKitBridge.listeners = ReadKitBridge.listeners.filter((item: ReadKitEventHandler) => item !== handler);
    if (ReadKitBridge.listeners.length === 0) {
      emitter.off(READKIT_NATIVE_EVENT_ID, ReadKitBridge.dispatch);
    }
  }

  private static dispatch(eventData: emitter.EventData): void {
    const payload = eventData.data as ReadKitEventPayload;
    if (payload === undefined) {
      return;
    }
    for (let i = 0; i < ReadKitBridge.listeners.length; i++) {
      ReadKitBridge.listeners[i](payload);
    }
  }
}
