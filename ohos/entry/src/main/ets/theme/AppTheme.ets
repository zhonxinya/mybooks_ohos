import { ConfigurationConstant } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

export class AppTheme {
  static readonly pagePadding: number = 16;
  static readonly cardPadding: number = 12;
  static readonly cardRadius: number = 12;
  static readonly coverRadius: number = 8;

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  static applyThemeMode(context: common.UIAbilityContext, mode: string): void {
    // 同步发布墨水屏开关给全局组件：转圈类加载动画在墨水屏下会持续触发局部刷新，
    // 只产生残影与耗电，组件据此改为静态呈现（调用点：启动 onCreate 与设置页切换）
    AppStorage.setOrCreate('eink_mode', mode === 'eink');
    const appContext = context.getApplicationContext();
    // 墨水屏与浅色同样强制 COLOR_MODE_LIGHT：反射屏上白底黑字对比度最高，
    // 深色模式需要整屏涂黑，既费电又在刷新时闪黑，不适合墨水屏
    if (mode === 'light' || mode === 'eink') {
      appContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      return;
    }
    if (mode === 'dark') {
      appContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      return;
    }
    appContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
  }

  /**
   * 墨水屏整窗灰阶：彩色画面按亮度转灰（1=纯灰阶，0=恢复彩色），适配只有黑白灰的墨水屏面板。
   * 必须在窗口 loadContent 之后调用；设备能力不支持（801）或窗口异常时静默降级，
   * 「强制浅色」那一层仍然生效。
   * @throws 不向外抛出（内部已捕获）
   */
  static applyGrayScale(context: common.UIAbilityContext, mode: string): void {
    window.getLastWindow(context).then((win: window.Window) => {
      win.setWindowGrayScale(mode === 'eink' ? 1 : 0).catch(() => {});
    }).catch(() => {});
  }

  static themeModeLabel(mode: string): string {
    if (mode === 'light') {
      return '浅色';
    }
    if (mode === 'dark') {
      return '深色';
    }
    if (mode === 'eink') {
      return '墨水屏';
    }
    return '跟随系统';
  }

  static nextThemeMode(mode: string): string {
    if (mode === 'system') {
      return 'light';
    }
    if (mode === 'light') {
      return 'dark';
    }
    if (mode === 'dark') {
      return 'eink';
    }
    return 'system';
  }
}
