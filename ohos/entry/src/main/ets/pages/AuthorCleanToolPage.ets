import {
  PageScaffold, PrimaryButton, SecondaryButton, SettingCell, LoadingState
} from '../components';
import {
  TalebookApi, ApiMessageResult, apiErrorMessage,
  MetaListResponse, MetaNameCount
} from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';

@Entry
@Component
struct AuthorCleanToolPage {
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;

  @State authorName: string = '';
  @State action: string = 'clean';
  @State newAuthorName: string = '';
  @State searchQuery: string = '';
  @State suggestions: MetaNameCount[] = [];
  @State authorTotalHint: string = '';

  aboutToAppear(): void {
    void this.bootstrap();
  }

  private toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private setMsg(text: string, error: boolean): void {
    this.message = text;
    this.isError = error;
  }

  private actionLabel(): string {
    return this.action === 'replace' ? '替换作者名' : '清理作者名';
  }

  private cycleAction(): void {
    this.action = this.action === 'clean' ? 'replace' : 'clean';
  }

  private isValidNewAuthorName(name: string): boolean {
    if (name.length === 0) {
      return false;
    }
    if (name.indexOf(' ') >= 0 || name.indexOf("'") >= 0 || name.indexOf('"') >= 0) {
      return false;
    }
    return true;
  }

  private canSubmit(): boolean {
    if (this.authorName.trim().length === 0) {
      return false;
    }
    if (this.action === 'replace') {
      const neu = this.newAuthorName.trim();
      return neu.length > 0 && this.isValidNewAuthorName(neu);
    }
    return true;
  }

  private async bootstrap(): Promise<void> {
    this.loading = true;
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.setMsg('请先配置 Talebook 服务器', true);
        return;
      }
      await TalebookService.ensureAuthenticated();
      try {
        const rsp: MetaListResponse = await TalebookApi.getMetaList('author', true);
        const items = rsp.items !== undefined ? rsp.items : [];
        const total = rsp.total !== undefined ? rsp.total : items.length;
        this.authorTotalHint = `书库作者约 ${total} 位，可搜索后点选`;
      } catch (_e) {
        this.authorTotalHint = '可手动填写作者名，或搜索后点选';
      }
    } finally {
      this.loading = false;
    }
  }

  private async searchAuthors(): Promise<void> {
    if (this.busy) {
      return;
    }
    const q = this.searchQuery.trim().length > 0 ? this.searchQuery.trim() : this.authorName.trim();
    if (q.length === 0) {
      this.setMsg('请先输入要搜索的作者关键字', true);
      return;
    }
    if (!ServerRegistry.supports(ServerFeature.AUTHOR_SEARCH)) {
      this.setMsg(`${ServerRegistry.profile().displayName} 服务端不支持作者搜索`, true);
      return;
    }
    this.busy = true;
    try {
      const items: MetaNameCount[] = await TalebookApi.searchAuthors(q);
      this.suggestions = items.slice(0, 20);
      if (this.suggestions.length === 0) {
        this.setMsg('未找到匹配作者', true);
      } else {
        this.setMsg(`找到 ${this.suggestions.length} 个作者`, false);
      }
    } catch (e) {
      this.setMsg(`${e}`, true);
      this.suggestions = [];
    } finally {
      this.busy = false;
    }
  }

  private pickAuthor(name: string): void {
    this.authorName = name;
    this.toast(`已选择：${name}`);
  }

  private confirmStart(): void {
    if (this.busy) {
      return;
    }
    if (!this.canSubmit()) {
      if (this.action === 'replace' && this.newAuthorName.trim().length > 0 &&
        !this.isValidNewAuthorName(this.newAuthorName.trim())) {
        this.setMsg('新作者名不能含空格或引号', true);
      } else {
        this.setMsg(this.action === 'replace' ? '请填写作者名与新作者名' : '请填写作者名', true);
      }
      return;
    }
    const author = this.authorName.trim();
    const neu = this.newAuthorName.trim();
    const msg = this.action === 'replace'
      ? `将把作者「${author}」替换为「${neu}」。确定继续？`
      : `将清理作者「${author}」的名称（去噪/规范化）。确定继续？`;
    this.getUIContext().getPromptAction().showDialog({
      title: '确认作者清理',
      message: msg,
      buttons: [
        { text: '取消', color: '#999999' },
        { text: '开始', color: '#E84026' },
      ],
    }).then((result) => {
      if (result.index === 1) {
        void this.runClean();
      }
    }).catch(() => {});
  }

  private async runClean(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const neu = this.action === 'replace' ? this.newAuthorName.trim() : '';
      const rsp: ApiMessageResult = await TalebookApi.authorClean(
        this.action,
        this.authorName.trim(),
        neu,
      );
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '操作失败', true);
        return;
      }
      this.setMsg(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '操作成功', false);
    } catch (e) {
      this.setMsg(`${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '作者清理',
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
    if (this.loading) {
      LoadingState({});
    } else {
      Scroll() {
        Column({ space: 12 }) {
          Text('清理或替换书库中的作者名。可搜索后点选作者，再选择动作并确认执行。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');

          if (this.authorTotalHint.length > 0) {
            Text(this.authorTotalHint)
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%');
          }

          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(13)
              .fontColor(this.isError ? $r('app.color.error') : $r('app.color.success'))
              .width('100%');
          }

          Column({ space: 10 }) {
            TextInput({ placeholder: '作者名', text: this.authorName })
              .height(40)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((v: string) => {
                this.authorName = v;
              });
            TextInput({ placeholder: '搜索关键字（可留空则用作者名）', text: this.searchQuery })
              .height(40)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((v: string) => {
                this.searchQuery = v;
              });
          }
          .width('100%')
          .padding(12)
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          SecondaryButton({
            label: this.busy ? '搜索中…' : '搜索作者',
            buttonEnabled: !this.busy,
            onTap: () => {
              void this.searchAuthors();
            },
          });

          if (this.suggestions.length > 0) {
            Column() {
              ForEach(this.suggestions, (item: MetaNameCount) => {
                SettingCell({
                  title: item.name,
                  subtitle: `${item.count} 本`,
                  showChevron: true,
                  onTap: () => {
                    this.pickAuthor(item.name);
                  },
                });
              }, (item: MetaNameCount) => `${item.name}-${item.count}`);
            }
            .width('100%')
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'));
          }

          Column() {
            SettingCell({
              title: '动作',
              subtitle: this.actionLabel(),
              showChevron: true,
              onTap: () => {
                if (!this.busy) {
                  this.cycleAction();
                }
              },
            });
          }
          .width('100%')
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          if (this.action === 'clean') {
            Text('清理：规范化作者名（去噪）。')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%');
          } else {
            Column({ space: 10 }) {
              TextInput({ placeholder: '新作者名', text: this.newAuthorName })
                .height(40)
                .borderRadius(8)
                .backgroundColor($r('app.color.page_background'))
                .onChange((v: string) => {
                  this.newAuthorName = v;
                });
            }
            .width('100%')
            .padding(12)
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'));
            Text('替换：将旧作者名整体替换为新名（勿含空格或引号）。')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%');
          }

          PrimaryButton({
            label: this.busy ? '处理中…' : '开始',
            buttonEnabled: !this.busy,
            onTap: () => {
              this.confirmStart();
            },
          });
        }
        .padding({ left: 16, right: 16, top: 12, bottom: 24 })
        .width('100%');
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off);
    }
  }
}
