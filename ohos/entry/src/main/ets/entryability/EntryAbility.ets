import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { WindowAbility } from './WindowAbility';
import { TalebookService, AUTH_FAILURE_KEY } from '../services/TalebookService';
import { TalebookCoreService } from '../services/TalebookCoreService';
import { AccountManager } from '../services/AccountManager';
import { SERVER_KIND_NOTICE_KEY } from '../services/ServerProbe';
import { ServerRegistry } from '../services/ServerProfile';
import { NotificationService } from '../services/NotificationService';
import { DownloadTaskService } from '../services/DownloadTaskService';
import { ReadKitSession } from '../services/ReadKitSession';
import { AppTheme } from '../theme/AppTheme';
import { BookshelfRefresh } from '../utils/BookshelfRefresh';
import { UpdateService } from '../services/UpdateService';
import { AudioPlaybackService, publishAudioLaunch } from '../services/AudioPlaybackService';

const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  /** @throws 内部调用可能抛出异常，由调用方处理 */
  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'Ability onCreate');
    publishAudioLaunch(want);
    WindowAbility.getInstance().initContext(this.context);
    TalebookService.init(this.context.filesDir);
    TalebookCoreService.ensureInitialized(this.context);
    TalebookService.applyLocalConfig();
    // 升级迁移：把既有单账号配置落成默认账号（其身份根就是 filesDir，不搬移任何文件）
    AccountManager.ensureMigrated();
    // 按当前账号记录重新下发身份：自愈历史上未能落盘的账号配置，避免重启后请求打到空地址
    AccountManager.ensureActiveIdentity();
    NotificationService.init();
    DownloadTaskService.notifyChanged();
    void TalebookService.warmLocalCaches();
    // 先预热连接再恢复会话，减轻首次 API 握手等待
    void TalebookService.warmConnection().then(() => {
      void TalebookService.ensureAuthenticated().then((_ok: boolean) => {
        // 登录页已移除：自动登录失败的原因发布到 AppStorage，由 MainTabs 提示一次
        AppStorage.setOrCreate(AUTH_FAILURE_KEY, TalebookService.consumeAuthFailure());
        // 启动自愈：按服务器实际响应纠正书库类型（选错会导致管理概览等功能整类走错）
        void AccountManager.syncServerKindByProbe().then((corrected: boolean) => {
          if (corrected) {
            AppStorage.setOrCreate(SERVER_KIND_NOTICE_KEY, ServerRegistry.profile().displayName);
          }
        });
      });
    });
    BookshelfRefresh.init();
    // 初始化「可升级版本」提示键，供设置页订阅（值为空串表示暂无提示）
    UpdateService.publishHint();
    AppTheme.applyThemeMode(this.context, TalebookService.prefGet('theme_mode', 'system'));
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'Ability onDestroy');
    AudioPlaybackService.getInstance().release();
  }

  /** 应用已在运行时，从播控中心卡片再次点入：走 onNewWant，同样落到 AppStorage 交给 MainTabs 处理。 */
  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    publishAudioLaunch(want);
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(0x0000, TAG, 'Ability onWindowStageCreate');
    WindowAbility.getInstance().setWindowStage(windowStage);
    AppStorage.setOrCreate('colorMode', this.context.config.colorMode);
    windowStage.loadContent('pages/MainTabs', (err) => {
      if (err.code !== 0) {
        hilog.error(0x0000, TAG, 'Failed to load MainTabs: %{public}s', err.message);
      }
    });
    windowStage.getMainWindow((err, windowClass) => {
      if (err.code !== 0) {
        return;
      }
      WindowAbility.getInstance().initAvoidArea(windowClass);
      const systemBarProperties: window.SystemBarProperties = {
        statusBarContentColor: this.context.config.colorMode ? '#000000' : '#FFFFFF'
      };
      windowClass.setWindowSystemBarProperties(systemBarProperties).catch(() => {
        hilog.error(0x0000, TAG, 'setWindowSystemBarProperties failed');
      });
    });
    WindowAbility.getInstance().setWindowLayoutFullScreen(false);
    if (deviceInfo.deviceType === 'tablet') {
      WindowAbility.getInstance().setOrientation(windowStage, window.Orientation.AUTO_ROTATION_RESTRICTED);
    }
    WindowAbility.getInstance().initWindowSize();
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    const colorMode: number | undefined = AppStorage.get('colorMode');
    if (colorMode !== newConfig.colorMode) {
      AppStorage.setOrCreate('colorMode', newConfig.colorMode);
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(0x0000, TAG, 'Ability onForeground');
    void NotificationService.refreshUnreadCount();
    DownloadTaskService.processQueue();
  }

  onBackground(): void {
    hilog.info(0x0000, TAG, 'Ability onBackground');
    ReadKitSession.flushProgress();
    DownloadTaskService.flushPersist();
  }
}
