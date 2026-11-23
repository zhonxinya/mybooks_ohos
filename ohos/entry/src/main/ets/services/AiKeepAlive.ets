import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'AiKeepAlive';

/**
 * AI 流式请求存活期间的 dataTransfer 长时任务保活（#1639）。
 *
 * 现象：流式回复进行中应用进后台，系统掐断网络流量，rcp 传输超时 →
 * 会话以「AI 请求超时」中断。修复：请求在途即申请 DATA_TRANSFER 长时任务，
 * 后台网络保持可用；收敛（完成/出错/中断）即释放。
 *
 * 引用计数：工具多轮回路各自 begin/end 嵌套或平铺，仅首个 begin 申请、
 * 末个 end 释放；end 幂等（计数不下零）。
 * 已知取舍：stopBackgroundRunning 释放的是整个应用的长时任务——若音频
 * 播放先于流式结束而 stop，会连带释放本保活（低概率，统一引用计数待音频改造）。
 */
export class AiKeepAlive {
  private static refs: number = 0;
  private static running: boolean = false;
  /** 测试注入缝：harness 替换为计数函数；默认真实实现。 */
  static startFn: ((ctx: common.UIAbilityContext) => Promise<boolean>) | null = null;
  static stopFn: ((ctx: common.UIAbilityContext) => Promise<void>) | null = null;
  /** 最近一次成功申请的 context（end 释放用；begin 同步取保活上下文）。 */
  private static lastContext: common.UIAbilityContext | null = null;

  static begin(): void {
    AiKeepAlive.refs += 1;
    if (AiKeepAlive.refs > 1 || AiKeepAlive.running) {
      return;
    }
    let ctx: common.UIAbilityContext | null = null;
    try {
      // 同步调用取 context（异步续体里 getContext 不可靠，必须此刻取）
      ctx = getContext() as common.UIAbilityContext;
    } catch (_error) {
      ctx = null; // 非 UI 环境（harness/worker）：不申请，功能降级为修复前
    }
    if (ctx === null || ctx === undefined) {
      return;
    }
    AiKeepAlive.lastContext = ctx;
    AiKeepAlive.running = true;
    const fn: (c: common.UIAbilityContext) => Promise<boolean> =
      AiKeepAlive.startFn !== null ? AiKeepAlive.startFn : AiKeepAlive.realStart;
    fn(ctx).then((ok: boolean) => {
      if (!ok) {
        AiKeepAlive.running = false;
      }
    }).catch((e: Error) => {
      hilog.warn(0x0000, TAG, `startBackgroundRunning failed: ${e.message}`);
      AiKeepAlive.running = false;
    });
  }

  static end(): void {
    if (AiKeepAlive.refs > 0) {
      AiKeepAlive.refs -= 1;
    }
    if (AiKeepAlive.refs > 0 || !AiKeepAlive.running) {
      return;
    }
    const ctx = AiKeepAlive.lastContext;
    AiKeepAlive.running = false;
    if (ctx === null) {
      return;
    }
    const fn: (c: common.UIAbilityContext) => Promise<void> =
      AiKeepAlive.stopFn !== null ? AiKeepAlive.stopFn : AiKeepAlive.realStop;
    fn(ctx).catch((e: Error) => {
      // 释放失败仅记日志：应用退出/切前台时系统会兜底回收
      hilog.warn(0x0000, TAG, `stopBackgroundRunning failed: ${e.message}`);
    });
  }

  /** 当前申请中引用数（harness 断言配对用）。 */
  static refCount(): number {
    return AiKeepAlive.refs;
  }

  private static async realStart(ctx: common.UIAbilityContext): Promise<boolean> {
    const agent: WantAgent | null = await AiKeepAlive.buildWantAgent(ctx);
    if (agent === null) {
      return false;
    }
    // 板上实测（API 24 模拟器镜像）：dataTransfer 三种登记形态均被系统拒绝
    // （9800005），真机支持；申请失败仅记日志，功能优雅降级为修复前行为
    await backgroundTaskManager.startBackgroundRunning(ctx,
      backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
    hilog.info(0x0000, TAG, 'dataTransfer keep-alive started');
    return true;
  }

  private static async realStop(ctx: common.UIAbilityContext): Promise<void> {
    await backgroundTaskManager.stopBackgroundRunning(ctx);
    hilog.info(0x0000, TAG, 'dataTransfer keep-alive stopped');
  }

  private static async buildWantAgent(ctx: common.UIAbilityContext): Promise<WantAgent | null> {
    const info: wantAgent.WantAgentInfo = {
      wants: [{ bundleName: ctx.abilityInfo.bundleName, abilityName: ctx.abilityInfo.name }],
      operationType: wantAgent.OperationType.START_ABILITIES,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    };
    try {
      return await wantAgent.getWantAgent(info);
    } catch (error) {
      hilog.error(0x0000, TAG, `getWantAgent failed: ${error}`);
      return null;
    }
  }
}
