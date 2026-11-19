import { ToolBookLine } from '../services/AiTools';

/**
 * 工具结果的书目列表渲染：书名行 + 副标题行，供对话页活动区使用。
 * 纯展示组件，items 由 parseToolBookLines 产出。
 */
@Component
export struct ToolResultList {
  items: ToolBookLine[] = [];

  build() {
    Column({ space: 6 }) {
      ForEach(this.items, (item: ToolBookLine, idx: number) => {
        Column({ space: 1 }) {
          Text(item.title)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
          if (item.subtitle.length > 0) {
            Text(item.subtitle)
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%');
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: 8, top: 4, bottom: 4 })
        .borderRadius(6)
        .backgroundColor($r('app.color.page_background'));
      }, (item: ToolBookLine, idx: number) => `${idx}-${item.title}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }
}
