import { common } from '@kit.AbilityKit';

/**
 * 听书播放状态（跨端共享）。
 *
 * 原先定义在 `AudioPlaybackService` 内，为让 `AudioPlatformOhos` / `AudioPlatformAndroid`
 * 都能引用而不产生循环依赖，单独抽到本文件。
 */
export interface AudioPlaybackState {
  bookId: number;
  bookTitle: string;
  bookAuthor: string;
  bookCover: string;
  files: Object[];
  currentIndex: number;
  isPlaying: boolean;
  currentTimeMs: number;
  durationMs: number;
  loading: boolean;
  trackLoading: boolean;
  speed: number;
  notice: string;
  errorMessage: string;
}

/**
 * 音频播放的平台层（**Android 降级实现**）。
 *
 * ArkUI-X 的 Android 端不提供：
 * - `avSession.AVSession` —— 无系统播控中心会话；
 * - `backgroundTaskManager.startBackgroundRunning` —— 无鸿蒙长时任务；
 * - `image.createImageSource(...).createPixelMap` —— 无鸿蒙 PixelMap 解码链。
 *
 * 因此本端**不再提供**「后台播放 + 锁屏播控」能力：所有平台层方法均为空实现，
 * 播放本身仍在 `AudioPlaybackService` 内完成（App 处于前台时功能完整）。
 * 这是一次**能力降级**而非崩溃 —— 播放页照常可用，只是退到后台会被系统回收。
 *
 * 若需在 Android 上补齐该能力，正确路径是用 Android 原生的
 * `MediaSession` + `MediaBrowserService` + `MediaStyle` 通知，
 * 通过 `@arkui-x.android` 桥接接入，而不是在鸿蒙 API 上做条件编译。
 */
export class AudioPlatformAndroid {
  private static readonly INSTANCE: AudioPlatformAndroid = new AudioPlatformAndroid();

  static getInstance(): AudioPlatformAndroid {
    return AudioPlatformAndroid.INSTANCE;
  }

  /** 无播控中心会话，无需建立。 */
  async ensureSession(_context: common.UIAbilityContext | null, _state: AudioPlaybackState,
    _coverUrl: string,
    _onPlay: () => void, _onPause: () => void, _onNext: () => void, _onPrev: () => void,
    _onSeek: (posMs: number) => void): Promise<void> {
  }

  async destroySession(): Promise<void> {
  }

  async syncMetadata(_state: AudioPlaybackState, _coverPath: string): Promise<void> {
  }

  async syncPlaybackState(_state: AudioPlaybackState, _completed: boolean): Promise<void> {
  }

  async startBackgroundTask(_context: common.UIAbilityContext | null, _state: AudioPlaybackState): Promise<void> {
  }

  async stopBackgroundTask(_context: common.UIAbilityContext | null): Promise<void> {
  }

  /** 无 PixelMap 解码链，返回空。 */
  async coverPixelMap(_path: string): Promise<null> {
    return null;
  }

  releaseCoverPixel(): void {
  }

  releaseAll(_context: common.UIAbilityContext | null): void {
  }
}
