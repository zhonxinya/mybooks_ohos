import { media } from '@kit.MediaKit';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, Want, WantAgent, wantAgent } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AudioFileInfo, AudioInfoResponse } from '../common/ApiTypes';
import { TalebookApi } from './TalebookApi';
import { TalebookService } from './TalebookService';
import { CoverCache } from '../utils/CoverCache';

const TAG: string = 'AudioPlayback';
/** 播控中心会话标识：全应用只保留一个音频会话 */
const SESSION_TAG: string = 'mybooks_audiobook';
/** wantAgent 请求码：长时任务通知与播控中心卡片各用一个 */
const REQUEST_CODE_TASK: number = 0x1010;
const REQUEST_CODE_LAUNCH: number = 0x1011;
/** 进度上报节流：1s 一次，避免高频 IPC */
const POSITION_SYNC_MS: number = 1000;
/** 页面刷新节流：约 4fps，避免整页高频重建 */
const NOTIFY_THROTTLE_MS: number = 250;

/** 长时任务请求失败后的重试延时（系统要求"音频确实在播"才放行，首次可能还没起播） */
const TASK_RETRY_DELAY_MS: number = 800;

/** 播控中心卡片回跳播放页时携带的 want 参数名 */
const WANT_BOOK_ID: string = 'audioPlayerBookId';
const WANT_INDEX: string = 'audioPlayerIndex';
const WANT_TITLE: string = 'audioPlayerTitle';
const WANT_AUTHOR: string = 'audioPlayerAuthor';
const WANT_COVER: string = 'audioPlayerCover';

/** AppStorage 键：EntryAbility 收到回跳 want 后写入，MainTabs 消费后清空 */
export const AUDIO_LAUNCH_KEY: string = 'audioPlayerLaunch';

export interface AudioLaunchRequest {
  bookId: number;
  index: number;
  title: string;
  author: string;
  cover: string;
}

/** EntryAbility 收到播控中心卡片的 want 时调用：把回跳参数落到 AppStorage。 */
export function publishAudioLaunch(want: Want): void {
  const params = want.parameters;
  if (params === undefined) {
    return;
  }
  const bookId = Number(params[WANT_BOOK_ID] ?? 0);
  if (bookId <= 0) {
    return;
  }
  const request: AudioLaunchRequest = {
    bookId: bookId,
    index: Number(params[WANT_INDEX] ?? 0),
    title: String(params[WANT_TITLE] ?? ''),
    author: String(params[WANT_AUTHOR] ?? ''),
    cover: String(params[WANT_COVER] ?? ''),
  };
  AppStorage.setOrCreate(AUDIO_LAUNCH_KEY, JSON.stringify(request));
}

/** MainTabs 调用：取出并清空回跳请求，无请求时返回 null。 */
export function consumeAudioLaunch(): AudioLaunchRequest | null {
  const raw = AppStorage.get<string>(AUDIO_LAUNCH_KEY);
  if (raw === undefined || raw.length === 0) {
    return null;
  }
  AppStorage.setOrCreate(AUDIO_LAUNCH_KEY, '');
  try {
    return JSON.parse(raw) as AudioLaunchRequest;
  } catch (_error) {
    return null;
  }
}

export interface AudioPlaybackState {
  bookId: number;
  bookTitle: string;
  bookAuthor: string;
  bookCover: string;
  files: AudioFileInfo[];
  currentIndex: number;
  isPlaying: boolean;
  loading: boolean;
  trackLoading: boolean;
  currentTimeMs: number;
  durationMs: number;
  speed: number;
  errorMessage: string;
  /** 一次性提示（页面消费后由 consumeNotice 清空） */
  notice: string;
}

export type AudioPlaybackListener = (state: AudioPlaybackState) => void;

function emptyAudioState(): AudioPlaybackState {
  return {
    bookId: 0,
    bookTitle: '',
    bookAuthor: '',
    bookCover: '',
    files: [],
    currentIndex: 0,
    isPlaying: false,
    loading: true,
    trackLoading: false,
    currentTimeMs: 0,
    durationMs: 0,
    speed: 1,
    errorMessage: '',
    notice: '',
  };
}

/**
 * 听书播放器（全局单例）：持有 AVPlayer、后台长时任务与系统播控中心会话（AVSession）。
 * 页面只做状态绑定，离开页面不停止播放；App 退后台/锁屏靠 AUDIO_PLAYBACK 长时任务保活。
 */
export class AudioPlaybackService {
  private static readonly INSTANCE: AudioPlaybackService = new AudioPlaybackService();
  private context: common.UIAbilityContext | null = null;
  private avPlayer: media.AVPlayer | null = null;
  private session: avSession.AVSession | null = null;
  private taskRunning: boolean = false;
  private audioDir: string = '';
  private switching: boolean = false;
  /** 当前播放文件保持打开的 fd（AVPlayer 通过 fdSrc 播放本地文件）。 */
  private localFd: number = -1;
  private coverPixel: image.PixelMap | null = null;
  private coverSource: string = '';
  private finished: boolean = false;
  private lastNotifyAt: number = 0;
  private lastPositionSyncAt: number = 0;
  private listeners: AudioPlaybackListener[] = [];
  private state: AudioPlaybackState = emptyAudioState();

  private constructor() {
  }

  static getInstance(): AudioPlaybackService {
    return AudioPlaybackService.INSTANCE;
  }

  addListener(listener: AudioPlaybackListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  removeListener(listener: AudioPlaybackListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  currentState(): AudioPlaybackState {
    return this.state;
  }

  /** 取走一次性提示，返回后清空，避免重复弹相同 toast。 */
  consumeNotice(): string {
    const notice = this.state.notice;
    this.state.notice = '';
    return notice;
  }

  private notify(force: boolean = false): void {
    const now = Date.now();
    if (!force && now - this.lastNotifyAt < NOTIFY_THROTTLE_MS) {
      return;
    }
    this.lastNotifyAt = now;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i](this.state);
    }
  }

  private setNotice(message: string): void {
    this.state.notice = message;
    this.notify(true);
  }

  /**
   * 打开有声书并播放指定章节。
   * `resume=true` 表示"只是回到播放页"（播控中心/通知回跳），同一本书不打断当前播放；
   * 用户从音频文件列表点某一章进来时传 false，此时同一本书也要切到点的那一章。
   */
  /** @throws 内部调用可能抛出异常，由调用方处理 */
  async openBook(context: common.UIAbilityContext, bookId: number, title: string, author: string,
    cover: string, startIndex: number, resume: boolean = false): Promise<void> {
    this.context = context;
    if (bookId <= 0) {
      this.state.errorMessage = '缺少书籍参数';
      this.state.loading = false;
      this.notify(true);
      return;
    }
    if (this.state.bookId === bookId && this.state.files.length > 0) {
      const target = startIndex >= 0 && startIndex < this.state.files.length ? startIndex : this.state.currentIndex;
      if (!resume && target !== this.state.currentIndex) {
        await this.loadTrack(target);
        return;
      }
      this.state.loading = false;
      this.notify(true);
      return;
    }
    this.stopForSwitchBook();
    this.audioDir = `${context.filesDir}/audio/${bookId}`;
    this.state = emptyAudioState();
    this.state.bookId = bookId;
    this.state.bookTitle = title;
    this.state.bookAuthor = author;
    this.state.bookCover = cover;
    this.notify(true);
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.state.errorMessage = '请先配置 Talebook 服务器';
        return;
      }
      const rsp: AudioInfoResponse = await TalebookApi.getAudioList(bookId);
      const err = rsp.err ?? rsp.status ?? '';
      if (err.length > 0 && err !== 'ok' && err !== 'ready' && err !== 'available') {
        this.state.errorMessage = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '暂无音频文件';
        return;
      }
      this.state.files = rsp.audios ?? [];
      if (this.state.files.length === 0) {
        this.state.errorMessage = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '暂无音频文件';
        return;
      }
      const index = startIndex >= 0 && startIndex < this.state.files.length ? startIndex : 0;
      await this.loadTrack(index);
    } catch (error) {
      this.state.errorMessage = `加载失败：${error}`;
    } finally {
      this.state.loading = false;
      this.notify(true);
    }
  }

  /** 切到另一本书前彻底停掉上一本（会话与长时任务一并回收）。 */
  private stopForSwitchBook(): void {
    if (this.state.bookId === 0) {
      return;
    }
    this.finished = false;
    this.state.isPlaying = false;
    const player = this.avPlayer;
    if (player !== null) {
      try {
        player.pause();
      } catch (_error) {
      }
    }
    void this.stopBackgroundTask();
    void this.destroySession();
  }

  private async loadTrack(index: number): Promise<void> {
    if (index < 0 || index >= this.state.files.length || this.switching) {
      return;
    }
    this.switching = true;
    this.finished = false;
    this.state.trackLoading = true;
    this.state.currentIndex = index;
    this.state.currentTimeMs = 0;
    this.state.durationMs = 0;
    this.notify(true);
    try {
      const file = this.state.files[index];
      const path = await this.ensureLocalFile(file);
      if (this.avPlayer === null) {
        this.avPlayer = await media.createAVPlayer();
        this.bindPlayerEvents(this.avPlayer);
      } else {
        // AVPlayer 的 url/fdSrc 只能在 idle 态赋值，切曲前必须先 reset 回 idle
        await this.avPlayer.reset();
      }
      // AVPlayer 不接受 file:// 路径（实测报 401 "not fd:// or network address"），本地文件要用
      // fdSrc 传文件描述符；fd 在播放期间保持打开。赋 fdSrc 后播放器是**异步**进入 initialized
      // 的，所以这里不直接 prepare：交给 stateChange('initialized') 去驱动（同步 prepare 会报
      // "current state is not stopped or initialized, unsupport prepare operation"）。
      this.closeLocalFd();
      const opened = fs.openSync(path, fs.OpenMode.READ_ONLY);
      this.localFd = opened.fd;
      this.avPlayer.fdSrc = { fd: opened.fd };
      await this.ensureSession();
      await this.syncMetadata();
      this.cleanupDistantAudioFiles();
    } catch (error) {
      this.state.isPlaying = false;
      this.state.trackLoading = false;
      this.setNotice(`播放失败：${error}`);
    } finally {
      this.switching = false;
    }
  }

  private bindPlayerEvents(player: media.AVPlayer): void {
    player.on('stateChange', (state: media.AVPlayerState) => {
      if (state === 'initialized') {
        // 赋 fdSrc/url 之后播放器异步进入 initialized，必须等这个事件再 prepare。
        // prepare/play 在这版 SDK 里返回 void（非 Promise），失败通过 'error' 事件/error 态上报。
        player.prepare();
      } else if (state === 'prepared') {
        player.setSpeed(this.state.speed);
        player.play();
      } else if (state === 'playing') {
        this.state.isPlaying = true;
        this.state.trackLoading = false;
        this.finished = false;
        this.notify(true);
        void this.startBackgroundTask();
        void this.syncPlaybackState();
      } else if (state === 'paused') {
        this.state.isPlaying = false;
        this.state.trackLoading = false;
        this.notify(true);
        void this.stopBackgroundTask();
        void this.syncPlaybackState();
      } else if (state === 'completed') {
        this.state.isPlaying = false;
        void this.onTrackCompleted();
      } else if (state === 'stopped') {
        this.state.isPlaying = false;
        this.state.trackLoading = false;
        this.notify(true);
        void this.stopBackgroundTask();
        void this.syncPlaybackState();
      } else if (state === 'error') {
        this.state.isPlaying = false;
        this.state.trackLoading = false;
        this.notify(true);
        void this.stopBackgroundTask();
        void this.syncPlaybackState();
      }
    });
    player.on('timeUpdate', (time: number) => {
      this.state.currentTimeMs = time;
      this.notify();
      const now = Date.now();
      if (now - this.lastPositionSyncAt >= POSITION_SYNC_MS) {
        this.lastPositionSyncAt = now;
        void this.syncPlaybackState();
      }
    });
    player.on('durationUpdate', (duration: number) => {
      this.state.durationMs = duration;
      this.notify(true);
      void this.syncMetadata();
      void this.syncPlaybackState();
    });
    player.on('error', (err: BusinessError) => {
      this.state.isPlaying = false;
      this.state.trackLoading = false;
      this.setNotice(`播放错误：${err.message ?? err.code}`);
    });
  }

  /** 自动续播下一章；已是最后一章则停在完成态（可按播放键重头播）。 */
  private async onTrackCompleted(): Promise<void> {
    if (this.state.currentIndex < this.state.files.length - 1) {
      await this.loadTrack(this.state.currentIndex + 1);
      return;
    }
    this.finished = true;
    this.state.currentTimeMs = 0;
    this.notify(true);
    await this.stopBackgroundTask();
    const session = this.session;
    if (session !== null) {
      try {
        await session.setAVPlaybackState({
          state: avSession.PlaybackState.PLAYBACK_STATE_COMPLETED,
          speed: this.state.speed,
          position: { elapsedTime: 0, updateTime: Date.now() },
        });
      } catch (_error) {
      }
    }
  }

  play(): void {
    const player = this.avPlayer;
    if (player === null) {
      return;
    }
    if (this.finished) {
      this.finished = false;
      player.seek(0);
      this.state.currentTimeMs = 0;
    }
    player.play();
  }

  pause(): void {
    const player = this.avPlayer;
    if (player === null) {
      return;
    }
    player.pause();
  }

  toggle(): void {
    if (this.state.isPlaying) {
      this.pause();
    } else {
      this.play();
    }
  }

  next(): void {
    if (this.state.currentIndex < this.state.files.length - 1) {
      void this.loadTrack(this.state.currentIndex + 1);
    }
  }

  playIndex(index: number): void {
    if (index === this.state.currentIndex) {
      return;
    }
    void this.loadTrack(index);
  }

  previous(): void {
    if (this.state.currentIndex > 0) {
      void this.loadTrack(this.state.currentIndex - 1);
    }
  }

  seekToMs(positionMs: number): void {
    const player = this.avPlayer;
    if (player === null || this.state.durationMs <= 0) {
      return;
    }
    const target = Math.max(0, Math.min(this.state.durationMs, Math.round(positionMs)));
    this.finished = false;
    player.seek(target);
    this.state.currentTimeMs = target;
    this.notify(true);
    void this.syncPlaybackState();
  }

  seekToPercent(percent: number): void {
    if (this.state.durationMs <= 0) {
      return;
    }
    this.seekToMs(this.state.durationMs * percent / 100);
  }

  setSpeed(speed: number): void {
    const player = this.avPlayer;
    this.state.speed = speed;
    if (player !== null) {
      player.setSpeed(speed);
    }
    this.notify(true);
    void this.syncPlaybackState();
  }

  /** 播控中心「停止」：停播并回收会话，卡片随之消失。 */
  stop(): void {
    this.finished = false;
    this.state.isPlaying = false;
    this.state.trackLoading = false;
    const player = this.avPlayer;
    if (player !== null) {
      try {
        player.pause();
      } catch (_error) {
      }
    }
    this.notify(true);
    void this.stopBackgroundTask();
    void this.destroySession();
  }

  /** Ability 销毁时彻底释放：播放器、fd、会话、长时任务。 */
  release(): void {
    this.finished = false;
    this.state.isPlaying = false;
    const player = this.avPlayer;
    this.avPlayer = null;
    if (player !== null) {
      try {
        player.release();
      } catch (_error) {
      }
    }
    this.closeLocalFd();
    this.releaseCoverPixel();
    void this.stopBackgroundTask();
    void this.destroySession();
  }

  // ---------------- 系统播控中心（AVSession） ----------------

  private async ensureSession(): Promise<void> {
    if (this.session !== null) {
      return;
    }
    const context = this.context;
    if (context === null) {
      return;
    }
    try {
      const session = await avSession.createAVSession(context, SESSION_TAG, 'audio');
      this.bindRemoteCommands(session);
      const launchAgent = await this.buildWantAgent(REQUEST_CODE_LAUNCH, true);
      if (launchAgent !== null) {
        await session.setLaunchAbility(launchAgent);
      }
      await session.activate();
      this.session = session;
    } catch (error) {
      hilog.error(0x0000, TAG, `createAVSession failed: ${error}`);
    }
  }

  /** 播控中心/耳机/锁屏发来的控制命令，全部转成播放器动作；动作结果再回写状态。 */
  private bindRemoteCommands(session: avSession.AVSession): void {
    session.on('play', () => {
      this.play();
    });
    session.on('pause', () => {
      this.pause();
    });
    session.on('stop', () => {
      this.stop();
    });
    session.on('playNext', () => {
      this.next();
    });
    session.on('playPrevious', () => {
      this.previous();
    });
    session.on('seek', (time: number) => {
      this.seekToMs(time);
    });
    session.on('setSpeed', (speed: number) => {
      this.setSpeed(speed);
    });
  }

  private async destroySession(): Promise<void> {
    const session = this.session;
    this.session = null;
    if (session === null) {
      return;
    }
    try {
      await session.deactivate();
      await session.destroy();
    } catch (error) {
      hilog.warn(0x0000, TAG, `destroy session failed: ${error}`);
    }
  }

  /** 元数据：书名 + 章节名 + 作者 + 封面，供播控中心卡片展示。 */
  private async syncMetadata(): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    const chapter = this.chapterName();
    const metadata: avSession.AVMetadata = {
      assetId: `${this.state.bookId}-${this.state.currentIndex}`,
      title: this.state.bookTitle.length > 0 ? this.state.bookTitle : '有声书',
      subtitle: chapter,
      artist: this.state.bookAuthor,
      album: this.state.bookTitle,
      duration: this.state.durationMs,
    };
    const pixel = await this.coverPixelMap();
    if (pixel !== null) {
      metadata.mediaImage = pixel;
    }
    try {
      await session.setAVMetadata(metadata);
    } catch (error) {
      hilog.error(0x0000, TAG, `setAVMetadata failed: ${error}`);
    }
  }

  private async syncPlaybackState(): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    const playbackState: avSession.AVPlaybackState = {
      state: this.playbackStateOf(),
      speed: this.state.speed,
      position: { elapsedTime: this.state.currentTimeMs, updateTime: Date.now() },
      duration: this.state.durationMs,
    };
    try {
      await session.setAVPlaybackState(playbackState);
    } catch (error) {
      hilog.warn(0x0000, TAG, `setAVPlaybackState failed: ${error}`);
    }
  }

  private playbackStateOf(): avSession.PlaybackState {
    if (this.state.isPlaying) {
      return avSession.PlaybackState.PLAYBACK_STATE_PLAY;
    }
    if (this.state.trackLoading) {
      return avSession.PlaybackState.PLAYBACK_STATE_PREPARE;
    }
    return avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
  }

  /** 封面转 PixelMap：播控中心服务读不到应用沙箱路径，只能给位图。 */
  private async coverPixelMap(): Promise<image.PixelMap | null> {
    const context = this.context;
    const url = this.state.bookCover;
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
      if (!this.hasLocalFile(path)) {
        const envelope = await TalebookService.fetchImageCacheAsync(resolved, path);
        if (envelope.status < 200 || envelope.status >= 300) {
          return null;
        }
      }
      const source = image.createImageSource(path);
      if (source === null) {
        return null;
      }
      const pixel = await source.createPixelMap();
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

  private releaseCoverPixel(): void {
    const pixel = this.coverPixel;
    this.coverPixel = null;
    this.coverSource = '';
    if (pixel !== null) {
      try {
        pixel.release().catch((error: BusinessError) => {
          hilog.warn(0x0000, TAG, `release cover pixel failed: ${error}`);
        });
      } catch (_error) {
      }
    }
  }

  // ---------------- 后台长时任务 ----------------

  /** 申请 AUDIO_PLAYBACK 长时任务：系统要求必须先有 AVSession 且音频确实在播，否则被拒。 */
  private async startBackgroundTask(retry: boolean = true): Promise<void> {
    if (this.taskRunning) {
      return;
    }
    const context = this.context;
    if (context === null) {
      return;
    }
    await this.ensureSession();
    const agent = await this.buildWantAgent(REQUEST_CODE_TASK, false);
    if (agent === null) {
      return;
    }
    try {
      await this.requestContinuousTask(context, agent);
      this.taskRunning = true;
      hilog.info(0x0000, TAG, 'background task started');
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0000, TAG, `startBackgroundRunning failed: code=${err.code} msg=${err.message}`);
      if (retry && this.state.isPlaying) {
        // 首次失败多为"音频尚未真正起播"，稍后重试一次
        setTimeout(() => {
          if (this.state.isPlaying && !this.taskRunning) {
            void this.startBackgroundTask(false);
          }
        }, TASK_RETRY_DELAY_MS);
      }
    }
  }

  /**
   * 申请 AUDIO_PLAYBACK 长时任务。API 21 起长时任务的主类型与子类型必须成对匹配：
   * 已接入 AVSession 的音视频播放要用 MODE_AV_PLAYBACK_AND_RECORD + SUBMODE_AVSESSION_AUDIO_PLAYBACK
   * （该子类型由 AVSession 出通知，后台任务模块不再另发通知）；直接用旧的
   * BackgroundMode.AUDIO_PLAYBACK 会被判为 "The bgMode is invalid"（实测 9800005）。
   * API 22 以下没有这套枚举，回退旧接口。
   */
  private async requestContinuousTask(context: common.UIAbilityContext, agent: WantAgent): Promise<void> {
    if (deviceInfo.sdkApiVersion < 22) {
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      return;
    }
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
  }

  private async stopBackgroundTask(): Promise<void> {
    if (!this.taskRunning) {
      return;
    }
    this.taskRunning = false;
    const context = this.context;
    if (context === null) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
    } catch (error) {
      hilog.warn(0x0000, TAG, `stopBackgroundRunning failed: ${error}`);
    }
  }

  /**
   * 构建 WantAgent：长时任务通知点击回应用；播控中心卡片点击回播放页（带书籍参数）。
   * @throws 内部调用可能抛出异常，由调用方处理
   */
  private async buildWantAgent(requestCode: number, deepLink: boolean): Promise<WantAgent | null> {
    const context = this.context;
    if (context === null) {
      return null;
    }
    const want: Want = deepLink ? {
      bundleName: context.abilityInfo.bundleName,
      abilityName: context.abilityInfo.name,
      parameters: this.launchParameters(),
    } : {
      bundleName: context.abilityInfo.bundleName,
      abilityName: context.abilityInfo.name,
    };
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
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

  private launchParameters(): Record<string, Object> {
    const params: Record<string, Object> = {};
    params[WANT_BOOK_ID] = this.state.bookId;
    params[WANT_INDEX] = this.state.currentIndex;
    params[WANT_TITLE] = this.state.bookTitle;
    params[WANT_AUTHOR] = this.state.bookAuthor;
    params[WANT_COVER] = this.state.bookCover;
    return params;
  }

  // ---------------- 本地文件与缓存 ----------------

  /**
   * 服务端返回的 `filename` 是 `os.path.splitext()` 去掉扩展名后的名字，真实文件名（含
   * .mp3/.m4a 等）只在 `url` 字段里；拿 filename 直接请求会 500/404（已实测）。因此下载
   * 与落盘统一用 url 的最后一段。
   */
  private remoteName(file: AudioFileInfo): string {
    const url: string = file.url ?? '';
    const slash = url.lastIndexOf('/');
    const name = slash >= 0 ? url.substring(slash + 1) : url;
    return name.length > 0 ? name : file.filename;
  }

  private localPath(file: AudioFileInfo): string {
    return `${this.audioDir}/${this.remoteName(file)}`;
  }

  private hasLocalFile(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (_error) {
      return false;
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async ensureLocalFile(file: AudioFileInfo): Promise<string> {
    const path = this.localPath(file);
    if (this.hasLocalFile(path)) {
      return path;
    }
    try {
      if (!fs.accessSync(this.audioDir)) {
        fs.mkdirSync(this.audioDir, true);
      }
    } catch (_error) {
      fs.mkdirSync(this.audioDir, true);
    }
    const envelope = await TalebookService.downloadAudioFileAsync(this.state.bookId, this.remoteName(file), path);
    if (!TalebookService.isApiSuccess(envelope)) {
      throw new Error(envelope.error.length > 0 ? envelope.error : '下载失败');
    }
    if (!this.hasLocalFile(path)) {
      throw new Error('文件未写入');
    }
    return path;
  }

  /** 只保留当前曲目附近缓存，控制 audio 目录膨胀（后台播放期间也不会删掉正在播的文件） */
  private cleanupDistantAudioFiles(): void {
    if (this.state.files.length === 0 || this.audioDir.length === 0) {
      return;
    }
    const keep = new Set<string>();
    for (let i = Math.max(0, this.state.currentIndex - 1); i <= Math.min(this.state.files.length - 1, this.state.currentIndex + 1); i++) {
      keep.add(this.remoteName(this.state.files[i]));
    }
    try {
      if (!fs.accessSync(this.audioDir)) {
        return;
      }
      const names = fs.listFileSync(this.audioDir);
      for (let i = 0; i < names.length; i++) {
        const name = names[i];
        if (!keep.has(name)) {
          try {
            fs.unlinkSync(`${this.audioDir}/${name}`);
          } catch (_error) {
          }
        }
      }
    } catch (_error) {
    }
  }

  /** 关闭当前播放文件的 fd（AVPlayer 已 reset/release 后调用）。 */
  private closeLocalFd(): void {
    if (this.localFd < 0) {
      return;
    }
    try {
      fs.closeSync(this.localFd);
    } catch (_error) {
      // 已关闭或无效 fd：忽略
    }
    this.localFd = -1;
  }

  private chapterName(): string {
    const file = this.state.files[this.state.currentIndex];
    if (file === undefined) {
      return '';
    }
    if (file.filename.length > 0) {
      return file.filename;
    }
    return `音频 ${this.state.currentIndex + 1}`;
  }
}
