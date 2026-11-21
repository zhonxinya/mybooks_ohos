import { AiService, AiConfig } from '../services/AiService';
import { McpServer } from '../services/McpService';
import { AiToolDefinition } from '../services/AiToolsDefs';

/**
 * MCP 设置区（AiSettingsPage「MCP」档）：四家百炼 MCP 服务的启用开关 + 探测。
 * 开关改动即存并失效工具集缓存（下一轮对话生效）；组件自持状态，无对外回调。
 */
@Component
export struct AiMcpSection {
  @State tags: string[] = [];
  @State labels: string[] = [];
  @State onArr: boolean[] = [];
  @State probing: boolean = false;
  @State probeText: string = '';
  /** 门控提示用：当前服务商是否为 Token Plan（MCP 唯一鉴权来源）。 */
  @State gateOk: boolean = false;

  aboutToAppear(): void {
    const servers: McpServer[] = AiService.mcpServers();
    for (let i = 0; i < servers.length; i++) {
      this.tags.push(servers[i].tag);
      this.labels.push(servers[i].label);
      this.onArr.push(AiService.loadMcpEnabled(servers[i].tag));
    }
    const config: AiConfig = AiService.loadConfig();
    this.gateOk = config.providerId === 'qwen-tokenplan';
  }

  private setEnabled(index: number, on: boolean): void {
    this.onArr[index] = on;
    AiService.saveMcpEnabled(this.tags[index], on);
  }

  private async probe(): Promise<void> {
    if (this.probing) {
      return;
    }
    this.probing = true;
    try {
      const tools: AiToolDefinition[] = await AiService.mcpToolset();
      this.probeText = tools.length === 0
        ? '没有挂载任何工具：需服务商为 Token Plan 且已配 API Key；仍为空则是网络/服务端握手失败'
        : `已挂载共 ${tools.length} 个工具（${AiService.mcpSummary()}）`;
    } finally {
      this.probing = false;
    }
  }

  build() {
    Column({ space: 12 }) {
      Text('百炼 MCP 服务（增强搜索/联网搜索/网页解析/语音转写）的工具仅在服务商为 Token Plan 且已配 API Key 时自动挂进对话（复用同一 Key）。关掉哪家，哪家的工具就不出现；下一轮对话生效。')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      if (!this.gateOk) {
        Text('当前服务商不是 Token Plan，MCP 工具不会挂载（可在「服务商与模型」档切换）。')
          .fontSize(12)
          .fontColor($r('app.color.error'))
          .width('100%');
      }
      ForEach(this.tags, (tag: string, index: number) => {
        Row({ space: 8 }) {
          Text(this.labels[index])
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1);
          Toggle({ type: ToggleType.Switch, isOn: this.onArr[index] })
            .onChange((on: boolean) => this.setEnabled(index, on));
        }
        .width('100%');
      }, (tag: string, index: number) => `${tag}-${this.onArr[index] ? 'on' : 'off'}`)

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
}
