import { PageScaffold, PrimaryButton, SecondaryButton, SectionTitle, FilterChips, FilterChipItem,
  ChipButton } from '../components';
import { AiService, AiConfig, AiProviderPreset, AiMessage, CONTEXT_LENGTH_OPTIONS } from '../services/AiService';
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
 * 一个页面装下「选服务商 → 填地址/模型/Key → 测连通」的完整闭环，
 * 避免用户为了改一个字段来回跳页。
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

  aboutToAppear(): void {
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

  private indexOfProvider(id: string): number {
    for (let i = 0; i < this.providers.length; i++) {
      if (this.providers[i].id === id) {
        return i;
      }
    }
    return 0;
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

        if (this.testResult.length > 0) {
          Text(this.testResult)
            .fontSize(12)
            .fontColor(this.testOk ? $r('app.color.success') : $r('app.color.error'))
            .width('100%');
        }

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
