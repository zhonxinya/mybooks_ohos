import { router } from '@kit.ArkUI';
import {
  PageScaffold, PrimaryButton, SecondaryButton, SettingCell,
  LoadingState, EmptyState, TextButton
} from '../components';
import {
  TalebookApi, apiErrorMessage, ToolboxDataResponse
} from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';

@Entry
@Component
struct EpubSplitToolPage {
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;
  @State bookIdText: string = '';
  @State chapters: Record<string, Object>[] = [];
  @State selectedNums: number[] = [];
  @State useFirstChapterCover: boolean = false;
  @State resultHint: string = '';

  aboutToAppear(): void {
    void this.bootstrap();
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private setMsg(text: string, error: boolean): void {
    this.message = text;
    this.isError = error;
  }

  private async bootstrap(): Promise<void> {
    this.loading = true;
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.setMsg('请先配置 Talebook 服务器', true);
        return;
      }
      await TalebookService.ensureAuthenticated();
    } finally {
      this.loading = false;
    }
  }

  private chapterNum(item: Record<string, Object>): number {
    return Number(item['num'] ?? item['index'] ?? item['id'] ?? -1);
  }

  private chapterTitle(item: Record<string, Object>, index: number): string {
    const title = String(item['title'] ?? item['name'] ?? '');
    if (title.length > 0) {
      return title;
    }
    return `章节 ${this.chapterNum(item) >= 0 ? this.chapterNum(item) : index + 1}`;
  }

  private isSelected(num: number): boolean {
    return this.selectedNums.indexOf(num) >= 0;
  }

  private toggleChapter(num: number): void {
    if (num < 0) {
      return;
    }
    const next: number[] = [];
    let found = false;
    for (let i = 0; i < this.selectedNums.length; i++) {
      if (this.selectedNums[i] === num) {
        found = true;
      } else {
        next.push(this.selectedNums[i]);
      }
    }
    if (!found) {
      next.push(num);
    }
    this.selectedNums = next;
  }

  private selectAll(): void {
    const next: number[] = [];
    for (let i = 0; i < this.chapters.length; i++) {
      const n = this.chapterNum(this.chapters[i]);
      if (n >= 0) {
        next.push(n);
      }
    }
    this.selectedNums = next;
  }

  private clearSelection(): void {
    this.selectedNums = [];
  }

  private async loadChapters(): Promise<void> {
    if (this.busy) {
      return;
    }
    const bookId = Number(this.bookIdText.trim());
    if (!(bookId > 0)) {
      this.setMsg('请填写有效的书籍 ID', true);
      return;
    }
    this.busy = true;
    this.resultHint = '';
    try {
      const rsp: ToolboxDataResponse = await TalebookApi.epubSplitChapters(bookId);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.chapters = [];
        this.selectedNums = [];
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '加载章节失败', true);
        return;
      }
      const data = rsp.data;
      let list: Record<string, Object>[] = [];
      if (data !== undefined) {
        const raw = data['chapters'];
        if (Array.isArray(raw)) {
          list = raw as Record<string, Object>[];
        }
      }
      this.chapters = list;
      this.selectedNums = [];
      this.setMsg(list.length > 0 ? `已加载 ${list.length} 个章节` : '未找到可拆分章节', list.length === 0);
    } catch (e) {
      this.chapters = [];
      this.selectedNums = [];
      this.setMsg(`${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  private async generate(): Promise<void> {
    if (this.busy) {
      return;
    }
    const bookId = Number(this.bookIdText.trim());
    if (!(bookId > 0)) {
      this.setMsg('请填写有效的书籍 ID', true);
      return;
    }
    if (this.selectedNums.length === 0) {
      this.setMsg('请至少选择一个章节', true);
      return;
    }
    this.busy = true;
    try {
      const rsp: ToolboxDataResponse = await TalebookApi.epubSplitGenerate(
        bookId, this.selectedNums, this.useFirstChapterCover);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '拆分失败', true);
        return;
      }
      const data = rsp.data;
      let hint = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '拆分完成';
      if (data !== undefined) {
        const id = data['id'] ?? data['book_id'] ?? data['new_book_id'];
        const title = data['title'];
        if (id !== undefined) {
          hint = `${hint} · 新书 ID ${id}`;
        }
        if (title !== undefined) {
          hint = `${hint} · ${title}`;
        }
      }
      this.resultHint = hint;
      this.setMsg(hint, false);
      this.toast(hint);
    } catch (e) {
      this.setMsg(`${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: 'EPUB 拆分',
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
      Column({ space: 8 }) {
        if (this.message.length > 0) {
          Text(this.message)
            .fontSize(13)
            .fontColor(this.isError ? $r('app.color.error') : $r('app.color.success'))
            .width('100%')
            .padding({ left: 16, right: 16 });
        }
        if (this.resultHint.length > 0) {
          Text(this.resultHint)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ left: 16, right: 16 });
        }

        Column({ space: 10 }) {
          TextInput({ placeholder: '书籍 ID', text: this.bookIdText })
            .height(40)
            .borderRadius(8)
            .backgroundColor($r('app.color.page_background'))
            .onChange((v: string) => {
              this.bookIdText = v;
            });
          SecondaryButton({
            label: this.busy ? '加载中…' : '加载章节',
            buttonEnabled: !this.busy,
            onTap: () => {
              void this.loadChapters();
            },
          });
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8 });

        Column() {
          SettingCell({
            title: '使用首章封面',
            subtitle: '生成新书时用第一章封面',
            showToggle: true,
            toggleOn: this.useFirstChapterCover,
            onToggle: (v: boolean) => {
              this.useFirstChapterCover = v;
            },
          });
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        .borderRadius($r('app.float.card_radius'));

        if (this.chapters.length > 0) {
          Row({ space: 12 }) {
            Text(`已选 ${this.selectedNums.length}/${this.chapters.length}`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1);
            TextButton({
              label: '全选',
              onTap: () => {
                this.selectAll();
              },
            });
            TextButton({
              label: '清空',
              onTap: () => {
                this.clearSelection();
              },
            });
          }
          .width('100%')
          .padding({ left: 16, right: 16 });

          List({ space: 6 }) {
            ForEach(this.chapters, (item: Record<string, Object>, index: number) => {
              ListItem() {
                Row({ space: 8 }) {
                  Column({ space: 2 }) {
                    Text(this.chapterTitle(item, index))
                      .fontSize(14)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%');
                    Text(`#${this.chapterNum(item)}` +
                      (String(item['preview'] ?? '').length > 0
                        ? ` · ${String(item['preview']).substring(0, 40)}`
                        : ''))
                      .fontSize(11)
                      .fontColor($r('app.color.text_tertiary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%');
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start);

                  Text(this.isSelected(this.chapterNum(item)) ? '已选' : '选择')
                    .fontSize(12)
                    .fontColor(this.isSelected(this.chapterNum(item))
                      ? $r('app.color.brand_primary')
                      : $r('app.color.text_secondary'));
                }
                .width('100%')
                .padding(12)
                .borderRadius($r('app.float.card_radius'))
                .backgroundColor($r('app.color.card_background'))
                .onClick(() => {
                  this.toggleChapter(this.chapterNum(item));
                });
              }
            }, (item: Record<string, Object>, index: number) =>
              `ch-${this.chapterNum(item)}-${index}`);
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 8 });

          PrimaryButton({
            label: this.busy ? '生成中…' : `拆分生成（${this.selectedNums.length}）`,
            buttonEnabled: !this.busy && this.selectedNums.length > 0,
            onTap: () => {
              void this.generate();
            },
          });
        } else {
          EmptyState({
            message: '先填写书籍 ID 并加载章节',
          });
        }
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: 16 });
    }
  }
}
