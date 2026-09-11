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

  @Builder
  defaultContent(): void {
  }

  build() {
    Column() {
      HarmonyTopBar({ title: this.title, showBack: this.showBack && this.backSettingEnabled, action: this.action });
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
