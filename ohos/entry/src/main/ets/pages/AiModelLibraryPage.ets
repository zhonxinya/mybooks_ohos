import { PageScaffold } from '../components';
import { AiService, AiModelEntry, AiProviderPreset } from '../services/AiService';

/**
 * 模型库：模型条目 = 名称 + 服务商 + 模型 id 的自由组合。
 *
 * 把「服务商」与「模型」拆开管理：同一条目可被多个功能复用（功能模型页只做挑选），
 * 换服务商不会清空已选模型。条目只存服务商/模型名，地址与 Key 仍由服务商管理页维护。
 */
@Entry
@Component
struct AiModelLibraryPage {
  @State entries: AiModelEntry[] = [];
  @State providers: AiProviderPreset[] = [];
  /** 编辑态：'' 无；'add' 新增；否则为条目 id。 */
  @State editId: string = '';
  @State editName: string = '';
  @State editProviderIndex: number = 0;
  @State editModel: string = '';
  @State modelOptions: string[] = [];
  @State fetching: boolean = false;

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    this.entries = AiService.listModelEntries();
    this.providers = AiService.listEnabledProviders();
  }

  private providerItems(): SelectOption[] {
    const items: SelectOption[] = [];
    for (let i = 0; i < this.providers.length; i++) {
      const opt: SelectOption = { value: this.providers[i].name };
      items.push(opt);
    }
    return items;
  }

  private startAdd(): void {
    this.editId = 'add';
    this.editName = '';
    this.editProviderIndex = 0;
    this.editModel = '';
    this.modelOptions = [];
  }

  private startEdit(entry: AiModelEntry): void {
    if (this.editId === entry.id) {
      this.editId = '';
      return;
    }
    this.editId = entry.id;
    this.editName = entry.name;
    this.editModel = entry.model;
    this.modelOptions = [];
    this.editProviderIndex = this.indexOfProvider(entry.providerId);
  }

  private indexOfProvider(providerId: string): number {
    for (let i = 0; i < this.providers.length; i++) {
      if (this.providers[i].id === providerId) {
        return i;
      }
    }
    return 0;
  }

  private currentProviderId(): string {
    if (this.providers.length === 0) {
      return '';
    }
    const idx: number = Math.min(this.editProviderIndex, this.providers.length - 1);
    return this.providers[idx].id;
  }

  private async fetchModels(): Promise<void> {
    const providerId: string = this.currentProviderId();
    if (this.fetching || providerId.length === 0) {
      return;
    }
    this.fetching = true;
    try {
      const ids: string[] = await AiService.fetchModels(providerId, AiService.baseUrlFor(providerId), '');
      if (ids.length === 0) {
        this.toast('该服务未返回模型列表');
      } else {
        this.modelOptions = ids;
        this.toast(`获取到 ${ids.length} 个模型`);
      }
    } catch (error) {
      this.toast(error instanceof Error ? error.message : String(error));
    } finally {
      this.fetching = false;
    }
  }

  private modelItems(): SelectOption[] {
    const ids: string[] = [];
    for (let i = 0; i < this.modelOptions.length; i++) {
      ids.push(this.modelOptions[i]);
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

  private commit(): void {
    try {
      const providerId: string = this.currentProviderId();
      if (this.editId === 'add') {
        AiService.addModelEntry(this.editName, providerId, this.editModel);
        this.toast('已添加模型');
      } else {
        AiService.updateModelEntry(this.editId, this.editName, providerId, this.editModel);
        this.toast('已保存');
      }
      this.editId = '';
      this.reload();
    } catch (error) {
      this.toast(error instanceof Error ? error.message : String(error));
    }
  }

  private confirmRemove(entry: AiModelEntry): void {
    this.getUIContext().showAlertDialog({
      title: '删除模型条目',
      message: `确定删除「${entry.name}」吗？用到它的功能会退回「跟随」。`,
      primaryButton: {
        value: '删除',
        action: () => {
          AiService.removeModelEntry(entry.id);
          this.reload();
          this.toast('已删除');
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
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
        title: '模型库',
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
  editForm() {
    Select(this.providerItems())
      .selected(Math.min(this.editProviderIndex, Math.max(0, this.providers.length - 1)))
      .value(this.providers.length > 0 ?
        this.providers[Math.min(this.editProviderIndex, this.providers.length - 1)].name : '无可用服务商')
      .width('100%')
      .enabled(this.providers.length > 0)
      .onSelect((index: number, value: string) => {
        this.editProviderIndex = index;
        this.modelOptions = [];
      });
    Row() {
      Text('模型')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'));
      Blank();
      Text(this.fetching ? '拉取中…' : '拉取模型列表')
        .fontSize(13)
        .fontColor($r('app.color.brand_primary'))
        .onClick(() => {
          void this.fetchModels();
        });
    }
    .width('100%');
    if (this.modelOptions.length > 0) {
      Select(this.modelItems())
        .selected(Math.max(0, this.modelOptions.indexOf(this.editModel)))
        .value(this.editModel.length > 0 ? this.editModel : '选择模型')
        .width('100%')
        .onSelect((index: number, value: string) => {
          this.editModel = value;
        });
    } else {
      TextInput({ placeholder: '模型 id，如 deepseek-chat（也可点上方拉取）', text: this.editModel })
        .fontSize(13)
        .onChange((v: string) => {
          this.editModel = v;
        });
    }
    TextInput({ placeholder: '名称（可选，如「便宜摘要」「本地视觉」）', text: this.editName })
      .fontSize(13)
      .onChange((v: string) => {
        this.editName = v;
      });
    Row() {
      Blank();
      Text('取消')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .padding(6)
        .onClick(() => {
          this.editId = '';
        });
      Text(this.editId === 'add' ? '添加' : '保存')
        .fontSize(13)
        .fontColor($r('app.color.brand_primary'))
        .padding(6)
        .onClick(() => this.commit());
    }
    .width('100%');
  }

  @Builder
  pageContent() {
    Scroll() {
      Column({ space: 12 }) {
        Text('模型条目 = 服务商 + 模型的自由组合。建好后在「功能模型」页给各功能挑选；同一条目可被多个功能复用，换服务商不会清空已选模型。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');

        ForEach(this.entries, (entry: AiModelEntry) => {
          Column({ space: 6 }) {
            Row() {
              Column({ space: 2 }) {
                Text(entry.name)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'));
                Text(`${AiService.presetOf(entry.providerId).name} · ${
                  entry.model.length > 0 ? entry.model : '默认模型'}`)
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'));
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1);
              Text(this.editId === entry.id ? '收起' : '编辑')
                .fontSize(12)
                .fontColor($r('app.color.brand_primary'))
                .onClick(() => this.startEdit(entry));
              Text('删除')
                .fontSize(12)
                .fontColor($r('app.color.error'))
                .margin({ left: 12 })
                .onClick(() => this.confirmRemove(entry));
            }
            .width('100%');

            if (this.editId === entry.id) {
              this.editForm();
            }
          }
          .width('100%')
          .padding($r('app.float.page_padding'))
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'))
          .alignItems(HorizontalAlign.Start);
        }, (entry: AiModelEntry) => `${entry.id}-${entry.name}-${entry.model}-${
          this.editId === entry.id ? 'e' : 'c'}`)

        if (this.editId === 'add') {
          Column({ space: 6 }) {
            Text('新增模型条目')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'));
            this.editForm();
          }
          .width('100%')
          .padding($r('app.float.page_padding'))
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'))
          .alignItems(HorizontalAlign.Start);
        } else {
          Text('＋ 新增模型条目')
            .fontSize(13)
            .fontColor($r('app.color.brand_primary'))
            .onClick(() => this.startAdd());
        }
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
