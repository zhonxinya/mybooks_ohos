import { emitter } from '@kit.BasicServicesKit';
import { ReadKitEventPayload } from '../common/Models';

export const READKIT_NATIVE_EVENT_ID: string = 'readkit_event';

interface EmitterPayload {
  data: ReadKitEventPayload;
}

/** In-process ReadKit event channel (replaces flutter_readkit). */
export class ReadKitEventChannel {
  static emit(event: ReadKitEventPayload): void {
    const payload: EmitterPayload = { data: event };
    emitter.emit(READKIT_NATIVE_EVENT_ID, payload);
  }
}
