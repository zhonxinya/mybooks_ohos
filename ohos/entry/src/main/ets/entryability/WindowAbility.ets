import { window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'WindowAbility';

export class WindowAbility {
  private static readonly INSTANCE: WindowAbility = new WindowAbility();
  private context: common.UIAbilityContext | null = null;
  private windowStage: window.WindowStage | null = null;
  private windowClass: window.Window | null = null;
  private windowSizeListenerRegistered: boolean = false;

  private constructor() {
  }

  public static getInstance(): WindowAbility {
    return WindowAbility.INSTANCE;
  }

  initContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  setWindowStage(windowStage: window.WindowStage): void {
    this.windowStage = windowStage;
  }

  async initAvoidArea(mainWindow: window.Window): Promise<void> {
    AppStorage.setOrCreate<number>('statusBarHeight', 36);
    AppStorage.setOrCreate<number>('navigationAiBarHeight', 28);
    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      const scaledDensity = defaultDisplay.scaledDensity > 0 ? defaultDisplay.scaledDensity : 1;
      const systemArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const navArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      if (systemArea) {
        AppStorage.setOrCreate<number>('statusBarHeight', systemArea.topRect.height / scaledDensity);
      }
      if (navArea) {
        AppStorage.setOrCreate<number>('navigationAiBarHeight', navArea.bottomRect.height / scaledDensity);
      }
    } catch (error) {
      hilog.error(0x0000, TAG, `initAvoidArea failed: ${JSON.stringify(error)}`);
    }
  }

  initWindowSize(): void {
    if (!this.context) {
      return;
    }
    window.getLastWindow(this.context, (err, windowClass) => {
      if (err.code !== 0) {
        return;
      }
      const windowProperty = windowClass.getWindowProperties();
      AppStorage.setOrCreate<number>('windowWidth', windowProperty.windowRect.width);
      AppStorage.setOrCreate<number>('windowHeight', windowProperty.windowRect.height);
      this.windowClass = windowClass;
      this.onWindowSizeChange();
    });
  }

  onWindowSizeChange(callback?: () => void): void {
    if (!this.windowClass || this.windowSizeListenerRegistered) {
      return;
    }
    try {
      this.windowClass.on('windowSizeChange', (size: window.Size) => {
        AppStorage.setOrCreate<number>('windowWidth', size.width);
        AppStorage.setOrCreate<number>('windowHeight', size.height);
        if (callback !== undefined) {
          callback();
        }
      });
      this.windowSizeListenerRegistered = true;
    } catch (error) {
      hilog.error(0x0000, TAG, `onWindowSizeChange failed: ${JSON.stringify(error)}`);
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  async setWindowLayoutFullScreen(isFullScreen: boolean): Promise<void> {
    if (!this.context || deviceInfo.deviceType === '2in1') {
      return;
    }
    const wnd = await window.getLastWindow(this.context);
    await wnd.setWindowLayoutFullScreen(isFullScreen);
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  setOrientation(windowStage: window.WindowStage, orientation: window.Orientation): void {
    windowStage.getMainWindow().then((win) => {
      win.setPreferredOrientation(orientation);
    });
  }

  toggleWindowSystemBar(names: Array<'status' | 'navigation'>, windowContext: common.UIAbilityContext | undefined): void {
    if (!windowContext) {
      return;
    }
    window.getLastWindow(windowContext, (err, windowClass) => {
      if (err.code !== 0) {
        return;
      }
      windowClass.setWindowSystemBarEnable(names.length > 0 ? names : []).catch(() => {
        hilog.error(0x0000, TAG, 'toggleWindowSystemBar failed');
      });
    });
  }
}
