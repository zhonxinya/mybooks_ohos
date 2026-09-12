import {
  PageScaffold, LoadingState, EmptyState, IconCircleButton, PrimaryButton, SecondaryButton,
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { TalebookApi, ApiMessageResult } from '../services/TalebookApi';
import { ExpectedItemModel } from '../models/UserModels';

@Entry
@Component
struct ExpectedBooksPage {
  @State items: ExpectedItemModel[] = [];
  @State loading: boolean = true;
  @State loadError: string = '';
  @State showAddSheet: boolean = false;
  @State newTitle: string = '';
  @State newAuthor: string = '';
  @State newPublisher: string = '';
  @State submitting: boolean = false;

  aboutToAppear(): void {
    void this.load();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private async load(): Promise<void> {
    this.loading = this.items.length === 0;
    this.loadError = '';
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.loadError = '请先配置 Talebook 服务器';
        return;
      }
      await TalebookService.ensureAuthenticated();
      this.items = await TalebookApi.getExpectedItems();
    } catch (error) {
      this.loadError = `加载失败：${error}`;
    } finally {
      this.loading = false;
    }
  }

  private async submit(): Promise<void> {
    const title = this.newTitle.trim();
    if (title.length === 0) {
      this.toast('书名不能为空');
      return;
    }
    if (this.submitting) {
      return;
    }
    this.submitting = true;
    try {
      const rsp = await TalebookApi.createExpectedItem(title, this.newAuthor.trim(),
        this.newPublisher.trim());
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '添加成功');
      this.showAddSheet = false;
      this.newTitle = '';
      this.newAuthor = '';
      this.newPublisher = '';
      await this.load();
    } catch (error) {
      this.toast(`添加失败：${error}`);
    } finally {
      this.submitting = false;
    }
  }

  private confirmDelete(item: ExpectedItemModel): void {
    this.getUIContext().showAlertDialog({
      title: '删除求书期望',
      message: `确定删除「${item.title}」的求书登记吗？`,
      primaryButton: {
        value: '删除',
        action: () => {
          TalebookApi.deleteExpectedItem(item.id)
            .then((rsp: ApiMessageResult) => {
              if (rsp.err === undefined || rsp.err === 'ok') {
                this.toast('已删除');
                void this.load();
              } else {
                this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
              }
            })
            .catch((e: Object) => this.toast(`删除失败：${e}`));
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  @Builder
  addAction() {
    IconCircleButton({
      icon: $r('sys.symbol.plus'),
      variant: 'soft',
      iconSize: 18,
      buttonSize: 32,
      onTap: () => {
        this.newTitle = '';
        this.newAuthor = '';
        this.newPublisher = '';
        this.showAddSheet = true;
      },
    });
  }

  build() {
    Column() {
      PageScaffold({
        title: '求书期望',
        showBack: true,
        action: () => {
          this.addAction();
        },
        content: () => {
          this.listBody();
        },
      });
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showAddSheet, this.addSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      title: { title: '登记求书' },
    });
  }

  @Builder
  listBody() {
    if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      EmptyState({ message: this.loadError });
    } else if (this.items.length === 0) {
      EmptyState({
        message: '暂无求书登记',
        detail: '点击右上角 + 登记你想读的书',
      });
    } else {
      List({ space: 10 }) {
        ForEach(this.items, (item: ExpectedItemModel) => {
          ListItem() {
            Row({ space: 10 }) {
              Column({ space: 4 }) {
                Text(item.title)
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
                Row({ space: 10 }) {
                  if (item.author.length > 0) {
                    Text(`作者：${item.author}`)
                      .fontSize(12)
                      .fontColor($r('app.color.text_secondary'));
                  }
                  if (item.publisher.length > 0) {
                    Text(`出版社：${item.publisher}`)
                      .fontSize(12)
                      .fontColor($r('app.color.text_secondary'));
                  }
                }
                Text(item.createTime)
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'));
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1);
              SymbolGlyph($r('sys.symbol.trash'))
                .fontSize(18)
                .fontColor([$r('app.color.error')])
                .padding(8)
                .onClick(() => this.confirmDelete(item));
            }
            .width('100%')
            .padding($r('app.float.card_padding'))
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'))
            .alignItems(VerticalAlign.Center);
          }
        }, (item: ExpectedItemModel) => `expected-${item.id}`);
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 16 });
    }
  }

  @Builder
  addSheet() {
    Column({ space: 12 }) {
      TextInput({ text: this.newTitle, placeholder: '书名（必填）' })
        .width('100%')
        .height(42)
        .onChange((value: string) => {
          this.newTitle = value;
        });
      TextInput({ text: this.newAuthor, placeholder: '作者（可选）' })
        .width('100%')
        .height(42)
        .onChange((value: string) => {
          this.newAuthor = value;
        });
      TextInput({ text: this.newPublisher, placeholder: '出版社（可选）' })
        .width('100%')
        .height(42)
        .onChange((value: string) => {
          this.newPublisher = value;
        });
      Row({ space: 12 }) {
        SecondaryButton({
          label: '取消',
          fullWidth: false,
          onTap: () => {
            this.showAddSheet = false;
          },
        })
          .layoutWeight(1);
        PrimaryButton({
          label: '登记',
          fullWidth: false,
          buttonEnabled: !this.submitting,
          onTap: () => {
            void this.submit();
          },
        })
          .layoutWeight(1);
      }
      .width('100%');
    }
    .width('100%')
    .padding($r('app.float.page_padding'));
  }
}
