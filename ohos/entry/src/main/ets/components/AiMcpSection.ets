import { AiService, AiConfig } from '../services/AiService';
import { McpServer } from '../services/McpService';
import { AiToolDefinition } from '../services/AiToolsDefs';

/**
 * MCP 设置区（AiSettingsPage「MCP」档）。
 *
 * 内置四家（百炼）复用 Token Plan 的 Key；用户可新增任意 MCP server 并各填各的 Key。
 * 每行：启用开关 / 名称 / URL / Key 状态；自定义家可编辑与删除。
 * 改动即存并失效工具集缓存，下一轮对话生效。
 */
@Component
export struct AiMcpSection {
  @State servers: McpServer[] = [];
  @State onArr: boolean[] = [];
  @State hasKeyArr: boolean[] = [];
  @State probing: boolean = false;
  @State probeText: string = '';
  /** 门控提示：当前服务商是否 Token Plan（内置四家的 Key 来源）。 */
  @State gateOk: boolean = false;
  /** 编辑态：'' 无；'add' 新增；否则为被编辑家的 tag。 */
  @State editTag: string = '';
  @State editLabel: string = '';
  @State editUrl: string = '';
  @State editKey: string = '';

  aboutToAppear(): void {
    this.reload();
    const config: AiConfig = AiService.loadConfig();
    this.gateOk = config.providerId === 'qwen-tokenplan';
  }

  private reload(): void {
    const list: McpServer[] = AiService.mcpServers();
    const onArr: boolean[] = [];
    const keyArr: boolean[] = [];
    for (let i = 0; i < list.length; i++) {
      onArr.push(AiService.loadMcpEnabled(list[i].tag));
      keyArr.push(AiService.mcpHasKey(list[i]));
    }
    this.servers = list;
    this.onArr = onArr;
    this.hasKeyArr = keyArr;
  }

  private setEnabled(index: number, on: boolean): void {
    this.onArr[index] = on;
    AiService.saveMcpEnabled(this.servers[index].tag, on);
  }

  private startAdd(): void {
    this.editTag = 'add';
    this.editLabel = '';
    this.editUrl = '';
    this.editKey = '';
  }

  private startEdit(server: McpServer): void {
    this.editTag = server.tag;
    this.editLabel = server.label;
    this.editUrl = server.url;
    this.editKey = '';
  }

  private cancelEdit(): void {
    this.editTag = '';
  }

  private commitEdit(): void {
    try {
      if (this.editTag === 'add') {
        AiService.mcpAddServer(this.editLabel, this.editUrl, this.editKey);
        this.toast('已添加 MCP 服务');
      } else {
        AiService.mcpUpdateServer(this.editTag, this.editLabel, this.editUrl, this.editKey);
        this.toast('已保存');
      }
      this.editTag = '';
      this.reload();
    } catch (error) {
      this.toast(error instanceof Error ? error.message : String(error));
    }
  }

  private confirmRemove(server: McpServer): void {
    this.getUIContext().showAlertDialog({
      title: '删除 MCP 服务',
      message: `确定删除「${server.label}」吗？其保存的 Key 会一并清除。`,
      primaryButton: {
        value: '删除',
        action: () => {
          AiService.mcpRemoveServer(server.tag);
          this.reload();
          this.toast('已删除');
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private async probe(): Promise<void> {
    if (this.probing) {
      return;
    }
    this.probing = true;
    try {
      const tools: AiToolDefinition[] = await AiService.mcpToolset();
      this.probeText = tools.length === 0
        ? '没有挂载任何工具：内置家需服务商为 Token Plan 且已配 Key；自定义家需填自己的 Key。仍为空则是网络/服务端握手失败'
        : `已挂载共 ${tools.length} 个工具（${AiService.mcpSummary()}）`;
    } finally {
      this.probing = false;
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  build() {
    Column({ space: 12 }) {
      Text('MCP 服务会把其工具挂进对话。内置四家百炼服务复用 Token Plan 的 Key；也可新增任意 MCP 服务（Streamable HTTP）并各填各的 Key。关掉哪家，哪家的工具就不出现，下一轮对话生效。')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      if (!this.gateOk) {
        Text('当前服务商不是 Token Plan：内置四家不会挂载；新增的自定义服务只要填了自己的 Key 仍可用。')
          .fontSize(12)
          .fontColor($r('app.color.error'))
          .width('100%');
      }

      ForEach(this.servers, (server: McpServer, index: number) => {
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Row({ space: 6 }) {
                Text(server.label)
                  .fontSize(13)
                  .fontColor($r('app.color.text_primary'));
                Text(server.builtin === true ? '内置' : '自定义')
                  .fontSize(10)
                  .fontColor($r('app.color.text_tertiary'))
                  .backgroundColor($r('app.color.page_background'))
                  .borderRadius(4)
                  .padding({ left: 5, right: 5, top: 1, bottom: 1 });
              }
              Text(server.url)
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis });
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1);
            Toggle({ type: ToggleType.Switch, isOn: this.onArr[index] })
              .onChange((on: boolean) => this.setEnabled(index, on));
          }
          .width('100%');

          Row({ space: 12 }) {
            Text(this.hasKeyArr[index] ? 'Key 已配置' : '未配 Key')
              .fontSize(11)
              .fontColor(this.hasKeyArr[index] ? $r('app.color.success') : $r('app.color.error'));
            if (AiService.mcpOwnsKey(server)) {
              Text(this.editTag === server.tag ? '收起' : '编辑')
                .fontSize(12)
                .fontColor($r('app.color.brand_primary'))
                .onClick(() => {
                  if (this.editTag === server.tag) {
                    this.cancelEdit();
                  } else {
                    this.startEdit(server);
                  }
                });
              Text('删除')
                .fontSize(12)
                .fontColor($r('app.color.error'))
                .onClick(() => this.confirmRemove(server));
            }
          }
          .width('100%');

          if (this.editTag === server.tag) {
            this.editFields(false);
          }
        }
        .width('100%')
        .padding(8)
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'))
        .alignItems(HorizontalAlign.Start);
      }, (server: McpServer, index: number) =>
        `${server.tag}-${this.onArr[index] ? 'on' : 'off'}-${this.hasKeyArr[index] ? 'k' : 'n'}-${
          this.editTag === server.tag ? 'e' : 'c'}`)

      if (this.editTag === 'add') {
        Column({ space: 6 }) {
          Text('新增 MCP 服务')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'));
          this.editFields(true);
        }
        .width('100%')
        .padding(8)
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'))
        .alignItems(HorizontalAlign.Start);
      } else {
        Text('＋ 新增 MCP 服务')
          .fontSize(13)
          .fontColor($r('app.color.brand_primary'))
          .onClick(() => this.startAdd());
      }

      Row() {
        Text(this.probing ? '探测中…' : '立即探测挂载状态')
          .fontSize(13)
          .fontColor($r('app.color.brand_primary'))
          .onClick(() => {
            void this.probe();
          });
      }
      .width('100%');

      if (this.probeText.length > 0) {
        Text(this.probeText)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  editFields(isAdd: boolean) {
    TextInput({ placeholder: '名称，如 我的搜索服务', text: this.editLabel })
      .fontSize(13)
      .onChange((v: string) => {
        this.editLabel = v;
      });
    TextInput({ placeholder: 'MCP 端点 URL（Streamable HTTP）', text: this.editUrl })
      .fontSize(13)
      .onChange((v: string) => {
        this.editUrl = v;
      });
    TextInput({ placeholder: isAdd ? 'API Key（可选）' : 'API Key（留空不修改）', text: this.editKey })
      .fontSize(13)
      .onChange((v: string) => {
        this.editKey = v;
      });
    Row() {
      Blank();
      Text('取消')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .padding(6)
        .onClick(() => this.cancelEdit());
      Text(isAdd ? '添加' : '保存')
        .fontSize(13)
        .fontColor($r('app.color.brand_primary'))
        .padding(6)
        .onClick(() => this.commitEdit());
    }
    .width('100%');
  }
}
