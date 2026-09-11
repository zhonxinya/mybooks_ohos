import { BusinessError } from '@kit.BasicServicesKit';
import { textToSpeech } from '@kit.CoreSpeechKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'ReaderTtsService';
const MIN_SPEED: number = 0.5;
const MAX_SPEED: number = 2.0;
const DEFAULT_PERSON: number = 0;

export type ReaderTtsState = 'idle' | 'playing' | 'paused';

export interface ReaderTtsProgress {
  chunkIndex: number;
  totalChunks: number;
}

export interface ReaderTtsVoice {
  person: number;
  label: string;
}

export class ReaderTtsService {
  private engine: textToSpeech.TextToSpeechEngine | null = null;
  private chunks: string[] = [];
  private chunkIndex: number = 0;
  private speed: number = 1.0;
  private state: ReaderTtsState = 'idle';
  private chapterFinishedCallback: (() => void) | null = null;
  private stateCallback: ((state: ReaderTtsState) => void) | null = null;
  private errorCallback: ((message: string) => void) | null = null;
  private progressCallback: ((progress: ReaderTtsProgress) => void) | null = null;
  private initPromise: Promise<boolean> | null = null;
  private person: number = DEFAULT_PERSON;

  setCallbacks(
    stateCallback: (state: ReaderTtsState) => void,
    errorCallback: (message: string) => void,
    progressCallback: (progress: ReaderTtsProgress) => void,
  ): void {
    this.stateCallback = stateCallback;
    this.errorCallback = errorCallback;
    this.progressCallback = progressCallback;
  }

  getState(): ReaderTtsState {
    return this.state;
  }

  getSpeed(): number {
    return this.speed;
  }

  /** 语速改动立即生效：TTS 不支持运行时改参数，播放中只能重读当前段。 */
  setSpeed(speed: number): void {
    const next = ReaderTtsService.clampSpeed(speed);
    const changed = next !== this.speed;
    this.speed = next;
    if (changed && this.state === 'playing') {
      this.restartCurrentChunk();
    }
  }

  getPerson(): number {
    return this.person;
  }

  /** 切换发音人：参数只在创建引擎时生效，需重建引擎后从当前段继续。 */
  async setPerson(person: number): Promise<void> {
    if (person === this.person) {
      return;
    }
    this.person = person;
    if (this.state === 'idle') {
      return;
    }
    const wasPlaying = this.state === 'playing';
    this.resetEngine();
    if (!wasPlaying) {
      return;
    }
    const ready = await this.ensureEngine();
    if (ready) {
      this.speakCurrentChunk();
    }
  }

  /** 查询设备支持的中文发音人；失败或为空时由调用方降级隐藏选择项。 */
  static async listVoices(): Promise<ReaderTtsVoice[]> {
    try {
      const query: textToSpeech.VoiceQuery = {
        requestId: `voices_${Date.now()}`,
        online: 1,
      };
      const voices = await textToSpeech.listVoices(query);
      const result: ReaderTtsVoice[] = [];
      for (const voice of voices) {
        if (!voice.language.startsWith('zh')) {
          continue;
        }
        result.push({ person: voice.person, label: ReaderTtsService.voiceLabel(voice) });
      }
      return result;
    } catch (error) {
      const message = (error as BusinessError).message ?? '';
      hilog.warn(0x0000, TAG, 'listVoices failed: %{public}s', message);
      return [];
    }
  }

  async start(
    chunks: string[],
    speed: number,
    onChapterFinished: () => void,
  ): Promise<boolean> {
    if (chunks.length === 0) {
      return false;
    }
    const ready = await this.ensureEngine();
    if (!ready || this.engine === null) {
      return false;
    }
    this.chunks = chunks;
    this.chunkIndex = 0;
    this.speed = ReaderTtsService.clampSpeed(speed);
    this.chapterFinishedCallback = onChapterFinished;
    this.setState('playing');
    this.speakCurrentChunk();
    return true;
  }

  async resume(): Promise<boolean> {
    if (this.chunks.length === 0 || this.chunkIndex >= this.chunks.length) {
      return false;
    }
    const ready = await this.ensureEngine();
    if (!ready || this.engine === null) {
      return false;
    }
    this.setState('playing');
    this.speakCurrentChunk();
    return true;
  }

  pause(): void {
    if (this.state !== 'playing') {
      return;
    }
    this.engine?.stop();
    this.setState('paused');
  }

  stop(): void {
    this.engine?.stop();
    this.chunks = [];
    this.chunkIndex = 0;
    this.chapterFinishedCallback = null;
    this.setState('idle');
    this.emitProgress();
  }

  shutdown(): void {
    this.stop();
    this.resetEngine();
  }

  private resetEngine(): void {
    if (this.engine !== null) {
      this.engine.shutdown();
      this.engine = null;
    }
    this.initPromise = null;
  }

  private async ensureEngine(): Promise<boolean> {
    if (this.engine !== null) {
      return true;
    }
    if (this.initPromise !== null) {
      return this.initPromise;
    }
    this.initPromise = this.createEngine();
    return this.initPromise;
  }

  private async createEngine(): Promise<boolean> {
    try {
      const initParams: textToSpeech.CreateEngineParams = {
        language: 'zh-CN',
        person: this.person,
        online: 1,
        extraParams: {
          'style': 'interaction-broadcast',
          'locate': 'CN',
          'name': 'TalebookReaderTts',
        },
      };
      const engine = await textToSpeech.createEngine(initParams);
      engine.setListener({
        onStart: (_requestId: string, _response: textToSpeech.StartResponse): void => {
        },
        onComplete: (_requestId: string, _response: textToSpeech.CompleteResponse): void => {
          this.handleChunkComplete();
        },
        onStop: (_requestId: string, _response: textToSpeech.StopResponse): void => {
        },
        onError: (_requestId: string, errorCode: number, errorMessage: string): void => {
          hilog.error(0x0000, TAG, 'tts error %{public}d %{public}s', errorCode, errorMessage);
          this.reportError(errorMessage.length > 0 ? errorMessage : '朗读失败');
          this.stop();
        },
      });
      this.engine = engine;
      return true;
    } catch (error) {
      const message = (error as BusinessError).message ?? 'TTS 引擎初始化失败';
      hilog.error(0x0000, TAG, 'createEngine failed: %{public}s', message);
      this.reportError(message);
      this.initPromise = null;
      return false;
    }
  }

  private handleChunkComplete(): void {
    if (this.state !== 'playing') {
      return;
    }
    this.chunkIndex += 1;
    if (this.chunkIndex >= this.chunks.length) {
      const callback = this.chapterFinishedCallback;
      this.chunks = [];
      this.chunkIndex = 0;
      this.chapterFinishedCallback = null;
      this.setState('idle');
      if (callback !== null) {
        callback();
      }
      return;
    }
    this.speakCurrentChunk();
  }

  /** SDK 不支持运行时更新播放参数，调速/换音色只能停掉当前段再重读。 */
  private restartCurrentChunk(): void {
    if (this.engine === null) {
      return;
    }
    this.engine.stop();
    this.speakCurrentChunk();
  }

  private speakCurrentChunk(): void {
    if (this.engine === null || this.chunkIndex >= this.chunks.length) {
      return;
    }
    this.emitProgress();
    const text = this.chunks[this.chunkIndex];
    if (text.length === 0) {
      this.handleChunkComplete();
      return;
    }
    const speakParams: textToSpeech.SpeakParams = {
      requestId: `${Date.now()}_${Math.random().toString(36).substring(2, 8)}`,
      extraParams: {
        'queueMode': 0,
        'speed': this.speed,
        'volume': 1,
        'pitch': 1,
        'languageContext': 'zh-CN',
        'audioType': 'pcm',
        'soundChannel': 3,
        'playType': 1,
      },
    };
    try {
      this.engine.speak(text, speakParams);
    } catch (error) {
      const message = (error as BusinessError).message ?? '朗读失败';
      this.reportError(message);
      this.stop();
    }
  }

  private setState(state: ReaderTtsState): void {
    this.state = state;
    if (this.stateCallback !== null) {
      this.stateCallback(state);
    }
  }

  private emitProgress(): void {
    if (this.progressCallback === null) {
      return;
    }
    this.progressCallback({ chunkIndex: this.chunkIndex, totalChunks: this.chunks.length });
  }

  private reportError(message: string): void {
    if (this.errorCallback !== null) {
      this.errorCallback(message);
    }
  }

  private static voiceLabel(voice: textToSpeech.VoiceInfo): string {
    const parts: string[] = [];
    if (voice.description.length > 0) {
      parts.push(voice.description);
    }
    if (voice.style.length > 0 && voice.style !== voice.description) {
      parts.push(voice.style);
    }
    if (parts.length === 0) {
      parts.push(voice.person === DEFAULT_PERSON ? '默认音色' : `发音人 ${voice.person}`);
    }
    return parts.join(' · ');
  }

  private static clampSpeed(speed: number): number {
    if (speed < MIN_SPEED) {
      return MIN_SPEED;
    }
    if (speed > MAX_SPEED) {
      return MAX_SPEED;
    }
    return speed;
  }
}
