// #1631：书架 AI 入口一次性提示。wand 图标无文字标签，新用户认不出是 AI 助手；
// 首次进书架在工具栏下方显示一行说明，点「知道了」后永久不再出现（prefSet 落库）。
import { TalebookService } from '../services/TalebookService';

const KEY_HINT_SHOWN: string = 'ai_entry_hint_shown';

@Component
export struct AiEntryHintBanner {
  @State visible: boolean = false;

  aboutToAppear(): void {
    this.visible = TalebookService.prefGet(KEY_HINT_SHOWN, '0') !== '1';
  }

  private dismiss(): void {
    this.visible = false;
    TalebookService.prefSet(KEY_HINT_SHOWN, '1');
  }

  build() {
    if (this.visible) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.wand_and_stars'))
          .fontSize(16)
          .fontColor([$r('app.color.brand_primary')]);
        Text('魔杖是 AI 助手入口：可以搜书、下载、管理书架')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text('知道了')
          .fontSize(12)
          .fontColor($r('app.color.brand_primary'))
          .onClick(() => {
            this.dismiss();
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding(10)
      .borderRadius($r('app.float.chip_radius'))
      .backgroundColor($r('app.color.page_background'));
    }
  }
}
