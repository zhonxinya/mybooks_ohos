import { media } from '@kit.MediaKit';
import { common, Want } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AudioFileInfo, AudioInfoResponse } from '../common/ApiTypes';
import { TalebookApi } from './TalebookApi';
import { TalebookService } from './TalebookService';
import { CoverCache } from '../utils/CoverCache';
import { AudioPlatformOhos } from './AudioPlatformOhos';
import { AudioPlatformAndroid } from './AudioPlatformAndroid';
import { PlatformTarget } from '../common/PlatformTarget';

const TAG: string = 'AudioPlayback';
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

  /**
   * 按目标平台挑选平台层实现。
   *
   * ArkUI-X 的 Android 端没有 AVSession / 后台长时任务，落到降级实现
   * （前台播放可用，退后台不保活）；鸿蒙端用完整实现。
   */
  private static createPlatform(): AudioPlatformOhos | AudioPlatformAndroid {
    return PlatformTarget.isAndroid() ? AudioPlatformAndroid.getInstance() : AudioPlatformOhos.getInstance();
  }

  private context: common.UIAbilityContext | null = null;
  private avPlayer: media.AVPlayer | null = null;
  /**
   * 平台能力委托（AVSession / 后台长时任务 / 封面解码）。
   * 两个实现的方法签名一致，主服务因此不含任何鸿蒙专属 API。
   */
  private platform: AudioPlatformOhos | AudioPlatformAndroid = AudioPlaybackService.createPlatform();
  private audioDir: string = '';
  private switching: boolean = false;
  /** 当前播放文件保持打开的 fd（AVPlayer 通过 fdSrc 播放本地文件）。 */
  private localFd: number = -1;
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
    void this.platform.stopBackgroundTask(this.context ?? null);
    void this.platform.destroySession();
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
      const context = this.context;
      if (context === null) {
        return;
      }
      await this.platform.ensureSession(context, this.state, this.state.bookCover,
        () => this.play(), () => this.pause(), () => this.next(), () => this.previous(),
        (posMs: number) => this.seekToMs(posMs));
      await this.platform.syncMetadata(this.state, this.state.bookCover);
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
        void this.platform.startBackgroundTask(this.context ?? null, this.state);
        void this.platform.syncPlaybackState(this.state, false);
      } else if (state === 'paused') {
        this.state.isPlaying = false;
        this.state.trackLoading = false;
        this.notify(true);
        void this.platform.stopBackgroundTask(this.context ?? null);
        void this.platform.syncPlaybackState(this.state, false);
      } else if (state === 'completed') {
        this.state.isPlaying = false;
        void this.onTrackCompleted();
      } else if (state === 'stopped') {
        this.state.isPlaying = false;
        this.state.trackLoading = false;
        this.notify(true);
        void this.platform.stopBackgroundTask(this.context ?? null);
        void this.platform.syncPlaybackState(this.state, false);
      } else if (state === 'error') {
        this.state.isPlaying = false;
        this.state.trackLoading = false;
        this.notify(true);
        void this.platform.stopBackgroundTask(this.context ?? null);
        void this.platform.syncPlaybackState(this.state, false);
      }
    });
    player.on('timeUpdate', (time: number) => {
      this.state.currentTimeMs = time;
      this.notify();
      const now = Date.now();
      if (now - this.lastPositionSyncAt >= POSITION_SYNC_MS) {
        this.lastPositionSyncAt = now;
        void this.platform.syncPlaybackState(this.state, false);
      }
    });
    player.on('durationUpdate', (duration: number) => {
      this.state.durationMs = duration;
      this.notify(true);
      void this.platform.syncMetadata(this.state, '');
      void this.platform.syncPlaybackState(this.state, false);
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
    await this.platform.stopBackgroundTask(this.context ?? null);
    await this.platform.syncPlaybackState(this.state, true);
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
    void this.platform.syncPlaybackState(this.state, false);
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
    void this.platform.syncPlaybackState(this.state, false);
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
    void this.platform.stopBackgroundTask(this.context ?? null);
    void this.platform.destroySession();
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
    this.platform.releaseCoverPixel();
    void this.platform.stopBackgroundTask(this.context ?? null);
    void this.platform.destroySession();
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
