import { PageScaffold, PrimaryButton, SecondaryButton } from '../components';
import { TalebookService } from '../services/TalebookService';
import { TalebookCoreService } from '../services/TalebookCoreService';

@Entry
@Component
struct SoNovelConfigPage {
  @State url: string = '';

  aboutToAppear(): void {
    this.url = TalebookService.secureGet('sonovel_url');
  }

  build() {
    Column() {
      PageScaffold({
        title: 'SoNovel 配置',
        showBack: true,
        content: () => {
          this.configContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  configContent() {
    Column({ space: 16 }) {
      Column() {
        TextInput({ placeholder: 'SoNovel 服务地址', text: this.url })
          .height(44)
          .borderRadius(8)
          .backgroundColor($r('app.color.page_background'))
          .onChange((value: string) => this.url = value);
      }
      .width('100%')
      .padding($r('app.float.page_padding'))
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));

      PrimaryButton({
        label: '保存',
        onTap: () => {
          TalebookService.setBaseUrl('sonovel', this.url.trim());
          TalebookService.secureSet('sonovel_url', this.url.trim());
          TalebookCoreService.syncBaseUrl('sonovel', this.url.trim());
          this.getUIContext().getPromptAction().showToast({ message: '已保存' });
        },
      });

      SecondaryButton({
        label: '前往搜索',
        onTap: () => this.getUIContext().getRouter().pushUrl({ url: 'pages/SoNovelSearchPage' }),
      });
    }
    .padding($r('app.float.page_padding'));
  }
}
