import { PageScaffold } from '../components';
import { AiService, AiProviderPreset } from '../services/AiService';
import { ErrorFormat } from '../utils/ErrorFormat';

/**
 * 服务商管理（并行形态，参考 zcode_ohos 的供应商清单页）。
 *
 * 每家一卡：地址 / Key 状态 / 上次使用模型都在各自槽位互不覆盖，
 * 「默认」标记=普通对话用的服务商；「功能模型」页可再给各功能单独绑家。
 * 停用某家=它从 chips、功能槽下拉等所有选择面消失（已绑功能的旧绑定仍可用，仅不再可选）。
 * 预设里的 'custom' 占位项是设置页旧表单入口，不生成卡片。
 */
@Entry
@Component
struct AiProvidersPage {
  @State all: AiProviderPreset[] = [];
  @State currentId: string = '';
  @State editId: string = '';
  @State editBaseUrl: string = '';
  @State editModel: string = '';
  @State editKey: string = '';
  @State editHasKey: boolean = false;
  @State testingId: string = '';
  @State showAdd: boolean = false;
  @State newName: string = '';
  @State newBaseUrl: string = '';
  @State newModel: string = '';

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    const out: AiProviderPreset[] = [];
    const providers: AiProviderPreset[] = AiService.listProviders();
    for (let i = 0; i < providers.length; i++) {
      if (providers[i].id !== 'custom') {
        out.push(providers[i]);
      }
    }
    this.all = out;
    this.currentId = AiService.loadConfig().providerId;
  }

  /** 启停：当前默认服务商不可停用（否则对话无家可用）；重排数组触发 Toggle 回弹。 */
  private toggleEnabled(id: string, on: boolean): void {
    if (!on && id === this.currentId) {
      this.toast('当前默认服务商不能停用，请先切换默认');
      this.all = this.all.slice();
      return;
    }
    AiService.setProviderEnabled(id, on);
    this.all = this.all.slice();
  }

  private enterEdit(id: string): void {
    if (this.editId === id) {
      this.editId = '';
      return;
    }
    this.editId = id;
    this.editBaseUrl = AiService.baseUrlFor(id);
    this.editModel = AiService.modelFor(id);
    this.editKey = '';
    this.editHasKey = AiService.hasKeyFor(id);
  }

  private saveProfile(): void {
    if (this.editId.length === 0) {
      return;
    }
    AiService.updateProviderProfile(this.editId, this.editBaseUrl, this.editModel, this.editKey);
    this.toast('已保存');
    this.editId = '';
    this.all = this.all.slice();
  }

  /** 单家连通性测试：GET {base}/models，用该家已存 Key（各家地址/Key 独立所以可并行测）。 */
  private async testOne(id: string): Promise<void> {
    if (this.testingId.length > 0) {
      return;
    }
    this.testingId = id;
    try {
      const ids: string[] = await AiService.fetchModels(id, AiService.baseUrlFor(id), '');
      this.toast(`连接成功，${ids.length} 个模型`);
    } catch (error) {
      this.toast(ErrorFormat.message(error));
    } finally {
      this.testingId = '';
      this.all = this.all.slice();
    }
  }

  private setDefault(id: string): void {
    AiService.setDefaultProvider(id);
    this.currentId = id;
    this.toast(`「${AiService.presetOf(id).name}」已设为默认`);
  }

  private confirmDelete(preset: AiProviderPreset): void {
    this.getUIContext().showAlertDialog({
      title: '删除服务商',
      message: `确定删除「${preset.name}」吗？其保存的 API Key 会一并清除。`,
      primaryButton: {
        value: '删除',
        action: () => {
          AiService.removeCustomProvider(preset.id);
          this.reload();
          this.toast('已删除');
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private addProvider(): void {
    try {
      const preset: AiProviderPreset = AiService.addCustomProvider(this.newName, this.newBaseUrl, this.newModel);
      this.showAdd = false;
      this.newName = '';
      this.newBaseUrl = '';
      this.newModel = '';
      this.reload();
      this.toast(`已添加「${preset.name}」`);
    } catch (error) {
      this.toast(ErrorFormat.message(error));
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
        title: '服务商管理',
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
  actionText(label: string, color: ResourceColor, enabled: boolean, onTap: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(enabled ? color : $r('app.color.text_tertiary'))
      .padding({ top: 6, bottom: 6, right: 10 })
      .onClick(() => {
        if (enabled) {
          onTap();
        }
      });
  }

  @Builder
  providerCard(preset: AiProviderPreset) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(preset.name)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'));
            if (preset.id === this.currentId) {
              Text('默认')
                .fontSize(10)
                .fontColor(Color.White)
                .backgroundColor($r('app.color.brand_primary'))
                .borderRadius(4)
                .padding({ left: 5, right: 5, top: 1, bottom: 1 });
            }
            if (preset.id.startsWith('custom-')) {
              Text('自定义')
                .fontSize(10)
                .fontColor($r('app.color.text_tertiary'))
                .backgroundColor($r('app.color.page_background'))
                .borderRadius(4)
                .padding({ left: 5, right: 5, top: 1, bottom: 1 });
            }
          }
          Text(AiService.baseUrlFor(preset.id))
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
        Toggle({ type: ToggleType.Switch, isOn: AiService.isProviderEnabled(preset.id) })
          .onChange((on: boolean) => this.toggleEnabled(preset.id, on));
      }
      .width('100%');

      Row({ space: 10 }) {
        Text(AiService.hasKeyFor(preset.id) ? 'Key 已配置' : '未配 Key')
          .fontSize(11)
          .fontColor(AiService.hasKeyFor(preset.id) ? $r('app.color.success') : $r('app.color.error'));
        Text(`模型 ${AiService.modelFor(preset.id)}`)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .width('100%');

      Row() {
        this.actionText(this.editId === preset.id ? '收起' : '编辑',
          $r('app.color.brand_primary'), true, () => this.enterEdit(preset.id));
        this.actionText(this.testingId === preset.id ? '测试中…' : '测试',
          $r('app.color.brand_primary'), this.testingId.length === 0, () => {
            void this.testOne(preset.id);
          });
        if (preset.id !== this.currentId) {
          this.actionText('设为默认', $r('app.color.brand_primary'),
            AiService.isProviderEnabled(preset.id), () => this.setDefault(preset.id));
        }
        if (preset.id.startsWith('custom-')) {
          this.actionText('删除', $r('app.color.error'), true, () => this.confirmDelete(preset));
        }
      }
      .width('100%');

      if (this.editId === preset.id) {
        TextInput({ placeholder: '接口地址，如 https://api.example.com/v1', text: this.editBaseUrl })
          .fontSize(13)
          .onChange((v: string) => {
            this.editBaseUrl = v;
          });
        TextInput({ placeholder: this.editHasKey ? 'API Key（已保存，留空不修改）' : 'API Key（可选）',
          text: this.editKey })
          .fontSize(13)
          .onChange((v: string) => {
            this.editKey = v;
          });
        TextInput({ placeholder: '默认模型 id，如 deepseek-chat', text: this.editModel })
          .fontSize(13)
          .onChange((v: string) => {
            this.editModel = v;
          });
        Row() {
          Blank();
          Text('保存')
            .fontSize(13)
            .fontColor($r('app.color.brand_primary'))
            .padding(6)
            .onClick(() => this.saveProfile());
        }
        .width('100%');
      }
    }
    .width('100%')
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .alignItems(HorizontalAlign.Start)
    .opacity(AiService.isProviderEnabled(preset.id) ? 1 : 0.55);
  }

  @Builder
  pageContent() {
    Scroll() {
      Column({ space: 12 }) {
        Text('多家服务商并行配置：地址、Key、模型各存各的、互不覆盖。「默认」用于日常对话；「功能模型」页可给看图/摘要/语音等功能单独绑家；停用某家后它从所有选择列表消失。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');

        ForEach(this.all, (preset: AiProviderPreset) => {
          this.providerCard(preset);
        }, (preset: AiProviderPreset) => `${preset.id}-${this.currentId === preset.id ? 'd' : 'n'}-${
          AiService.isProviderEnabled(preset.id) ? 'on' : 'off'}-${this.editId === preset.id ? 'e' : 'c'}-${
          this.testingId === preset.id ? 't' : 'i'}`)

        Column({ space: 8 }) {
          if (!this.showAdd) {
            Text('＋ 添加服务商')
              .fontSize(14)
              .fontColor($r('app.color.brand_primary'))
              .onClick(() => {
                this.showAdd = true;
              });
          } else {
            Text('添加自定义服务商')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'));
            TextInput({ placeholder: '名称，如 我的 LM Studio', text: this.newName })
              .fontSize(13)
              .onChange((v: string) => {
                this.newName = v;
              });
            TextInput({ placeholder: '接口地址，如 http://192.168.1.5:1234/v1', text: this.newBaseUrl })
              .fontSize(13)
              .onChange((v: string) => {
                this.newBaseUrl = v;
              });
            TextInput({ placeholder: '默认模型 id（可留空）', text: this.newModel })
              .fontSize(13)
              .onChange((v: string) => {
                this.newModel = v;
              });
            Row() {
              Blank();
              Text('取消')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .padding(6)
                .onClick(() => {
                  this.showAdd = false;
                });
              Text('添加')
                .fontSize(13)
                .fontColor($r('app.color.brand_primary'))
                .padding(6)
                .onClick(() => this.addProvider());
            }
            .width('100%');
          }
        }
        .width('100%')
        .padding($r('app.float.page_padding'))
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'))
        .alignItems(HorizontalAlign.Start);
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
