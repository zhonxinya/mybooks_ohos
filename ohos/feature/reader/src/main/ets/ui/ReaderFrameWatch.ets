import { FrameCallback, UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'ReaderFrameWatch';
/** 慢帧判定阈值（ms）：60fps 的单帧预算是 16.7ms，超过 26ms 就是明显掉帧。 */
const JANK_FRAME_MS: number = 26;
/** 采样窗口帧数，以及窗口内允许的慢帧数（超过就判定需要降级）。 */
const SAMPLE_FRAMES: number = 28;
const SLOW_FRAME_LIMIT: number = 9;
/**
 * 硬上限：即使调用方忘了 `stop()`（例如手势被打断后没走到结算分支），
 * 累计这么多帧后也强制停下，避免帧回调一直挂着耗电。
 */
const MAX_FRAMES: number = SAMPLE_FRAMES * 3;
/** 跟手延迟日志的最小间隔（ms）：拖动时不必每帧都打。 */
const LATENCY_LOG_INTERVAL_MS: number = 1000;

/**
 * 翻页交互期的帧耗时采样。
 *
 * 用 ArkUI 的帧回调（`UIContext.postFrameCallback`）而不是 `setInterval`：只有真正渲染出来的帧
 * 才会回调，采样结果直接对应「跟手是否掉帧」。采样只在拖拽/翻页动画期间进行（`start` / `stop`），
 * 闲时没有回调开销；计数跨多次交互累计，够一个窗口就给出一次判定。
 */
export class ReaderFrameWatch extends FrameCallback {
  private uiContext: UIContext | null = null;
  private onJank: () => void = () => {};
  private posted: boolean = false;
  private running: boolean = false;
  private lastNano: number = 0;
  private frames: number = 0;
  private slow: number = 0;
  private total: number = 0;
  /** 跟手延迟探针：手势事件时刻（ms，Date.now 口径），等下一帧回调时结算。 */
  private probeAt: number = 0;
  private lastLatencyLogAt: number = 0;

  /** 开始采样（可重复调用；已经在采样时只置运行标记）。 */
  start(uiContext: UIContext, onJank: () => void): void {
    this.uiContext = uiContext;
    this.onJank = onJank;
    if (this.posted) {
      this.running = true;
      return;
    }
    this.posted = true;
    this.running = true;
    this.lastNano = 0;
    uiContext.postFrameCallback(this);
  }

  /** 结束采样：帧回调链自行退出，计数保留到下一个窗口。 */
  stop(): void {
    this.running = false;
  }

  /**
   * 打一次「跟手延迟」探针：记录手势事件时刻，等下一帧渲染回调时算出
   * 「事件 → 该状态被渲染」的耗时（ms）。同一时刻只保留一个探针，不会排队。
   */
  probe(): void {
    // 没在采样（帧回调链已停）时不记探针：否则它会跨过 stop/start 等到下一轮，
    // 算出来的「延迟」会是几秒级的假数据。
    if (!this.running || this.probeAt !== 0) {
      return;
    }
    this.probeAt = Date.now();
  }

  onFrame(frameTimeInNano: number): void {
    if (!this.running) {
      this.posted = false;
      return;
    }
    if (this.probeAt > 0) {
      const latency: number = Date.now() - this.probeAt;
      this.probeAt = 0;
      const now: number = Date.now();
      if (now - this.lastLatencyLogAt >= LATENCY_LOG_INTERVAL_MS) {
        this.lastLatencyLogAt = now;
        hilog.debug(0x0000, TAG, '跟手延迟 %{public}d ms（手势事件→渲染帧）', latency);
      }
    }
    if (this.lastNano > 0) {
      const deltaMs = (frameTimeInNano - this.lastNano) / 1000000;
      this.frames++;
      this.total++;
      if (deltaMs > JANK_FRAME_MS) {
        this.slow++;
      }
      if (this.frames >= SAMPLE_FRAMES) {
        const janky = this.slow >= SLOW_FRAME_LIMIT;
        // debug 级别：默认不输出，需要排查掉帧时用 `hilog -L D` 抓窗口结论
        hilog.debug(0x0000, TAG, '翻页帧采样窗口结束：%{public}d 帧，慢帧 %{public}d', this.frames, this.slow);
        this.frames = 0;
        this.slow = 0;
        if (janky) {
          this.running = false;
          this.posted = false;
          this.onJank();
          return;
        }
      }
      if (this.total >= MAX_FRAMES) {
        this.running = false;
        this.posted = false;
        return;
      }
    }
    this.lastNano = frameTimeInNano;
    if (this.uiContext !== null) {
      this.uiContext.postFrameCallback(this);
    }
  }
}
