// AI 回复播报统一入口：按设置选择系统语音（CoreSpeechKit）或 Token Plan 云端 TTS。
// 系统引擎复用 ReaderTtsService（离线引擎 online=1；模拟器无引擎会在 createEngine 报 50008，
// 由 errorCallback 转成播报失败提示，用户在设置页可切回云端档）。
import { AiService } from './AiService';
import { QwenAudioService } from './QwenAudioService';
import { ReaderTtsService } from './ReaderTtsService';

export class SpeakService {
  private static systemTts: ReaderTtsService | null = null;
  private static pending: ((completed: boolean) => void) | null = null;
  private static pendingReject: ((error: Error) => void) | null = null;

  /** 合成并播放一段文本直到播完；被打断返回 false，引擎/网络失败抛错（调用方 toast）。 */
  static async speak(text: string): Promise<boolean> {
    if (AiService.loadSpeakEngine() === 'cloud') {
      const path: string = await QwenAudioService.synthesize(text);
      return await QwenAudioService.playFile(path);
    }
    return await SpeakService.speakSystem(text);
  }

  /** 打断当前播报。不判断在播的是哪一路，两边都停；未播完的 speak 以 false 结束。 */
  static stop(): void {
    QwenAudioService.stopPlayback();
    if (SpeakService.systemTts !== null) {
      SpeakService.systemTts.stop();
    }
    // ReaderTtsService.stop() 不发完成回调，这里补上，否则 speak 的 Promise 悬挂
    SpeakService.settle(false);
  }

  private static ensureSystemTts(): ReaderTtsService {
    if (SpeakService.systemTts === null) {
      const tts: ReaderTtsService = new ReaderTtsService();
      tts.setCallbacks(
        (): void => {},
        (message: string): void => {
          SpeakService.rejectWith(new Error(message));
        },
        (): void => {},
      );
      SpeakService.systemTts = tts;
    }
    return SpeakService.systemTts;
  }

  private static speakSystem(text: string): Promise<boolean> {
    const tts: ReaderTtsService = SpeakService.ensureSystemTts();
    return new Promise<boolean>((resolve: (completed: boolean) => void,
      reject: (error: Error) => void): void => {
      SpeakService.pending = resolve;
      SpeakService.pendingReject = reject;
      tts.start([text], 1.0, (): void => {
        SpeakService.settle(true);
      }).then((ok: boolean): void => {
        if (!ok) {
          // createEngine 失败时错误回调已先行 reject，这里兜底防止悬挂
          SpeakService.settle(false);
        }
      });
    });
  }

  private static settle(completed: boolean): void {
    const resolve: ((completed: boolean) => void) | null = SpeakService.pending;
    SpeakService.pending = null;
    SpeakService.pendingReject = null;
    if (resolve !== null) {
      resolve(completed);
    }
  }

  private static rejectWith(error: Error): void {
    const reject: ((error: Error) => void) | null = SpeakService.pendingReject;
    SpeakService.pending = null;
    SpeakService.pendingReject = null;
    if (reject !== null) {
      reject(error);
    }
  }
}
