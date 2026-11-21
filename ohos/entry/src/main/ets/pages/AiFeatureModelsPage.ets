import { PageScaffold } from '../components';
import { AiService, AiConfig, AiProviderPreset } from '../services/AiService';

/**
 * 功能模型：给六个 AI 功能单独绑定服务商/模型。
 *
 * 未绑定的档位自动跟随（看图/摘要跟随全局，TTS/ASR/实时通话先跟随语音档再退全局）；
 * 编辑区改动即存，无需保存按钮。编辑套件由旧设置页语音档套件泛化而来：
 * 所有档位读写走 AiService.loadFeatureConfig / saveFeatureConfig。
 */
@Entry
@Component
struct AiFeatureModelsPage {
  @State features: string[] = [];
  @State providers: AiProviderPreset[] = [];
  /** 当前展开编辑器的档位；'' 表示全部折叠。 */
  @State editFeature: string = '';
  @State editFollow: boolean = true;
  @State editProviderId: string = '';
  @State editModel: string = '';
  @State editModelOptions: string[] = [];
  @State editFetchingModels: boolean = false;

  aboutToAppear(): void {
    this.features = AiService.featureIds();
    this.providers = AiService.listProviders();
    if (this.features.length > 0) {
      this.enterFeature(this.features[0]);
    }
  }

  /** DashScope 原生音频协议的三档：只允许绑 Token Plan，未绑跟随语音档。 */
  private isAudioFeature(feature: string): boolean {
    return feature === 'tts' || feature === 'asr' || feature === 'realtime';
  }

  private featureLabel(feature: string): string {
    if (feature === 'vision') return '带图对话';
    if (feature === 'summary') return '历史摘要';
    if (feature === 'voice') return '语音通话 · 对话模型';
    if (feature === 'tts') return '语音合成 TTS';
    if (feature === 'asr') return '语音转文字 ASR';
    return '实时语音通话';
  }

  private featureHint(feature: string): string {
    if (feature === 'vision') return '对话页附带图片发送时用的模型，需具备视觉能力。';
    if (feature === 'summary') return '把超出上下文窗口的历史压缩成摘要，推荐低随机性模型。';
    if (feature === 'voice') return '轮转模式语音通话的对话模型，推荐流式与工具调用强的模型。';
    if (feature === 'tts') return '云端播报与通话朗读的合成模型；不绑定则用协议默认。';
    if (feature === 'asr') return '按住说话与通话语音输入的识别模型；不绑定则用协议默认。';
    return '实时全双工通话模型（开口即打断）。';
  }

  /** 音频档协议固定默认模型（槽 model 留空时消费端按此走）。 */
  private audioModelDefault(feature: string): string {
    if (feature === 'asr') return 'qwen-audio-3.0-asr-flash';
    if (feature === 'tts') return 'qwen-audio-3.0-tts-plus';
    if (feature === 'realtime') return 'qwen-audio-3.0-realtime-plus';
    return '';
  }

  /** 本档可选服务商：音频三档限 Token Plan（协议约束），其余为全部服务商。 */
  private editorProviders(feature: string): AiProviderPreset[] {
    if (!this.isAudioFeature(feature)) {
      return this.providers;
    }
    return this.providers.filter((p: AiProviderPreset) => p.id === 'qwen-tokenplan');
  }

  /** 下拉首项文案：音频档跟随语音档，其余跟随全局（带服务商名）。 */
  private followLabel(feature: string): string {
    if (this.isAudioFeature(feature)) {
      return '跟随语音档';
    }
    const globalName: string = AiService.presetOf(AiService.loadConfig().providerId).name;
    return `跟随全局（${globalName}）`;
  }

  // ———— 泛化编辑套件（改动即存，与旧语音档套件同语义） ————

  private providerItems(feature: string): SelectOption[] {
    const items: SelectOption[] = [];
    const first: SelectOption = { value: this.followLabel(feature) };
    items.push(first);
    const list: AiProviderPreset[] = this.editorProviders(feature);
    for (let i = 0; i < list.length; i++) {
      const opt: SelectOption = { value: list[i].name };
      items.push(opt);
    }
    return items;
  }

  private providerSelectedIndex(feature: string): number {
    if (this.editFollow) {
      return 0;
    }
    const list: AiProviderPreset[] = this.editorProviders(feature);
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === this.editProviderId) {
        return i + 1;
      }
    }
    return 0;
  }

  /** 点开/收起某档编辑器；展开时读回该档已存配置。 */
  private enterFeature(feature: string): void {
    if (this.editFeature === feature) {
      this.editFeature = '';
      return;
    }
    this.editFeature = feature;
    this.editProviderId = AiService.loadFeatureProviderId(feature);
    this.editFollow = !AiService.hasFeatureProvider(feature);
    this.editModel = AiService.loadFeatureModel(feature);
    this.editModelOptions = [];
    this.editFetchingModels = false;
  }

  private selectProvider(feature: string, index: number): void {
    if (index <= 0) {
      this.editFollow = true;
      this.editProviderId = '';
      this.editModel = '';
      this.editModelOptions = [];
      AiService.saveFeatureConfig(feature, '', '');
      return;
    }
    const preset: AiProviderPreset = this.editorProviders(feature)[index - 1];
    this.editFollow = false;
    this.editProviderId = preset.id;
    this.editModel = '';
    this.editModelOptions = [];
    AiService.saveFeatureConfig(feature, preset.id, '');
  }

  private modelItems(feature: string): SelectOption[] {
    const ids: string[] = [];
    if (this.isAudioFeature(feature)) {
      ids.push(this.audioModelDefault(feature));
    }
    for (let i = 0; i < this.editModelOptions.length; i++) {
      if (ids.indexOf(this.editModelOptions[i]) < 0) {
        ids.push(this.editModelOptions[i]);
      }
    }
    const presetModel: string = AiService.presetOf(this.editProviderId).model;
    if (ids.length === 0 && presetModel.length > 0) {
      ids.push(presetModel);
    }
    if (this.editModel.length > 0 && ids.indexOf(this.editModel) < 0) {
      ids.push(this.editModel);
    }
    const items: SelectOption[] = [];
    for (let i = 0; i < ids.length; i++) {
      const opt: SelectOption = { value: ids[i] };
      items.push(opt);
    }
    return items;
  }

  private async fetchFeatureModels(feature: string): Promise<void> {
    if (this.editFetchingModels || this.editProviderId.length === 0) {
      return;
    }
    this.editFetchingModels = true;
    try {
      const ids: string[] = await AiService.fetchModels(this.editProviderId,
        AiService.baseUrlFor(this.editProviderId), '');
      if (ids.length === 0) {
        this.toast('该服务未返回模型列表');
      } else {
        this.editModelOptions = ids;
        this.toast(`获取到 ${ids.length} 个模型，可从下拉选择`);
      }
    } catch (error) {
      this.toast(error instanceof Error ? error.message : String(error));
    } finally {
      this.editFetchingModels = false;
    }
  }

  /** 模型下拉选中：改动即存（与服务商选择同语义）。 */
  private chooseModel(feature: string, value: string): void {
    this.editModel = value;
    AiService.saveFeatureConfig(feature, this.editProviderId, value);
  }

  /** 生效配置一行人话：绑定值或跟随来源。 */
  private featureSummary(feature: string): string {
    const cfg: AiConfig = AiService.loadFeatureConfig(feature);
    const name: string = AiService.presetOf(cfg.providerId).name;
    const model: string = cfg.model.length > 0 ? cfg.model : '默认模型';
    if (AiService.hasFeatureProvider(feature)) {
      return `${name} · ${model}（已绑定）`;
    }
    return `${name} · ${model}（${this.isAudioFeature(feature) ? '跟随语音档' : '跟随全局'}）`;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '功能模型',
        showBack: true,
        content: () => {
          this.pageContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  pageContent() {
    Scroll() {
      Column({ space: 12 }) {
        Text('给单个功能指定服务商/模型：如图用本地视觉模型、摘要用便宜模型省用量。未绑定的档位自动跟随，改动即存。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');

        ForEach(this.features, (f: string) => {
          Column({ space: 6 }) {
            Row() {
              Column({ space: 2 }) {
                Text(this.featureLabel(f))
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'));
                Text(this.featureSummary(f))
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'));
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1);
              Text(this.editFeature === f ? '⌃' : '⌄')
                .fontSize(14)
                .fontColor($r('app.color.text_tertiary'));
            }
            .width('100%')
            .onClick(() => {
              this.enterFeature(f);
            });

            if (this.editFeature === f) {
              Text(this.featureHint(f))
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%');
              Select(this.providerItems(f))
                .selected(this.providerSelectedIndex(f))
                .value(this.editFollow ? this.followLabel(f) : AiService.presetOf(this.editProviderId).name)
                .width('100%')
                .onSelect((index: number, value: string) => this.selectProvider(f, index));
              if (!this.editFollow) {
                Row() {
                  Text('模型')
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'));
                  Blank();
                  Text(this.editFetchingModels ? '拉取中…' : '拉取模型列表')
                    .fontSize(13)
                    .fontColor($r('app.color.brand_primary'))
                    .onClick(() => {
                      void this.fetchFeatureModels(f);
                    });
                }
                .width('100%');
                Select(this.modelItems(f))
                  .selected(Math.max(0, this.modelItems(f).findIndex((it: SelectOption) =>
                    it.value === this.editModel)))
                  .value(this.editModel.length > 0 ? this.editModel :
                    (this.isAudioFeature(f) ? '使用协议默认模型' : '使用该服务商默认模型'))
                  .width('100%')
                  .onSelect((index: number, value: string) => this.chooseModel(f, value));
              }
            }
          }
          .width('100%')
          .padding($r('app.float.page_padding'))
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'))
          .alignItems(HorizontalAlign.Start);
        }, (f: string) => `${f}-${this.editFeature === f ? 'open' : 'fold'}-${this.featureSummary(f)}`)
      }
      .width('100%')
      .padding($r('app.float.page_padding'))
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top);
  }
}
