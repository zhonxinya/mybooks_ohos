import { PageScaffold } from '../components';
import { AiService, AiConfig, AiModelEntry } from '../services/AiService';
import { AppRouter } from '../utils/AppRouter';

/**
 * 功能模型：给每个 AI 功能从「模型库」里挑一条模型条目。
 *
 * 模型库把「服务商」与「模型」拆开自由组合（见 pages/AiModelLibraryPage），
 * 功能这里只做绑定：选中条目即写 provider/model，未绑定的功能按回退链跟随。
 */
@Entry
@Component
struct AiFeatureModelsPage {
  @State features: string[] = [];
  @State entries: AiModelEntry[] = [];
  /** 当前展开编辑器的档位；'' 表示全部折叠。 */
  @State editFeature: string = '';

  aboutToAppear(): void {
    this.features = AiService.featureIds();
    this.reload();
  }

  private reload(): void {
    this.entries = AiService.listModelEntries();
  }

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
    if (feature === 'tts') return '云端播报与通话朗读的合成模型；不绑定则跟随语音档。';
    if (feature === 'asr') return '按住说话与通话语音输入的识别模型；不绑定则跟随语音档。';
    return '实时全双工通话模型（开口即打断）；不绑定则跟随语音档。';
  }

  /** 条目在功能页的可读名：名称 + 服务商/模型。 */
  private entryLabel(entry: AiModelEntry): string {
    const modelText: string = entry.model.length > 0 ? entry.model : '默认模型';
    return `${entry.name}（${AiService.presetOf(entry.providerId).name} · ${modelText}）`;
  }

  /** 下拉首项文案：音频档跟随语音档，其余跟随全局。 */
  private followLabel(feature: string): string {
    if (this.isAudioFeature(feature)) {
      return '跟随语音档';
    }
    const globalName: string = AiService.presetOf(AiService.loadConfig().providerId).name;
    return `跟随全局（${globalName}）`;
  }

  private optionItems(feature: string): SelectOption[] {
    const items: SelectOption[] = [];
    const first: SelectOption = { value: this.followLabel(feature) };
    items.push(first);
    for (let i = 0; i < this.entries.length; i++) {
      const opt: SelectOption = { value: this.entryLabel(this.entries[i]) };
      items.push(opt);
    }
    return items;
  }

  /** 当前选中下标：0=跟随，其余=库条目序（按已绑 entryId 找）。 */
  private selectedIndex(feature: string): number {
    const bound: string = AiService.loadFeatureEntry(feature);
    if (bound.length === 0) {
      return 0;
    }
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].id === bound) {
        return i + 1;
      }
    }
    return 0;
  }

  private selectEntry(feature: string, index: number): void {
    if (index <= 0) {
      AiService.bindFeatureEntry(feature, '');
      return;
    }
    const entry: AiModelEntry = this.entries[index - 1];
    AiService.bindFeatureEntry(feature, entry.id);
  }

  private enterFeature(feature: string): void {
    this.editFeature = this.editFeature === feature ? '' : feature;
    this.reload();
  }

  /** 生效配置一行人话：绑定条目名或跟随来源。 */
  private featureSummary(feature: string): string {
    const entryId: string = AiService.loadFeatureEntry(feature);
    if (entryId.length > 0) {
      const entry: AiModelEntry | null = AiService.modelEntryOf(entryId);
      if (entry !== null) {
        return `${entry.name}（已绑定）`;
      }
    }
    const cfg: AiConfig = AiService.loadFeatureConfig(feature);
    const name: string = AiService.presetOf(cfg.providerId).name;
    const model: string = cfg.model.length > 0 ? cfg.model : '默认模型';
    return `${name} · ${model}（${this.isAudioFeature(feature) ? '跟随语音档' : '跟随全局'}）`;
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
        Text('给单个功能指定模型：从「模型库」里挑一条（服务商与模型可自由组合，同一模型可被多个功能复用）。未绑定的功能自动跟随。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');

        Row() {
          Text('模型库')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'));
          Text(`共 ${this.entries.length} 条`)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ left: 8 });
          Blank();
          Text('管理 ›')
            .fontSize(13)
            .fontColor($r('app.color.brand_primary'))
            .onClick(() => AppRouter.pushUrl(this.getUIContext(), { url: 'pages/AiModelLibraryPage' }));
        }
        .width('100%');

        if (this.entries.length === 0) {
          Text('模型库还是空的：先去「管理」里添加模型条目（选服务商、填模型 id），再回来给功能绑定。')
            .fontSize(12)
            .fontColor($r('app.color.error'))
            .width('100%');
        }

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
              Select(this.optionItems(f))
                .selected(this.selectedIndex(f))
                .value(this.selectedIndex(f) === 0 ? this.followLabel(f) :
                  this.entryLabel(this.entries[this.selectedIndex(f) - 1]))
                .width('100%')
                .enabled(this.entries.length > 0)
                .onSelect((index: number, value: string) => this.selectEntry(f, index));
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
