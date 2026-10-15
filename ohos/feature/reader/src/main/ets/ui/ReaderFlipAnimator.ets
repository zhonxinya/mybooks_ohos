import { displaySync } from '@kit.ArkGraphics2D';
import { FrameCallback, UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'ReaderFlipAnimator';

/**
 * `displaySync` 是否可用（模块级缓存，探测一次）。
 * ArkUI-X 的 Android 端没有该插件（`graphics_displaysync` 在 SDK 中不存在），
 * 首次调用即抛 `Cannot read property create of undefined`；缓存后不再重复尝试，
 * 避免每次翻页都刷一条异常日志。
 */
let displaySyncUnavailable: boolean = false;

/**
 * 翻页动画自驱动（按帧显式推进 `dragOffset`）。
 *
 * **为什么不用 `animateTo`**：仿真翻页的每一帧画面都由 `dragOffset` 现算出来——折痕曲线、
 * 裁剪路径 `PathShape.commands`、三条渐变带的坐标，全是普通数值，不是组件的可动画属性。
 * `animateTo` 只对「能插值的属性」逐帧插值，构建函数不会带着中间值重跑：实测一次 6s 的
 * 仿真翻页动画里，几何只被算了 2 次（抬手后 7ms 那一帧就是**终值**，下一次已经是结束回调）。
 * 现象是「抬手后纸面一直卡在卷到底的样子，直到动画结束才跳到新页」——拖拽跟手正常，
 * 抬手后的卷曲却根本不动。这里改成每帧显式赋值：每帧都是一次普通状态变更，构建必然重跑，
 * 折痕才会真的从一端扫到另一端。
 *
 * 帧源按可用性分三级（见 `start`）：
 * 1. 鸿蒙：`displaySync`——除逐帧时间戳外还能用 `setExpectedFrameRateRange` 声明期望帧率，
 *    高刷屏（90/120Hz）上折痕才走得顺；
 * 2. Android：`UIContext.postFrameCallback`——该 SDK 没有 `graphics_displaysync`，
 *    但跨端引擎实现了 `postFrameCallback`（`ReaderFrameWatch` 已在两端用它采帧）。
 *    它与渲染同步出帧，且动画结束后帧链自然断开；
 * 3. 兜底：`setInterval(16ms)`——只在拿不到 UIContext 时用（构造顺序异常等），
 *    不保证与 vsync 对齐。
 *
 * 同一个动画器也负责回弹（`to` 传 0），用轻微过冲的弹簧曲线保留「纸被松开」的手感。
 */
export class ReaderFlipAnimator extends FrameCallback {
  private sync: displaySync.DisplaySync | null = null;
  /** 定时器帧源（最后兜底的退化路径，见 `start`）。 */
  private timerId: number = -1;
  /** 帧回调帧源所需的 UIContext（Android 走这条）；未注入时退回定时器。 */
  private uiContext: UIContext | null = null;
  /** 是否已投递下一帧（避免一次重入里重复投递）。 */
  private framePosted: boolean = false;
  /** 定时器帧间隔：约 60Hz。 */
  private static readonly TIMER_FRAME_MS: number = 16;
  private running: boolean = false;
  private startNano: number = 0;
  private durationMs: number = 1;
  private from: number = 0;
  private to: number = 0;
  private spring: boolean = false;
  private apply: (value: number) => void = (): void => {};
  private onDone: () => void = (): void => {};
  /** 帧回调只需注册一次，实例内固定。 */
  private frameHandler: (info: displaySync.IntervalInfo) => void =
    (info: displaySync.IntervalInfo): void => {
      this.step(info.timestamp);
    };

  /** 是否正在跑（翻页结算用它防重入）。 */
  isRunning(): boolean {
    return this.running;
  }

  /**
   * 起一段动画。
   *
   * @param rate 期望帧率范围（高刷屏适配）
   * @param from 起始位移（vp）
   * @param to 结束位移（vp）
   * @param durationMs 时长（ms）
   * @param spring true = 回弹（带一点点过冲），false = 翻页（单调减速）
   * @param apply 每帧回调，参数是本帧的位移
   * @param onDone 结束回调（只会调用一次）
   */
  start(
    rate: ExpectedFrameRateRange,
    from: number,
    to: number,
    durationMs: number,
    spring: boolean,
    apply: (value: number) => void,
    onDone: () => void,
  ): void {
    this.from = from;
    this.to = to;
    this.durationMs = durationMs > 0 ? durationMs : 1;
    this.spring = spring;
    this.apply = apply;
    this.onDone = onDone;
    this.startNano = 0;
    this.running = true;
    if (this.sync !== null || this.timerId >= 0 || this.framePosted) {
      return;
    }
    if (!displaySyncUnavailable) {
      try {
        const sync: displaySync.DisplaySync = displaySync.create();
        sync.setExpectedFrameRateRange(rate);
        sync.on('frame', this.frameHandler);
        sync.start();
        this.sync = sync;
        return;
      } catch (error) {
        displaySyncUnavailable = true;
      }
    }
    // Android（无 displaySync）：用帧回调当帧源，与渲染同步出帧，动画结束后帧链自动断开
    if (this.uiContext !== null) {
      hilog.debug(0x0000, TAG, '帧源=frameCallback');
      this.scheduleFrame();
      return;
    }
    // 兜底：定时器帧源，动画照旧逐帧推进（本类每帧显式赋值，不依赖系统帧回调）
    hilog.debug(0x0000, TAG, '帧源=timer（未注入 UIContext）');
    this.timerId = setInterval(() => {
      this.step(Date.now() * 1000000);
    }, ReaderFlipAnimator.TIMER_FRAME_MS);
  }

  /**
   * 注入 UIContext（宿主在 `aboutToAppear` 调一次）。
   *
   * 只有拿不到 `displaySync` 的平台才需要它——Android 用它投递逐帧回调当帧源。
   */
  attachUiContext(uiContext: UIContext): void {
    this.uiContext = uiContext;
  }

  onFrame(frameTimeInNano: number): void {
    this.framePosted = false;
    if (!this.running) {
      return;
    }
    this.step(frameTimeInNano);
    // 动画已结束（step 里清了 running）就不再续投，帧链自然断开
    this.scheduleFrame();
  }

  /** 投递下一帧；已在途或已结束则不重复投递。 */
  private scheduleFrame(): void {
    const ui: UIContext | null = this.uiContext;
    if (!this.running || this.framePosted || ui === null) {
      return;
    }
    this.framePosted = true;
    ui.postFrameCallback(this);
  }

  /** 立即中止（手势被打断、组件销毁）：不触发结束回调。 */
  cancel(): void {
    this.running = false;
    this.release();
  }

  private release(): void {
    this.framePosted = false;
    const sync: displaySync.DisplaySync | null = this.sync;
    if (sync !== null) {
      this.sync = null;
      try {
        sync.stop();
        sync.off('frame', this.frameHandler);
      } catch (error) {
        // 释放失败不影响交互，下次动画会重建
      }
    }
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  /** 单帧推进。 */
  private step(timestampNano: number): void {
    if (!this.running) {
      this.release();
      return;
    }
    if (this.startNano === 0) {
      // 第一帧只记录起点：displaySync 给的是帧到达时间，用它算进度比 Date.now 更贴近实际出帧
      this.startNano = timestampNano;
    }
    const elapsedMs: number = (timestampNano - this.startNano) / 1000000;
    const t: number = Math.min(1, Math.max(0, elapsedMs / this.durationMs));
    if (t >= 1) {
      this.running = false;
      this.apply(this.to);
      this.release();
      this.onDone();
      return;
    }
    const eased: number = this.spring ? springEase(t) : easeOutCubic(t);
    this.apply(this.from + (this.to - this.from) * eased);
  }
}

/** 翻页：越走越慢（纸被甩出去后落定），起步就是全速。 */
function easeOutCubic(t: number): number {
  const u: number = 1 - t;
  return 1 - u * u * u;
}

/**
 * 回弹：轻微欠阻尼的弹簧阶跃响应 `1 - e^(-9t)·cos(7t)`。
 * 过冲约 3.4%（纸上被按住的角松手后会略微弹过原位再落回），收尾干净。
 */
function springEase(t: number): number {
  return 1 - Math.exp(-9 * t) * Math.cos(7 * t);
}
