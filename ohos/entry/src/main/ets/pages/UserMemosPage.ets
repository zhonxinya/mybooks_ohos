import {
  PageScaffold, LoadingState, EmptyState, IconCircleButton, ChipButton, PrimaryButton,
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { TalebookApi, ApiMessageResult } from '../services/TalebookApi';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { UserMemoItem, memoStageLabel, memoTypeLabel } from '../models/UserModels';

@Entry
@Component
struct UserMemosPage {
  @State memos: UserMemoItem[] = [];
  @State loading: boolean = true;
  @State loadError: string = '';
  @State showCreateSheet: boolean = false;
  @State newMemoType: number = 0;
  @State newMemoContent: string = '';
  @State submitting: boolean = false;
  /** 用户留言（/api/user/memo）为 mybooks 专有端点。 */
  @State supported: boolean = true;

  aboutToAppear(): void {
    this.supported = ServerRegistry.supports(ServerFeature.USER_MEMO);
    if (!this.supported) {
      this.loading = false;
      return;
    }
    void this.load();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private stageColor(stage: string): ResourceColor {
    if (stage === 'done') {
      return $r('app.color.success');
    }
    if (stage === 'suspend') {
      return $r('app.color.text_tertiary');
    }
    return $r('app.color.error');
  }

  private async load(): Promise<void> {
    if (!ServerRegistry.supports(ServerFeature.USER_MEMO)) {
      this.loading = false;
      return;
    }
    this.loading = this.memos.length === 0;
    this.loadError = '';
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.loadError = '请先配置 Talebook 服务器';
        return;
      }
      await TalebookService.ensureAuthenticated();
      this.memos = await TalebookApi.getUserMemos(1, 50);
    } catch (error) {
      this.loadError = `加载失败：${error}`;
    } finally {
      this.loading = false;
    }
  }

  private async submit(): Promise<void> {
    if (!ServerRegistry.supports(ServerFeature.USER_MEMO)) {
      return;
    }
    const content = this.newMemoContent.trim();
    if (content.length === 0) {
      this.toast('留言内容不能为空');
      return;
    }
    if (this.submitting) {
      return;
    }
    this.submitting = true;
    try {
      const rsp = await TalebookApi.createMemo(content, this.newMemoType);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '留言提交成功');
      this.showCreateSheet = false;
      this.newMemoContent = '';
      await this.load();
    } catch (error) {
      this.toast(`提交失败：${error}`);
    } finally {
      this.submitting = false;
    }
  }

  @Builder
  createMemoAction() {
    if (this.supported) {
      IconCircleButton({
        icon: $r('sys.symbol.plus'),
        variant: 'soft',
        iconSize: 18,
        buttonSize: 32,
        onTap: () => {
          this.newMemoContent = '';
          this.newMemoType = 0;
          this.showCreateSheet = true;
        },
      });
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '我的留言',
        showBack: true,
        action: () => {
          this.createMemoAction();
        },
        content: () => {
          this.listBody();
        },
      });
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showCreateSheet, this.createSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      title: { title: '新建留言' },
    });
  }

  @Builder
  listBody() {
    if (!this.supported) {
      EmptyState({ message: `${ServerRegistry.profile().displayName} 服务端不支持用户留言` });
    } else if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      EmptyState({ message: this.loadError });
    } else if (this.memos.length === 0) {
      EmptyState({
        message: '暂无留言',
        detail: '点击右上角 + 提交建议、求书或求助',
      });
    } else {
      List({ space: 10 }) {
        ForEach(this.memos, (memo: UserMemoItem) => {
          ListItem() {
            Column({ space: 8 }) {
              Row({ space: 8 }) {
                ChipButton({
                  label: memoTypeLabel(memo.memoType),
                  selected: false,
                });
                Text(memoStageLabel(memo.stage))
                  .fontSize(12)
                  .fontColor(this.stageColor(memo.stage));
                Blank().layoutWeight(1);
                Text(memo.createDate)
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'));
              }
              .width('100%')
              .alignItems(VerticalAlign.Center);
              Text(memo.memo)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .lineHeight(20)
                .width('100%');
              if (memo.reply.length > 0) {
                Column({ space: 4 }) {
                  Text('管理员回复')
                    .fontSize(11)
                    .fontColor($r('app.color.brand_primary'));
                  Text(memo.reply)
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                    .lineHeight(18)
                    .width('100%');
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding(8)
                .borderRadius(8)
                .backgroundColor($r('app.color.brand_primary_light'));
              }
            }
            .width('100%')
            .padding($r('app.float.card_padding'))
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'))
            .alignItems(HorizontalAlign.Start);
          }
        }, (memo: UserMemoItem) => `memo-${memo.id}-${memo.stage}`);
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 16 });
    }
  }

  @Builder
  createSheet() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        ChipButton({
          label: '建议',
          selected: this.newMemoType === 0,
          onTap: () => {
            this.newMemoType = 0;
          },
        });
        ChipButton({
          label: '求书',
          selected: this.newMemoType === 1,
          onTap: () => {
            this.newMemoType = 1;
          },
        });
        ChipButton({
          label: '求助',
          selected: this.newMemoType === 2,
          onTap: () => {
            this.newMemoType = 2;
          },
        });
      }
      .width('100%');
      TextArea({ text: this.newMemoContent, placeholder: '写下你的留言（最多 2048 字）' })
        .width('100%')
        .height(110)
        .onChange((value: string) => {
          this.newMemoContent = value;
        });
      PrimaryButton({
        label: '提交留言',
        buttonEnabled: !this.submitting,
        onTap: () => {
          void this.submit();
        },
      });
    }
    .width('100%')
    .padding($r('app.float.page_padding'));
  }
}
