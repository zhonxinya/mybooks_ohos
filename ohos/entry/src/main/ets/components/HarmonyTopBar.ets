import { IconCircleButton } from './IconCircleButton';

@Component
export struct HarmonyTopBar {
  title: string = '';
  showBack: boolean = false;
  @BuilderParam action: () => void = this.defaultAction;

  @Builder
  defaultAction(): void {
  }

  build() {
    Column() {
      Row() {
        if (this.showBack) {
          IconCircleButton({
            icon: $r('sys.symbol.chevron_left'),
            variant: 'ghost',
            onTap: () => this.getUIContext().getRouter().back(),
          });
        }
        Text(this.title)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .margin({ left: this.showBack ? 4 : 16 });
        this.action();
      }
      .width('100%')
      .height($r('app.float.top_bar_height'))
      .padding({ right: 16 })
      .alignItems(VerticalAlign.Center);

      Divider().color($r('app.color.divider')).strokeWidth(0.5);
    }
    .width('100%')
    .backgroundColor($r('app.color.card_background'));
  }
}
