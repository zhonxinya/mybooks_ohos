import { media } from '@kit.MediaKit';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, Want, WantAgent, wantAgent } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AudioFileInfo, AudioInfoResponse } from '../common/ApiTypes';
import { AudioPlaybackState } from './AudioPlaybackService';
import { CoverCache } from '../utils/CoverCache';
import { TalebookService } from './TalebookService';

const TAG: string = 'AudioPlatformOhos';
const SESSION_TAG: string = 'mybooks_audio';
const WANT_COVER: string = 'cover';
const WANT_TITLE: string = 'title';
const WANT_AUTHOR: string = 'author';
const WANT_LAUNCH_MODE: string = 'launchMode';
const WANT_LAUNCH_TYPE: string = 'type';
const WANT_VALUE_BOOK: string = 'mybooks.audio.book';

/** wantAgent 请求码：长时任务通知与播控中心卡片各用一个 */
const AGENT_REQ_CODE_SESSION: number = 1001;
const AGENT_REQ_CODE_CONTINUOUS: number = 1002;

/**
 * 音频播放的平台层（**仅鸿蒙编译**）。
 *
 * 承载三类只有鸿蒙才有的系统能力：
 * 1. `AVSession` —— 系统播控中心（锁屏/通知栏/耳机按键）；
 * 2. `AUDIO_PLAYBACK` 长时任务 —— App 退后台后继续播放；
 * 3. `image.PixelMap` —— 把网络封面解码成供播控卡片使用的位图。
 *
 * `AudioPlaybackService` 只依赖本类暴露的语义方法，因此主服务不含任何鸿蒙专属 API。
 * Android 端对应实现见 `AudioPlatformAndroid`：ArkUI-X 没有 AVSession / 长时任务，
 * 该端改为「前台播放 + 系统媒体通知」，能力有降级，故本类所有方法在 Android 端都是空实现。
 */
export class AudioPlatformOhos {
  private static readonly INSTANCE: AudioPlatformOhos = new AudioPlatformOhos();
  private session: avSession.AVSession | null = null;
  private taskRunning: boolean = false;
  private coverPixel: image.PixelMap | null = null;
  private coverSource: string = '';
  /** 最近一次 ensureSession 传入的上下文：封面下载与长时任务起停都要用。 */
  private lastContext: common.UIAbilityContext | null = null;

  static getInstance(): AudioPlatformOhos {
    return AudioPlatformOhos.INSTANCE;
  }

  // ---------------- AVSession（播控中心） ----------------

  async ensureSession(context: common.UIAbilityContext | null, state: AudioPlaybackState,
    coverUrl: string,
    onPlay: () => void, onPause: () => void, onNext: () => void, onPrev: () => void,
    onSeek: (posMs: number) => void): Promise<void> {
    this.lastContext = context;
    if (this.session !== null) {
      return;
    }
    if (context === null) {
      return;
    }
    try {
      const session = await avSession.createAVSession(context, SESSION_TAG, 'audio');
      this.session = session;
      this.bindRemoteCommands(session, onPlay, onPause, onNext, onPrev, onSeek);
      await this.syncMetadata(state, coverUrl);
      await this.syncPlaybackState(state, false);
    } catch (error) {
      hilog.error(0x0000, TAG, `createAVSession failed: ${error}`);
    }
  }

  private bindRemoteCommands(session: avSession.AVSession, onPlay: () => void, onPause: () => void,
    onNext: () => void, onPrev: () => void, onSeek: (posMs: number) => void): void {
    try {
      session.on('play', onPlay);
      session.on('pause', onPause);
      session.on('playNext', onNext);
      session.on('playPrevious', onPrev);
      session.on('seek', (posMs: number) => onSeek(posMs));
    } catch (error) {
      hilog.error(0x0000, TAG, `bindRemoteCommands failed: ${error}`);
    }
  }

  async destroySession(): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    this.session = null;
    try {
      await session.off('play');
      await session.off('pause');
      await session.off('playNext');
      await session.off('playPrevious');
      await session.off('seek');
      await session.deactivate();
      await session.destroy();
    } catch (error) {
      hilog.error(0x0000, TAG, `release session failed: ${error}`);
    }
  }

  async syncMetadata(state: AudioPlaybackState, coverUrl: string): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    try {
      const metadata: avSession.AVMetadata = {
        assetId: `${state.bookId}-${state.currentIndex}`,
        title: state.bookTitle.length > 0 ? state.bookTitle : '有声书',
        subtitle: this.chapterNameOf(state),
        artist: state.bookAuthor,
        album: state.bookTitle,
        duration: state.durationMs,
      };
      if (coverUrl.length > 0) {
        const pixel = await this.coverPixelMap(coverUrl);
        if (pixel !== null) {
          metadata.mediaImage = pixel;
        }
      }
      await session.setAVMetadata(metadata);
    } catch (error) {
      hilog.error(0x0000, TAG, `setMetadata failed: ${error}`);
    }
  }

  /** 章节名 = 当前轨道的服务端文件名（已去扩展名），空时回退书名。 */
  private chapterNameOf(state: AudioPlaybackState): string {
    const file = state.files[state.currentIndex] as AudioFileInfo | undefined;
    if (file === undefined) {
      return state.bookTitle;
    }
    const name: string = file.filename ?? '';
    return name.length > 0 ? name : state.bookTitle;
  }

  async syncPlaybackState(state: AudioPlaybackState, completed: boolean): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    try {
      const playbackState: avSession.AVPlaybackState = {
        state: completed ? avSession.PlaybackState.PLAYBACK_STATE_COMPLETED : this.playbackStateOf(state),
        speed: state.speed,
        position: { elapsedTime: state.currentTimeMs, updateTime: Date.now() },
        duration: state.durationMs,
      };
      await session.setAVPlaybackState(playbackState);
    } catch (error) {
      hilog.error(0x0000, TAG, `setPlaybackState failed: ${error}`);
    }
  }

  private playbackStateOf(state: AudioPlaybackState): avSession.PlaybackState {
    if (state.isPlaying) {
      return avSession.PlaybackState.PLAYBACK_STATE_PLAY;
    }
    if (state.durationMs <= 0) {
      return avSession.PlaybackState.PLAYBACK_STATE_PREPARE;
    }
    return avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
  }

  // ---------------- 后台长时任务 ----------------

  async startBackgroundTask(context: common.UIAbilityContext | null, state: AudioPlaybackState): Promise<void> {
    if (this.taskRunning || context === null || this.session === null) {
      return;
    }
    const agent = await this.buildWantAgent(AGENT_REQ_CODE_CONTINUOUS, false);
    if (agent === null) {
      return;
    }
    try {
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      this.taskRunning = true;
      // 部分设备要求再加一层连续任务（AVSession 型）才真正保活
      await this.requestContinuousTask(context, agent);
    } catch (error) {
      hilog.error(0x0000, TAG, `startBackgroundRunning failed: ${error}`);
    }
  }

  private async requestContinuousTask(context: common.UIAbilityContext, agent: WantAgent): Promise<void> {
    if (deviceInfo.sdkApiVersion < 22) {
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      return;
    }
    try {
      const modes: backgroundTaskManager.BackgroundTaskMode[] = [
        backgroundTaskManager.BackgroundTaskMode.MODE_AV_PLAYBACK_AND_RECORD,
      ];
      const subModes: backgroundTaskManager.BackgroundTaskSubmode[] = [
        backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_AVSESSION_AUDIO_PLAYBACK,
      ];
      const request = new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = modes;
      request.backgroundTaskSubmodes = subModes;
      request.wantAgent = agent;
      await backgroundTaskManager.startBackgroundRunning(context, request);
    } catch (error) {
      hilog.error(0x0000, TAG, `requestContinuousTask failed: ${error}`);
    }
  }

  async stopBackgroundTask(context: common.UIAbilityContext | null): Promise<void> {
    if (!this.taskRunning || context === null) {
      return;
    }
    this.taskRunning = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
    } catch (error) {
      hilog.error(0x0000, TAG, `stopBackgroundRunning failed: ${error}`);
    }
  }

  private async buildWantAgent(requestCode: number, deepLink: boolean): Promise<WantAgent | null> {
    const context = this.lastContext;
    if (context === null) {
      return null;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [this.launchWant(context, deepLink)],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: requestCode,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      };
      return await wantAgent.getWantAgent(info);
    } catch (error) {
      hilog.error(0x0000, TAG, `getWantAgent failed: ${error}`);
      return null;
    }
  }

  private launchWant(context: common.UIAbilityContext, deepLink: boolean): Want {
    // 深链回跳要带书籍参数才能定位到播放页；普通保活通知不带参数
    if (deepLink) {
      const want: Want = {
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name,
        parameters: this.launchParameters(),
      };
      return want;
    }
    const plain: Want = {
      bundleName: context.abilityInfo.bundleName,
      abilityName: context.abilityInfo.name,
    };
    return plain;
  }

  private launchParameters(): Record<string, Object> {
    const params: Record<string, Object> = {};
    params[WANT_COVER] = '';
    params[WANT_TITLE] = '';
    params[WANT_AUTHOR] = '';
    params[WANT_LAUNCH_MODE] = 'audio';
    params[WANT_LAUNCH_TYPE] = WANT_VALUE_BOOK;
    return params;
  }

  // ---------------- 封面位图 ----------------

  /**
   * 把封面（可能是网络 URL）解码成 PixelMap，供播控卡片展示。
   *
   * 播控中心服务读不到应用沙箱路径，只能给位图。流程与原实现一致：
   * 解析真实地址 → 算缓存路径 → 未命中则下载 → 解码，并按 URL 缓存结果避免重复解码。
   */
  async coverPixelMap(url: string): Promise<image.PixelMap | null> {
    const context = this.lastContext;
    if (context === null || url.length === 0) {
      return null;
    }
    if (this.coverPixel !== null && this.coverSource === url) {
      return this.coverPixel;
    }
    try {
      CoverCache.ensureDir(context);
      const resolved = TalebookService.resolveCoverUrl(url);
      const path = CoverCache.pathFor(context, resolved);
      if (!CoverCache.isPresent(path)) {
        const envelope = await TalebookService.fetchImageCacheAsync(resolved, path);
        if (envelope.status < 200 || envelope.status >= 300) {
          return null;
        }
      }
      const source = image.createImageSource(path);
      if (source === null) {
        return null;
      }
      // 播控中心卡片封面只用到 ~300px，按显示尺寸解码避免全分辨率占内存
      const pixel = await source.createPixelMap({
        desiredSize: { width: 300, height: 300 },
      });
      await source.release();
      this.releaseCoverPixel();
      this.coverPixel = pixel;
      this.coverSource = url;
      return pixel;
    } catch (error) {
      hilog.warn(0x0000, TAG, `cover pixel map failed: ${error}`);
      return null;
    }
  }

  releaseCoverPixel(): void {
    const pixel = this.coverPixel;
    this.coverPixel = null;
    this.coverSource = '';
    if (pixel === null) {
      return;
    }
    try {
      pixel.release();
    } catch (_error) {
    }
  }

  /** 释放本层全部资源（与主服务 release 对齐）。 */
  releaseAll(context: common.UIAbilityContext | null): void {
    this.releaseCoverPixel();
    void this.stopBackgroundTask(context);
    void this.destroySession();
  }
}
