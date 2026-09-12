import { HarmonyTopBar } from './HarmonyTopBar';
import { TalebookService } from '../services/TalebookService';
import { StorageKeys } from '../common/Constants';

@Component
export struct PageScaffold {
  title: string = '';
  showBack: boolean = false;
  @BuilderParam action: () => void = this.defaultAction;
  @BuilderParam content: () => void = this.defaultContent;
  private backSettingEnabled: boolean = true;

  aboutToAppear(): void {
    this.backSettingEnabled = TalebookService.prefGet(StorageKeys.SHOW_BACK_BUTTON, 'true') === 'true';
  }

  @Builder
  defaultAction(): void {
  }

  /**
   * 转发壳：ArkUI 要求 `@BuilderParam` 只能由 `@Builder` 函数或 `@LocalBuilder` 方法初始化，
   * 直接把本组件的 `@BuilderParam action` 传给下层组件会触发编译告警，故包一层。
   *
   * ⚠️ 必须用 `@LocalBuilder`：普通 `@Builder` 作为 builder 参数传下去时，ArkUI 会把 `this`
   * 重绑定到接收方组件，`this.action()` 会解析成同一个 builder 造成无限递归（实测 Stack overflow）。
   * `@LocalBuilder` 保持 `this` 指向本组件。
   */
  @LocalBuilder
  actionWrapper(): void {
    this.action();
  }

  @Builder
  defaultContent(): void {
  }

  build() {
    Column() {
      HarmonyTopBar({ title: this.title, showBack: this.showBack && this.backSettingEnabled, action: this.actionWrapper });
      Column() {
        this.content();
      }
      .layoutWeight(1)
      .width('100%');
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'));
  }
}
