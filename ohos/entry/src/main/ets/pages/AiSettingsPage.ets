import { PageScaffold, PrimaryButton, SecondaryButton, SectionTitle, FilterChips, FilterChipItem,
  ChipButton } from '../components';
import { AiService, AiConfig, AiProviderPreset, AiMessage, CONTEXT_LENGTH_OPTIONS } from '../services/AiService';
import { SpeakService } from '../services/SpeakService';
import { AppRouter } from '../utils/AppRouter';

/** @Builder 只有传单个对象字面量才是引用传递；标量参数不随 @State 更新，切服务商时输入框会停在旧值。 */
interface AiFieldParams {
  label: string;
  value: string;
  placeholder: string;
  onChange: (v: string) => void;
}

/**
 * AI 模型设置：本地配置，不依赖服务端。
 *
 * 「服务商 / 模型 / 语音 / 说明」四档 TAB 分开，每档只装本类设置；
 * 模型档额外维护本地常用模型清单（对话页快切菜单优先用它）。
 */
@Entry
@Component
struct AiSettingsPage {
  @State providerId: string = 'deepseek';
  /** FilterChips 的 selected 是 @Link，必须绑可写状态，不能传函数返回值。 */
  @State providerIndex: number = 0;
  @State providers: AiProviderPreset[] = [];
  @State showAddForm: boolean = false;
  @State newName: string = '';
  @State newBaseUrl: string = '';
  @State newModel: string = '';
  /** 「拉取模型」返回的模型 id；空表示还没拉过。 */
  @State modelOptions: string[] = [];
  @State fetchingModels: boolean = false;
  @State baseUrl: string = '';
  @State model: string = '';
  @State apiKey: string = '';
  @State temperature: number = 0.7;
  @State hasKey: boolean = false;
  /** vision 手动覆盖：''=按模型名自动检测。 */
  @State visionOverride: string = '';
  @State contextLength: number = 8;
  @State testing: boolean = false;
  @State testResult: string = '';
  @State testOk: boolean = false;
  @State probingVoice: boolean = false;
  @State autoSpeakOn: boolean = false;
  @State speakEngine: string = 'system';
  @State callMode: string = 'realtime';
  /** 语音通话对话模型：false=跟随全局；provider 0=跟随，其余=providers[index-1]。 */
  @State voiceFollow: boolean = true;
  @State voiceProviderId: string = '';
  @State voiceModel: string = '';
  @State voiceModelOptions: string[] = [];
  @State voiceFetchingModels: boolean = false;
  /** TAB 档位：0 服务商 / 1 模型 / 2 语音 / 3 说明。变量名避讳 CustomComponent.tabIndex 属性方法。 */
  @State activeTab: number = 0;
  /** 当前服务商的本地常用模型清单（对话页快切菜单数据源）。 */
  @State providerModels: string[] = [];
  /** 手动添加模型的输入框。 */
  @State newModelName: string = '';
  /** 拉取结果里已勾选、待并入清单的模型 id。 */
  @State pickedModels: string[] = [];

  aboutToAppear(): void {
    this.autoSpeakOn = AiService.loadAutoSpeak();
    this.speakEngine = AiService.loadSpeakEngine();
    this.callMode = AiService.loadCallMode();
    this.voiceProviderId = AiService.loadVoiceProviderId();
    this.voiceFollow = this.voiceProviderId.length === 0;
    this.voiceModel = AiService.loadVoiceModel();
    this.providers = AiService.listProviders();
    const config: AiConfig = AiService.loadConfig();
    this.providerId = config.providerId;
    this.providerIndex = this.indexOfProvider(config.providerId);
    this.baseUrl = config.baseUrl;
    this.model = config.model;
    this.hasKey = config.hasKey;
    this.temperature = config.temperature;
    this.visionOverride = config.visionOverride;
    this.contextLength = config.contextLength;
    this.providerModels = AiService.loadProviderModels(this.providerId);
    if (!this.hasKey) {
      // 未配置过时给出预设默认值，减少填空
      const preset: AiProviderPreset = AiService.presetOf(this.providerId);
      if (this.baseUrl.length === 0) {
        this.baseUrl = preset.baseUrl;
      }
      if (this.model.length === 0) {
        this.model = preset.model;
      }
    }
  }

  private chips(): FilterChipItem[] {
    const items: FilterChipItem[] = [];
    for (let i = 0; i < this.providers.length; i++) {
      items.push({ label: this.providers[i].name, value: i });
    }
    return items;
  }

  private selectProvider(id: string): void {
    if (this.providerId === id) {
      return;
    }
    this.providerId = id;
    this.providerIndex = this.indexOfProvider(id);
    const preset: AiProviderPreset = AiService.presetOf(id);
    // 切换服务商时地址与模型跟随预设；Key 各家不通用，但按服务商分开存过就不用重填
    this.baseUrl = preset.baseUrl;
    this.model = preset.model;
    this.apiKey = '';
    this.hasKey = AiService.hasKeyFor(id);
    this.testResult = '';
    this.modelOptions = [];
    this.providerModels = AiService.loadProviderModels(id);
    this.pickedModels = [];
    this.newModelName = '';
  }

  private isCustomSelected(): boolean {
    return this.providerId.startsWith('custom-');
  }

  /** 添加本机自定义服务商：只登记名字/地址/默认模型，Key 走下方主表单保存。 */
  private addProvider(): void {
    if (this.newName.trim().length === 0) {
      this.toast('请填写服务商名称');
      return;
    }
    if (this.newBaseUrl.trim().length === 0) {
      this.toast('请填写接口地址');
      return;
    }
    try {
      const preset: AiProviderPreset = AiService.addCustomProvider(this.newName, this.newBaseUrl, this.newModel);
      this.providers = AiService.listProviders();
      this.showAddForm = false;
      this.newName = '';
      this.newBaseUrl = '';
      this.newModel = '';
      this.selectProvider(preset.id);
      this.toast(`已添加「${preset.name}」`);
    } catch (error) {
      this.toast(error instanceof Error ? error.message : String(error));
    }
  }

  private confirmDeleteProvider(): void {
    const name: string = AiService.presetOf(this.providerId).name;
    this.getUIContext().showAlertDialog({
      title: '删除服务商',
      message: `确定删除「${name}」吗？其保存的 API Key 会一并清除。`,
      primaryButton: {
        value: '删除',
        action: () => {
          AiService.removeCustomProvider(this.providerId);
          this.providers = AiService.listProviders();
          this.selectProvider('deepseek');
          this.toast('已删除');
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  // ———— 本地常用模型清单（对话页快切菜单数据源，按服务商持久化） ————

  /** 手动把一个模型 id 加进清单（去重）。 */
  private addModelToList(): void {
    const name: string = this.newModelName.trim();
    if (name.length === 0) {
      this.toast('请填写模型名称');
      return;
    }
    if (this.providerModels.indexOf(name) >= 0) {
      this.toast('清单里已有该模型');
      return;
    }
    this.providerModels = this.providerModels.concat([name]);
    AiService.saveProviderModels(this.providerId, this.providerModels);
    this.newModelName = '';
  }

  private removeModel(name: string): void {
    this.providerModels = this.providerModels.filter((m: string): boolean => m !== name);
    AiService.saveProviderModels(this.providerId, this.providerModels);
  }

  private isPicked(name: string): boolean {
    return this.pickedModels.indexOf(name) >= 0;
  }

  private togglePick(name: string): void {
    this.pickedModels = this.isPicked(name)
      ? this.pickedModels.filter((m: string): boolean => m !== name)
      : this.pickedModels.concat([name]);
  }

  /** 把拉取列表里勾选的模型并入本地清单（去重后落盘）。 */
  private applyPicked(): void {
    if (this.pickedModels.length === 0) {
      this.toast('还没有勾选模型');
      return;
    }
    const merged: string[] = this.providerModels.slice();
    for (const m of this.pickedModels) {
      if (merged.indexOf(m) < 0) {
        merged.push(m);
      }
    }
    this.providerModels = merged;
    AiService.saveProviderModels(this.providerId, this.providerModels);
    this.pickedModels = [];
    this.toast(`已加入清单，共 ${merged.length} 个`);
  }

  /** 用当前填写的地址与 Key 拉模型列表；Key 留空则回退到该服务商已保存的。 */
  private async fetchModelList(): Promise<void> {
    if (this.fetchingModels) {
      return;
    }
    this.fetchingModels = true;
    this.testResult = '';
    try {
      const ids: string[] = await AiService.fetchModels(this.providerId, this.baseUrl, this.apiKey);
      if (ids.length === 0) {
        this.toast('该服务未返回模型列表');
      } else {
        this.modelOptions = ids;
        this.pickedModels = [];
        this.toast(`获取到 ${ids.length} 个模型，可从下拉选择`);
      }
    } catch (error) {
      this.testOk = false;
      this.testResult = error instanceof Error ? error.message : String(error);
    } finally {
      this.fetchingModels = false;
    }
  }

  /** 模型下拉数据源：拉取结果优先，未拉取时至少给出当前服务商预设。 */
  private modelSelectItems(): SelectOption[] {
    const ids: string[] = [];
    for (let i = 0; i < this.modelOptions.length; i++) {
      ids.push(this.modelOptions[i]);
    }
    const presetModel: string = AiService.presetOf(this.providerId).model;
    if (ids.length === 0 && presetModel.length > 0 && ids.indexOf(presetModel) < 0) {
      ids.push(presetModel);
    }
    if (this.model.length > 0 && ids.indexOf(this.model) < 0) {
      ids.push(this.model);
    }
    const items: SelectOption[] = [];
    for (let i = 0; i < ids.length; i++) {
      const opt: SelectOption = { value: ids[i] };
      items.push(opt);
    }
    return items;
  }

  private modelSelectIndex(): number {
    const idx: number = this.modelOptions.indexOf(this.model);
    return idx >= 0 ? idx : this.modelOptions.length;
  }

  private contextSelectItems(): SelectOption[] {
    const items: SelectOption[] = [];
    for (let i = 0; i < CONTEXT_LENGTH_OPTIONS.length; i++) {
      const opt: SelectOption = { value: `${CONTEXT_LENGTH_OPTIONS[i]}K` };
      items.push(opt);
    }
    return items;
  }

  private contextSelectIndex(): number {
    for (let i = 0; i < CONTEXT_LENGTH_OPTIONS.length; i++) {
      if (CONTEXT_LENGTH_OPTIONS[i] === this.contextLength) {
        return i;
      }
    }
    return 1;
  }

  /** 生效的 vision（手动覆盖优先，否则按模型名自动检测）。 */
  private visionOn(): boolean {
    if (this.visionOverride === 'on') {
      return true;
    }
    if (this.visionOverride === 'off') {
      return false;
    }
    return AiService.detectVision(this.model);
  }

  private save(): boolean {
    if (this.baseUrl.trim().length === 0) {
      this.toast('请填写接口地址');
      return false;
    }
    if (this.model.trim().length === 0) {
      this.toast('请填写模型名称');
      return false;
    }
    if (this.apiKey.trim().length === 0 && !this.hasKey) {
      this.toast('请填写 API Key');
      return false;
    }
    try {
      AiService.saveConfig(this.providerId, this.baseUrl, this.model, this.apiKey, this.temperature,
        this.visionOverride, this.contextLength);
      this.hasKey = true;
      this.apiKey = '';
      this.testResult = '';
      AppStorage.setOrCreate('aiConfigVersion', Date.now());
      this.toast('已保存');
      return true;
    } catch (error) {
      this.toast(error instanceof Error ? error.message : String(error));
      return false;
    }
  }

  /** 真实发一条最短的对话验证连通性：只看配置格式无法暴露地址/Key 错误。 */
  private async test(): Promise<void> {
    if (this.testing) {
      return;
    }
    if (!this.save()) {
      return;
    }
    this.testing = true;
    this.testResult = '';
    try {
      const messages: AiMessage[] = [{ role: 'user', content: '回复「ok」两个字符，不要还有其他内容。' }];
      const reply: string = await AiService.complete(messages, 16);
      this.testOk = reply.length > 0;
      this.testResult = this.testOk ? `连接正常，模型回复：${reply.substring(0, 40)}` : '连接成功但返回为空';
    } catch (error) {
      this.testOk = false;
      this.testResult = error instanceof Error ? error.message : String(error);
    } finally {
      this.testing = false;
    }
  }

  /** 语音链路探测：按当前播报引擎合成一句并播放（系统引擎在模拟器会报无引擎，可切云端档复测）。 */
  private async probeVoice(): Promise<void> {
    if (this.probingVoice) {
      return;
    }
    this.probingVoice = true;
    this.testResult = '';
    const engineName: string = AiService.loadSpeakEngine() === 'cloud' ? 'Token Plan 云端' : '系统语音';
    try {
      const completed: boolean = await SpeakService.speak('语音链路探测：合成与播放测试。');
      this.testOk = true;
      this.testResult = completed ? `${engineName}链路正常（播放完成）` : `${engineName}链路结束（被打断或提前停止）`;
    } catch (error) {
      this.testOk = false;
      this.testResult = `${engineName}链路失败：${error instanceof Error ? error.message : String(error)}`;
    } finally {
      this.probingVoice = false;
    }
  }

  private indexOfProvider(id: string): number {
    for (let i = 0; i < this.providers.length; i++) {
      if (this.providers[i].id === id) {
        return i;
      }
    }
    return 0;
  }

  // ———— 语音通话对话模型（改动即存，与自动播报开关同语义） ————

  /** 下拉首项固定为「跟随全局」，其余是全部服务商（预设+自定义）。 */
  private voiceProviderItems(): SelectOption[] {
    const items: SelectOption[] = [];
    const globalName: string = AiService.presetOf(AiService.loadConfig().providerId).name;
    const first: SelectOption = { value: `跟随全局（${globalName}）` };
    items.push(first);
    for (let i = 0; i < this.providers.length; i++) {
      const opt: SelectOption = { value: this.providers[i].name };
      items.push(opt);
    }
    return items;
  }

  private voiceProviderSelectedIndex(): number {
    if (this.voiceFollow) {
      return 0;
    }
    const idx: number = this.indexOfProvider(this.voiceProviderId);
    return idx >= 0 ? idx + 1 : 0;
  }

  private selectVoiceProvider(index: number): void {
    if (index <= 0) {
      this.voiceFollow = true;
      this.voiceProviderId = '';
      this.voiceModel = '';
      this.voiceModelOptions = [];
      AiService.saveVoiceConfig('', '');
      return;
    }
    const preset: AiProviderPreset = this.providers[index - 1];
    this.voiceFollow = false;
    this.voiceProviderId = preset.id;
    this.voiceModel = '';
    this.voiceModelOptions = [];
    AiService.saveVoiceConfig(preset.id, '');
  }

  private voiceModelItems(): SelectOption[] {
    const ids: string[] = [];
    for (let i = 0; i < this.voiceModelOptions.length; i++) {
      ids.push(this.voiceModelOptions[i]);
    }
    const presetModel: string = AiService.presetOf(this.voiceProviderId).model;
    if (ids.length === 0 && presetModel.length > 0) {
      ids.push(presetModel);
    }
    if (this.voiceModel.length > 0 && ids.indexOf(this.voiceModel) < 0) {
      ids.push(this.voiceModel);
    }
    const items: SelectOption[] = [];
    for (let i = 0; i < ids.length; i++) {
      const opt: SelectOption = { value: ids[i] };
      items.push(opt);
    }
    return items;
  }

  /** 语音服务商的接口地址：自定义商取注册地址；全局同款复用已保存的全局地址。 */
  private voiceBaseUrl(): string {
    const config: AiConfig = AiService.loadConfig();
    if (this.voiceProviderId === config.providerId) {
      return config.baseUrl;
    }
    return AiService.presetOf(this.voiceProviderId).baseUrl;
  }

  private async fetchVoiceModels(): Promise<void> {
    if (this.voiceFetchingModels || this.voiceProviderId.length === 0) {
      return;
    }
    this.voiceFetchingModels = true;
    try {
      const ids: string[] = await AiService.fetchModels(this.voiceProviderId, this.voiceBaseUrl(), '');
      if (ids.length === 0) {
        this.toast('该服务未返回模型列表');
      } else {
        this.voiceModelOptions = ids;
        this.toast(`获取到 ${ids.length} 个模型，可从下拉选择`);
      }
    } catch (error) {
      this.toast(error instanceof Error ? error.message : String(error));
    } finally {
      this.voiceFetchingModels = false;
    }
  }

  /** 当前生效的语音对话模型（一行人话，跟随全局时展示全局值）。 */
  private voiceSummary(): string {
    const voice: AiConfig = AiService.loadVoiceConfig();
    const name: string = AiService.presetOf(voice.providerId).name;
    return `当前使用：${name} · ${voice.model}`;
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
        title: 'AI 模型设置',
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
    Tabs({ index: this.activeTab }) {
      TabContent() {
        this.tabProvider();
      }
      .tabBar('服务商')

      TabContent() {
        this.tabModel();
      }
      .tabBar('模型')

      TabContent() {
        this.tabVoice();
      }
      .tabBar('语音')

      TabContent() {
        this.tabAbout();
      }
      .tabBar('说明')
    }
    .barMode(BarMode.Fixed)
    .width('100%')
    .height('100%')
    .onChange((index: number) => this.activeTab = index);
  }

  /** TAB 1 服务商：chips 选择/添加/删除 + 地址 + Key + 保存测试。 */
  @Builder
  tabProvider() {
    Scroll() {
      Column({ space: 16 }) {
        SectionTitle({ title: '服务商' });
        Scroll() {
          FilterChips({
            items: this.chips(),
            selected: $providerIndex,
            scrollable: true,
            onChange: (index: number) => this.selectProvider(this.providers[index].id),
            trailing: () => {
              this.addProviderChip();
            },
          });
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%');

        if (this.isCustomSelected()) {
          Text('删除该服务商')
            .fontSize(12)
            .fontColor($r('app.color.error'))
            .onClick(() => {
              this.confirmDeleteProvider();
            });
        }

        if (this.showAddForm) {
          Column({ space: 12 }) {
            this.field({ label: '名称', value: this.newName, placeholder: '如：公司网关',
              onChange: (v: string) => this.newName = v });
            this.field({ label: '接口地址', value: this.newBaseUrl, placeholder: 'https://example.com/v1',
              onChange: (v: string) => this.newBaseUrl = v });
            this.field({ label: '默认模型', value: this.newModel, placeholder: '可留空，保存后用「拉取模型列表」选择',
              onChange: (v: string) => this.newModel = v });
            Row({ space: 12 }) {
              PrimaryButton({
                label: '添加',
                onTap: () => {
                  this.addProvider();
                },
              }).layoutWeight(1);
              SecondaryButton({
                label: '取消',
                onTap: () => {
                  this.showAddForm = false;
                },
              }).layoutWeight(1);
            }
            .width('100%');
          }
          .width('100%')
          .padding($r('app.float.page_padding'))
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));
        }

        Column({ space: 12 }) {
          this.field({ label: '接口地址', value: this.baseUrl, placeholder: 'https://api.deepseek.com/v1',
            onChange: (v: string) => this.baseUrl = v });
          Column({ space: 6 }) {
            Text(this.hasKey ? 'API Key（已保存，留空则保持不变）' : 'API Key')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%');
            TextInput({ placeholder: this.hasKey ? '••••••••' : 'sk-...', text: this.apiKey })
              .type(InputType.Password)
              .height(44)
              .onChange((v: string) => this.apiKey = v);
          }
          .width('100%');
        }
        .width('100%')
        .padding($r('app.float.page_padding'))
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'));

        this.testResultLine();
        this.saveRow();
      }
      .width('100%')
      .padding($r('app.float.page_padding'))
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top);
  }

  /** TAB 2 模型：当前模型 + 本地常用清单管理 + 随机性/上下文/vision。 */
  @Builder
  tabModel() {
    Scroll() {
      Column({ space: 16 }) {
        SectionTitle({ title: '当前模型' });
        Column({ space: 12 }) {
          Column({ space: 6 }) {
            Row() {
              Text('模型')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'));
              Blank();
              Text(this.fetchingModels ? '拉取中…' : '拉取模型列表')
                .fontSize(13)
                .fontColor($r('app.color.brand_primary'))
                .onClick(() => {
                  void this.fetchModelList();
                });
            }
            .width('100%');
            TextInput({ placeholder: 'deepseek-chat', text: this.model })
              .height(44)
              .onChange((v: string) => this.model = v);
            Select(this.modelSelectItems())
              .selected(this.modelSelectIndex())
              .value(this.model.length > 0 ? this.model : '选择模型')
              .width('100%')
              .onSelect((index: number, value: string) => this.model = value);
          }
          .width('100%');
        }
        .width('100%')
        .padding($r('app.float.page_padding'))
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'));

        SectionTitle({ title: '常用模型清单' });
        Text('对话页顶栏快切菜单用这份清单；不用每次现拉全量列表。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
        Column({ space: 12 }) {
          if (this.providerModels.length === 0) {
            Text('清单为空（对话页将临时拉取服务商全量列表）')
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%');
          } else {
            ForEach(this.providerModels, (item: string) => {
              Row({ space: 8 }) {
                Text(item)
                  .fontSize(13)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
                Text(this.model === item ? '使用中' : '')
                  .fontSize(11)
                  .fontColor($r('app.color.brand_primary'));
                Text('删除')
                  .fontSize(12)
                  .fontColor($r('app.color.error'))
                  .onClick(() => {
                    this.removeModel(item);
                  });
              }
              .width('100%');
            }, (item: string) => item)
          }
          Row({ space: 12 }) {
            TextInput({ placeholder: '手动添加模型 id，如 gpt-4o', text: this.newModelName })
              .height(44)
              .layoutWeight(1)
              .onChange((v: string) => this.newModelName = v);
            SecondaryButton({
              label: '添加',
              onTap: () => {
                this.addModelToList();
              },
            });
          }
          .width('100%');

          if (this.modelOptions.length > 0) {
            Text(`拉取到 ${this.modelOptions.length} 个模型，点选后可加入清单：`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%');
            ForEach(this.modelOptions, (item: string) => {
              Row({ space: 8 }) {
                Text(this.isPicked(item) ? '☑' : '☐')
                  .fontSize(14)
                  .fontColor($r('app.color.brand_primary'));
                Text(item)
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
              }
              .width('100%')
              .onClick(() => {
                this.togglePick(item);
              });
            }, (item: string) => item)
            PrimaryButton({
              label: '把勾选项加入清单',
              onTap: () => {
                this.applyPicked();
              },
            }).width('100%');
          }
        }
        .width('100%')
        .padding($r('app.float.page_padding'))
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'));

        SectionTitle({ title: '生成参数' });
        Column({ space: 12 }) {
          Column({ space: 6 }) {
            Row() {
              Text('随机性')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'));
              Blank();
              Text(this.temperature.toFixed(1))
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'));
            }
            .width('100%');
            Slider({ value: this.temperature, min: 0, max: 1.5, step: 0.1 })
              .onChange((value: number) => this.temperature = value);
            Text('越低越稳定（适合摘要/元数据），越高越发散（适合推荐/书评）')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%');
          }
          .width('100%');

          Column({ space: 6 }) {
            Text('上下文长度')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%');
            Select(this.contextSelectItems())
              .selected(this.contextSelectIndex())
              .value(`${this.contextLength}K`)
              .width('100%')
              .onSelect((index: number, value: string) => {
                this.contextLength = CONTEXT_LENGTH_OPTIONS[index];
              });
            Text(`对话时携带最近约 ${AiService.contextRounds(this.contextLength)} 轮历史；档位越高越费 token`)
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%');
          }
          .width('100%');

          Column({ space: 6 }) {
            Row() {
              Text('图片能力（发送图片给模型）')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'));
              Blank();
              Toggle({ type: ToggleType.Switch, isOn: this.visionOn() })
                .onChange((on: boolean) => this.visionOverride = on ? 'on' : 'off');
            }
            .width('100%');
            Row({ space: 8 }) {
              Text(this.visionOverride.length === 0
                ? `按模型名自动检测：${this.visionOn() ? '支持' : '不支持'}`
                : `已手动${this.visionOverride === 'on' ? '开启' : '关闭'}`)
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'));
              if (this.visionOverride.length > 0) {
                Text('恢复自动')
                  .fontSize(11)
                  .fontColor($r('app.color.brand_primary'))
                  .onClick(() => this.visionOverride = '');
              }
            }
            .width('100%');
          }
          .width('100%');
        }
        .width('100%')
        .padding($r('app.float.page_padding'))
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'));

        this.testResultLine();
        this.saveRow();
      }
      .width('100%')
      .padding($r('app.float.page_padding'))
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top);
  }

  /** TAB 3 语音：播报引擎/探测/自动播报/通话模式/语音对话模型。 */
  @Builder
  tabVoice() {
    Scroll() {
      Column({ space: 16 }) {
        Row() {
          Text('播报引擎')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'));
          Blank();
          Select([{ value: '系统语音' }, { value: 'Token Plan 云端语音' }])
            .selected(this.speakEngine === 'cloud' ? 1 : 0)
            .value(this.speakEngine === 'cloud' ? 'Token Plan 云端语音' : '系统语音')
            .font({ size: 13 })
            .onSelect((index: number, value: string) => {
              this.speakEngine = index === 1 ? 'cloud' : 'system';
              AiService.saveSpeakEngine(this.speakEngine);
            });
        }
        .width('100%');

        Text('系统语音免流量、离线可播；模拟器没有系统语音引擎，播报报错时请切「Token Plan 云端语音」（需服务商为 Token Plan）。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');

        Row({ space: 12 }) {
          Text('语音能力探测（按当前播报引擎合成+播放）')
            .fontSize(13)
            .fontColor($r('app.color.brand_primary'))
            .onClick(() => {
              void this.probeVoice();
            });
          Blank();
          if (this.probingVoice) {
            Text('探测中…')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'));
          }
        }
        .width('100%');

        this.testResultLine();

        Row() {
          Text('回复自动播报（对话页）')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'));
          Blank();
          Toggle({ type: ToggleType.Switch, isOn: this.autoSpeakOn })
            .onChange((on: boolean) => {
              this.autoSpeakOn = on;
              AiService.saveAutoSpeak(on);
            });
        }
        .width('100%');

        Row() {
          Text('通话模式')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'));
          Blank();
          Select([{ value: '实时全双工（可打断）' }, { value: '轮转（一问一答）' }])
            .selected(this.callMode === 'turn' ? 1 : 0)
            .value(this.callMode === 'turn' ? '轮转（一问一答）' : '实时全双工（可打断）')
            .font({ size: 13 })
            .onSelect((index: number, value: string) => {
              this.callMode = index === 1 ? 'turn' : 'realtime';
              AiService.saveCallMode(this.callMode);
            });
        }
        .width('100%');

        Text('实时模式走 qwen-audio 实时服务（VAD 自动断句、开口即打断，需 Token Plan 服务商）；轮转模式按下方自选的对话模型+播报引擎逐轮对话。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');

        Column({ space: 6 }) {
          Text('语音通话对话模型（轮转模式）')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
          Text(this.voiceSummary())
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
          Select(this.voiceProviderItems())
            .selected(this.voiceProviderSelectedIndex())
            .value(this.voiceFollow ? '跟随全局' : AiService.presetOf(this.voiceProviderId).name)
            .width('100%')
            .onSelect((index: number, value: string) => this.selectVoiceProvider(index));
          if (!this.voiceFollow) {
            Row() {
              Text('模型')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'));
              Blank();
              Text(this.voiceFetchingModels ? '拉取中…' : '拉取模型列表')
                .fontSize(13)
                .fontColor($r('app.color.brand_primary'))
                .onClick(() => {
                  void this.fetchVoiceModels();
                });
            }
            .width('100%');
            Select(this.voiceModelItems())
              .selected(Math.max(0, this.voiceModelOptions.indexOf(this.voiceModel)))
              .value(this.voiceModel.length > 0 ? this.voiceModel : '使用该服务商默认模型')
              .width('100%')
              .onSelect((index: number, value: string) => {
                this.voiceModel = value;
                AiService.saveVoiceConfig(this.voiceProviderId, value);
              });
          }
        }
        .width('100%');
      }
      .width('100%')
      .padding($r('app.float.page_padding'))
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top);
  }

  /** TAB 4 说明：灵魂入口、使用说明、打开助手。 */
  @Builder
  tabAbout() {
    Scroll() {
      Column({ space: 16 }) {
        Row() {
          Text('灵魂与记忆')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'));
          Text('人格设定 · 跨对话记忆')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ left: 8 });
          Blank();
          Text('›')
            .fontSize(16)
            .fontColor($r('app.color.text_tertiary'));
        }
        .width('100%')
        .padding($r('app.float.page_padding'))
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'))
        .onClick(() => AppRouter.pushUrl(this.getUIContext(), { url: 'pages/AiPersonaPage' }));

        Column({ space: 8 }) {
          Text('说明')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%');
          Text('• 配置只存在本机，API Key 保存在系统关键资产存储（Asset Store），不会上传到本项目服务端。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
          Text('• 兼容任何 OpenAI 协议服务：OpenAI、DeepSeek、Kimi、智谱、通义、硅基流动、Ollama、LM Studio、OpenCode (Go)、OneAPI 等。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
          Text('• 用「＋ 添加」可把常用服务存成本机服务商，各自的 API Key 独立保存，来回切换不用重填。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
          Text('• 接口地址填到 /v1 层即可，程序会自动补 /chat/completions。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
          Text('• 开启图片能力后，对话页可附图发送，模型能看懂图片内容（需视觉模型，如 gpt-4o、qwen-vl、claude、gemini）。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
          Text('• 「模型」页的常用模型清单按服务商保存，对话页顶栏快切菜单优先用它。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
        }
        .width('100%')
        .padding($r('app.float.page_padding'))
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'));

        SecondaryButton({
          label: '打开 AI 助手',
          onTap: () => AppRouter.pushUrl(this.getUIContext(), { url: 'pages/AiAssistantPage' }),
        });
      }
      .width('100%')
      .padding($r('app.float.page_padding'))
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top);
  }

  /** 保存/测试结果行（服务商与模型两档共用同一状态）。 */
  @Builder
  testResultLine() {
    if (this.testResult.length > 0) {
      Text(this.testResult)
        .fontSize(12)
        .fontColor(this.testOk ? $r('app.color.success') : $r('app.color.error'))
        .width('100%');
    }
  }

  @Builder
  saveRow() {
    Row({ space: 12 }) {
      PrimaryButton({
        label: this.testing ? '测试中…' : '保存并测试',
        buttonEnabled: !this.testing,
        onTap: () => {
          void this.test();
        },
      }).layoutWeight(1);
      SecondaryButton({
        label: '仅保存',
        buttonEnabled: !this.testing,
        onTap: () => {
          this.save();
        },
      }).layoutWeight(1);
    }
    .width('100%');
  }

  /** chips 行尾部的「＋ 添加」：展开/收起本机服务商添加表单。 */
  @Builder
  addProviderChip() {
    ChipButton({
      label: this.showAddForm ? '收起' : '＋ 添加',
      selected: false,
      onTap: () => {
        this.showAddForm = !this.showAddForm;
      },
    });
  }

  @Builder
  field(params: AiFieldParams) {
    Column({ space: 6 }) {
      Text(params.label)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      TextInput({ placeholder: params.placeholder, text: params.value })
        .height(44)
        .onChange((v: string) => params.onChange(v));
    }
    .width('100%');
  }
}
