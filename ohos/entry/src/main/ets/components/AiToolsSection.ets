import { AiService } from '../services/AiService';
import { AiPermissionMode } from '../services/AiTools';
import { AiToolGroup, AiToolItem } from '../services/AiToolsDefs';

/**
 * 工具清单（设置页「工具」档）：按用途分组展示 AI 当前可用的全部工具。
 *
 * 数据来自 AiTools.catalogGroups()（与模型侧 list_ai_tools 同源），
 * 顶部显示权限模式与「该模式下实际可用数量」，让用户清楚写工具何时被裁掉。
 */
@Component
export struct AiToolsSection {
  @State groups: AiToolGroup[] = [];
  @State total: number = 0;
  @State available: number = 0;
  @State mode: string = 'confirm';
  @State expanded: string = '';

  aboutToAppear(): void {
    this.groups = AiService.toolCatalog();
    this.total = AiService.toolTotal();
    const perm: AiPermissionMode = AiService.loadPermission();
    this.mode = perm;
    this.available = AiService.toolAvailableCount(perm);
  }

  private modeLabel(): string {
    if (this.mode === 'readonly') {
      return '只读（写工具全部隐藏）';
    }
    if (this.mode === 'auto') {
      return '自动放行（写工具直接执行）';
    }
    return '逐笔确认（写工具需你点确认）';
  }

  build() {
    Column({ space: 12 }) {
      Text(`共 ${this.total} 个工具；当前权限「${this.modeLabel()}」下实际可用 ${this.available} 个。` +
        '带「写」标记的工具会修改服务器数据，在逐笔确认模式下每次执行前都会问你。')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');

      ForEach(this.groups, (group: AiToolGroup) => {
        Column({ space: 6 }) {
          Row() {
            Text(group.title)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'));
            Text(`${group.items.length}`)
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ left: 6 });
            Blank();
            Text(this.expanded === group.title ? '⌃' : '⌄')
              .fontSize(14)
              .fontColor($r('app.color.text_tertiary'));
          }
          .width('100%')
          .onClick(() => {
            this.expanded = this.expanded === group.title ? '' : group.title;
          });

          if (this.expanded === group.title) {
            ForEach(group.items, (item: AiToolItem) => {
              Column({ space: 2 }) {
                Row({ space: 6 }) {
                  Text(item.name)
                    .fontSize(12)
                    .fontColor($r('app.color.text_primary'));
                  if (item.write) {
                    Text('写')
                      .fontSize(10)
                      .fontColor(Color.White)
                      .backgroundColor($r('app.color.error'))
                      .borderRadius(3)
                      .padding({ left: 4, right: 4, top: 1, bottom: 1 });
                  }
                }
                .width('100%');
                Text(item.summary)
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%');
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start);
            }, (item: AiToolItem) => item.name)
          }
        }
        .width('100%')
        .padding($r('app.float.page_padding'))
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'))
        .alignItems(HorizontalAlign.Start);
      }, (group: AiToolGroup) => `${group.title}-${this.expanded === group.title ? 'open' : 'fold'}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }
}
