import { PageScaffold, PrimaryButton, SecondaryButton, SectionTitle, FilterChips, FilterChipItem } from '../components';
import { AiService, AiConfig, AiProviderPreset, AI_PROVIDERS, AiMessage } from '../services/AiService';
import { AppRouter } from '../utils/AppRouter';

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
  @State baseUrl: string = '';
  @State model: string = '';
  @State apiKey: string = '';
  @State temperature: number = 0.7;
  @State hasKey: boolean = false;
  @State testing: boolean = false;
  @State testResult: string = '';
  @State testOk: boolean = false;

  aboutToAppear(): void {
    const config: AiConfig = AiService.loadConfig();
    this.providerId = config.providerId;
    this.providerIndex = this.indexOfProvider(config.providerId);
    this.baseUrl = config.baseUrl;
    this.model = config.model;
    this.hasKey = config.hasKey;
    this.temperature = config.temperature;
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
    for (let i = 0; i < AI_PROVIDERS.length; i++) {
      items.push({ label: AI_PROVIDERS[i].name, value: i });
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
    // 切换服务商时地址与模型跟随预设，Key 让用户重填（各家的 Key 不通用）
    this.baseUrl = preset.baseUrl;
    this.model = preset.model;
    this.apiKey = '';
    this.hasKey = false;
    this.testResult = '';
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
      AiService.saveConfig(this.providerId, this.baseUrl, this.model, this.apiKey, this.temperature);
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
            onChange: (index: number) => this.selectProvider(AI_PROVIDERS[index].id),
          });
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%');

        Column({ space: 12 }) {
          this.field('接口地址', this.baseUrl, 'https://api.deepseek.com/v1', (v: string) => this.baseUrl = v);
          this.field('模型', this.model, 'deepseek-chat', (v: string) => this.model = v);
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
          Text('• 兼容任何 OpenAI 协议服务：OpenAI、DeepSeek、Kimi、智谱、通义、硅基流动、Ollama、LM Studio、OneAPI 等。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
          Text('• 接口地址填到 /v1 层即可，程序会自动补 /chat/completions。')
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

  private indexOfProvider(id: string): number {
    for (let i = 0; i < AI_PROVIDERS.length; i++) {
      if (AI_PROVIDERS[i].id === id) {
        return i;
      }
    }
    return 0;
  }

  @Builder
  field(label: string, value: string, placeholder: string, onChange: (v: string) => void) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      TextInput({ placeholder: placeholder, text: value })
        .height(44)
        .onChange((v: string) => onChange(v));
    }
    .width('100%');
  }
}
