/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

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
  private windowType: window.WindowStatusType | null = null;

  private constructor() {
  }

  public static getInstance(): WindowAbility {
    return WindowAbility.INSTANCE;
  }

  initContext(context: common.UIAbilityContext) {
    this.context = context;
  }

  setWindowStage(windowStage: window.WindowStage): void {
    this.windowStage = windowStage;
  }

  getWindowStage(): window.WindowStage | null {
    return this.windowStage;
  }

  /**
   * Initialize avoid area parameters
   * @param - mainWindow windows
   * @returns void
   */
  async initAvoidArea(mainWindow: window.Window): Promise<void> {
    hilog.info(0x0000, TAG, 'initAvoidArea start');
    // Initialize default values
    AppStorage.setOrCreate<number>('statusBarHeight', 36);
    AppStorage.setOrCreate<number>('navigationAiBarHeight', 28);
    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      let scaledDensity = (defaultDisplay.scaledDensity > 0) ? defaultDisplay.scaledDensity : 1;
      const systemArea: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const navArea: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      if (systemArea) {
        const statusBarHeight = systemArea.topRect.height / scaledDensity;
        hilog.info(0x0000, TAG, "initAvoidArea statusBarHeight: " + statusBarHeight);
        AppStorage.setOrCreate<number>('statusBarHeight', statusBarHeight);

        if (deviceInfo.deviceType === 'tablet') {
          AppStorage.setOrCreate<number>("Paf.TopHeight", 56);
        } else if (deviceInfo.deviceType === '2in1') {
          AppStorage.setOrCreate<number>("Paf.TopHeight", 0);
        } else {
          AppStorage.setOrCreate<number>("Paf.TopHeight", systemArea.topRect.height);
        }
      }
      if (navArea) {
        const navigationAiBarHeight = navArea.bottomRect.height / scaledDensity;
        hilog.info(0x0000, TAG, "initAvoidArea navigationAiBarHeight: " + navigationAiBarHeight);
        AppStorage.setOrCreate<number>('navigationAiBarHeight', navigationAiBarHeight);

        if (deviceInfo.deviceType === 'tablet') {
          AppStorage.setOrCreate<number>("NavigationBarHeight", navArea.bottomRect.height);
        } else if (deviceInfo.deviceType === '2in1') {
          AppStorage.setOrCreate<number>("NavigationBarHeight", 0);
        } else {
          AppStorage.setOrCreate<number>("NavigationBarHeight", navArea.bottomRect.height);
        }
      }
      hilog.info(0x0000, TAG, 'initAvoidArea end');
    } catch (error) {
      hilog.error(0x0000, TAG,
        `initAvoidArea failed , Code: ${error.code}, message: ${error.message}`);
    }
  }

  initWindowSize(): void {
    window.getLastWindow(this.context, (err, windowClass) => {
      if (err.code !== 0) {
        hilog.error(0x0000, TAG, `setWindowWidth getLastWindow failed, Code: ${err.code}, message: ${err.message}`);
        return;
      }
      try {
        let windowProperty = windowClass.getWindowProperties();
        AppStorage.setOrCreate<number>('windowWidth', windowProperty.windowRect.width);
        AppStorage.setOrCreate<number>('windowHeight', windowProperty.windowRect.height);
      } catch (error) {
        hilog.error(0x0000, TAG,
          `initWindowSize getWindowProperties failed, Code: ${error.code}, message: ${error.message}`);
      }
      this.windowClass = windowClass;
      this.onWindowSizeChange();
      this.onWindowStatusChange();
      this.onWindowRectChange();
    });
  }

  private onWindowStatusChange(): void {
    if (!this.windowClass) {
      return;
    }
    try {
      this.windowClass.on('windowStatusChange', (type: window.WindowStatusType) => {
        this.windowType = type;
        hilog.info(0x0000, TAG, 'onWindowStatusChange type: ', JSON.stringify(type));
        this.initAvoidArea(this.windowClass!);
        if (type === window.WindowStatusType.FLOATING) {
          AppStorage.setOrCreate<number>("NavigationBarHeight", 0);
        }
      })
    } catch (error) {
      hilog.error(0x0000, TAG,
        `onWindowStatusChange on windowStatusChange failed , Code: ${error.code}, message: ${error.message}`);
    }
  }

  private onWindowRectChange(): void {
    if (!this.windowClass) {
      return;
    }
    try {
      this.windowClass.on('windowRectChange', () => {
        if (this.windowType === window.WindowStatusType.SPLIT_SCREEN ||
          this.windowType === window.WindowStatusType.FULL_SCREEN) {
          // Reacquire the navigation bar height
          this.setNavigationBar();
        }
      })
    } catch (error) {
      hilog.error(0x0000, TAG,
        `onWindowRectChange on windowRectChange failed , Code: ${error.code}, message: ${error.message}`);
    }
  }

  private setNavigationBar(): void {
    if (!this.windowClass) {
      return;
    }
    try {
      const nav: window.AvoidArea = this.windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      hilog.info(0x0000, TAG, 'setNavigationBar avoidArea: ', JSON.stringify(nav));
      if (nav) {
        AppStorage.setOrCreate<number>("NavigationBarHeight", nav.bottomRect.height);
      }
    } catch (error) {
      hilog.error(0x0000, TAG,
        `onWindowRectChange on windowRectChange failed , Code: ${error.code}, message: ${error.message}`);
    }

  }

  async setWindowLayoutFullScreen(isFullScreen: boolean): Promise<void> {
    if (deviceInfo.deviceType === '2in1') {
      return;
    }
    window.getLastWindow(this.context).then(async (wnd: window.Window) => {
      try {
        await wnd.setWindowLayoutFullScreen(isFullScreen);
      } catch (error) {
        hilog.error(0x0000, TAG,
          `setWindowLayoutFullScreen failed , Code: ${error.code}, message: ${error.message}`);
      }
    });
  }

  onWindowSizeChange(callback?: () => void): void {
    if (!this.windowClass) {
      return;
    }
    try {
      this.windowClass.on('windowSizeChange', (size) => {
        hilog.info(0x0000, TAG,
          'onWindowSizeChange windowSizeChange size is: ' + JSON.stringify(size));
        AppStorage.setOrCreate<number>('windowWidth', size.width);
        AppStorage.setOrCreate<number>('windowHeight', size.height);
        callback && callback();
      });
    } catch (error) {
      hilog.error(0x0000, TAG,
        `onWindowSizeChange failed, Code: ${error.code}, message: ${error.message}`);
    }
  }

  setOrientation(windowStage: window.WindowStage, orientation: window.Orientation): void {
    windowStage.getMainWindow().then((win) => {
      win.setPreferredOrientation(orientation).then((data) => {
        hilog.info(0x0000, TAG, 'setOrientation succeeded, error is: ' + JSON.stringify(data));
      }).catch((err: Error) => {
        hilog.error(0x0000, TAG, `setOrientation setPreferredOrientation failed, message: ${err.message}`);
      });
    }).catch((err: Error) => {
      hilog.error(0x0000, TAG, `setOrientation getMainWindow failed, message: ${err.message}`);
    });
  }

  /**
   * Set the system bar to have visible.
   *
   * @param { Array<'status' | 'navigation'> } names - The set of system bar
   * @param context - Current application context
   */
  toggleWindowSystemBar(names: Array<'status' | 'navigation'>, windowContext: Context | undefined): void {
    window.getLastWindow(windowContext, (err, data) => {
      try {
        if (err.code) {
          return;
        }
        let windowClass = data;
        if (names.length === 0) {
          AppStorage.setOrCreate('Grid.tabPro.enableAvoidAreaListener', false);
        }
        windowClass.setWindowSystemBarEnable(names).then(() => {
          hilog.info(0x0000, TAG, 'toggleWindowSystemBar setWindowSystemBarEnable succeeded');
        }).catch(() => {
          hilog.error(0x0000, TAG,
            `toggleWindowSystemBar setWindowSystemBarEnable failed`);
        })
        if (names.length > 0) {
          AppStorage.setOrCreate('Grid.tabPro.enableAvoidAreaListener', true);
        }
        hilog.info(0x0000, TAG, 'toggleWindowSystemBar Succeeded in setting the system bar to be invisible.');
      } catch (exception) {
        hilog.error(0x0000, TAG,
          `toggleWindowSystemBar Failed to set the system bar to be invisible. Code: ${exception.code}, message: ${exception.message}`);
      }
    });
  }
}