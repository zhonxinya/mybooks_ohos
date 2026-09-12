import { PageScaffold, LoadingState, EmptyState, PrimaryButton } from '../components';
import { TalebookApi, ApiMessageResult } from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';

@Entry
@Component
struct AdminMemosPage {
  @State memos: Record<string, Object>[] = [];
  @State loading: boolean = true;
  @State loadError: string = '';
  @State saving: boolean = false;
  @State showReplySheet: boolean = false;
  @State replyMemoId: number = -1;
  @State replyName: string = '';
  @State replyContent: string = '';
  @State replyMemo: Record<string, Object> = {};

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
    this.loading = this.memos.length === 0;
    this.loadError = '';
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.getAdminMemos(1, 100);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.loadError = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err;
        return;
      }
      const data = rsp.data ?? {};
      this.memos = (data['items'] as Record<string, Object>[] | undefined) ?? [];
    } catch (e) {
      this.loadError = `加载失败：${e}`;
    } finally {
      this.loading = false;
    }
  }

  private typeLabel(type: number): string {
    if (type === 0) {
      return '建议';
    }
    if (type === 1) {
      return '需求';
    }
    if (type === 2) {
      return '求助';
    }
    return String(type);
  }

  private stageLabel(stage: string): string {
    if (stage === 'done') {
      return '已完成';
    }
    if (stage === 'suspend') {
      return '已搁置';
    }
    return '待处理';
  }

  private stageColor(stage: string): ResourceColor {
    if (stage === 'done') {
      return $r('app.color.on_brand');
    }
    if (stage === 'suspend') {
      return $r('app.color.text_tertiary');
    }
    return $r('app.color.error');
  }

  private openReplySheet(memo: Record<string, Object>): void {
    this.replyMemo = memo;
    this.replyMemoId = Number(memo['id'] ?? 0);
    this.replyName = String(memo['reader_name'] ?? '');
    this.replyContent = '';
    this.showReplySheet = true;
  }

  private submitReply(): void {
    if (this.saving) {
      return;
    }
    this.saving = true;
    TalebookApi.resolveAdminMemo(this.replyMemoId, this.replyContent.trim())
      .then((rsp: ApiMessageResult) => {
        this.saving = false;
        if (rsp.err === undefined || rsp.err === 'ok') {
          this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已处理');
          this.showReplySheet = false;
          void this.load();
        } else {
          this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        }
      })
      .catch((e: Object) => {
        this.saving = false;
        this.toast(`操作失败：${e}`);
      });
  }

  private confirmDelete(memo: Record<string, Object>): void {
    this.getUIContext().showAlertDialog({
      title: '删除留言',
      message: '确定删除该留言吗？删除后不可恢复。',
      primaryButton: {
        value: '删除',
        action: () => {
          TalebookApi.deleteAdminMemo(Number(memo['id'] ?? 0))
            .then((rsp: ApiMessageResult) => {
              if (rsp.err === undefined || rsp.err === 'ok') {
                this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已删除');
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

  private showMemoActions(memo: Record<string, Object>): void {
    const stage = String(memo['stage'] ?? 'new');
    if (stage === 'done') {
      this.getUIContext().getPromptAction().showActionMenu({
        title: `${String(memo['reader_name'] ?? '')} 的留言`,
        buttons: [{ text: '删除留言', color: '#E84026' }],
      }).then((result) => {
        if (result.index === 0) {
          this.confirmDelete(memo);
        }
      }).catch(() => {});
    } else {
      this.getUIContext().getPromptAction().showActionMenu({
        title: `${String(memo['reader_name'] ?? '')} 的留言`,
        buttons: [
          { text: '标记完成并回复', color: '#007DFF' },
          { text: '删除留言', color: '#E84026' },
        ],
      }).then((result) => {
        if (result.index === 0) {
          this.openReplySheet(memo);
        } else if (result.index === 1) {
          this.confirmDelete(memo);
        }
      }).catch(() => {});
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '用户留言',
        showBack: true,
        content: () => {
          this.pageContent();
        },
      });
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showReplySheet, this.replySheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      title: { title: `回复 · ${this.replyName}` },
    });
  }

  @Builder
  pageContent() {
    if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      EmptyState({ message: this.loadError });
    } else if (this.memos.length === 0) {
      EmptyState({ message: '暂无留言' });
    } else {
      List({ space: 8 }) {
        ForEach(this.memos, (memo: Record<string, Object>) => {
          ListItem() {
            this.memoRow(memo);
          }
        }, (memo: Record<string, Object>) => `memo-${Number(memo['id'] ?? 0)}`);
      }
      .layoutWeight(1)
      .width('100%');
    }
  }

  @Builder
  memoRow(memo: Record<string, Object>) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(String(memo['reader_name'] ?? '访客'))
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        Text(this.typeLabel(Number(memo['memo_type'] ?? 0)))
          .fontSize(11)
          .fontColor($r('app.color.brand_primary'))
          .backgroundColor($r('app.color.brand_primary_light'))
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 });
        Text(this.stageLabel(String(memo['stage'] ?? '')))
          .fontSize(11)
          .fontColor(this.stageColor(String(memo['stage'] ?? '')))
          .backgroundColor($r('app.color.page_background'))
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 });
      }
      .width('100%');

      Text(String(memo['memo'] ?? ''))
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .maxLines(4)
        .textOverflow({ overflow: TextOverflow.Ellipsis });

      if (String(memo['reply'] ?? '').length > 0) {
        Text(`回复：${String(memo['reply'] ?? '')}`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }

      Text(String(memo['create_date'] ?? ''))
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'));
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(() => this.showMemoActions(memo));
  }

  @Builder
  replySheet() {
    Column({ space: 12 }) {
      Text(`标记留言为已完成并发送回复给 ${this.replyName}`)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'));
      TextInput({ text: this.replyContent, placeholder: '回复内容（留空发送「完成」）' })
        .height(44)
        .fontSize(14)
        .borderRadius(8)
        .backgroundColor($r('app.color.page_background'))
        .onChange((value: string) => {
          this.replyContent = value;
        });
      PrimaryButton({
        label: this.saving ? '提交中…' : '标记完成',
        buttonEnabled: !this.saving,
        onTap: () => this.submitReply(),
      });
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 16 });
  }
}
