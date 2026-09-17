import { displaySync } from '@kit.ArkGraphics2D';

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
 * 帧源用 `displaySync` 而不是 `postFrameCallback`：除了拿到逐帧时间戳，还能用
 * `setExpectedFrameRateRange` 声明这一段动画期望的帧率，高刷屏（90/120Hz）上折痕才走得顺。
 *
 * 同一个动画器也负责回弹（`to` 传 0），用轻微过冲的弹簧曲线保留「纸被松开」的手感。
 */
export class ReaderFlipAnimator {
  private sync: displaySync.DisplaySync | null = null;
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
    if (this.sync !== null) {
      return;
    }
    try {
      const sync: displaySync.DisplaySync = displaySync.create();
      sync.setExpectedFrameRateRange(rate);
      sync.on('frame', this.frameHandler);
      sync.start();
      this.sync = sync;
    } catch (error) {
      // 拿不到帧源时不能把翻页卡住：直接把终值给出去，视觉上退化成瞬切
      this.running = false;
      this.apply(this.to);
      this.onDone();
    }
  }

  /** 立即中止（手势被打断、组件销毁）：不触发结束回调。 */
  cancel(): void {
    this.running = false;
    this.release();
  }

  private release(): void {
    const sync: displaySync.DisplaySync | null = this.sync;
    if (sync === null) {
      return;
    }
    this.sync = null;
    try {
      sync.stop();
      sync.off('frame', this.frameHandler);
    } catch (error) {
      // 释放失败不影响交互，下次动画会重建
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
