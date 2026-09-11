import { router } from '@kit.ArkUI';
import {
  PageScaffold, LoadingState, EmptyState, SectionTitle, FilterChips, FilterChipItem,
  PrimaryButton, SecondaryButton
} from '../components';
import {
  AdminImportApi, AdminApiResult, BookFilePathResponse, TxtParserResponse,
  TxtReadResponse, TxtTocChapter
} from '../services/AdminImportApi';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';

/**
 * 单次读取的字节窗口上限。
 * 上游 `/api/read/txt/{id}` 在 `end = -1` 时会读到文件末尾，整本书回传会拖垮 UI，
 * 故客户端始终按窗口读取（默认 0 ~ 4000 字节）。
 */
const MAX_WINDOW_BYTES: number = 4000;
/** 目录预览条数上限 */
const MAX_CHAPTER_PREVIEW: number = 30;

/**
 * TXT 书籍工具（mybooks 专有）：
 * - 内容片段读取 `GET /api/read/txt/{id}?start=&end=`
 * - 解析查询/触发 `GET /api/book/txt/parser?id=&test=`
 * - 文件路径 `GET /api/book/{id}/filepath?format=epub|pdf`
 * - 馆藏位置 `POST /api/book/{id}/location`
 */
@Entry
@Component
struct TxtBookPage {
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;
  @State bookIdText: string = '';
  @State startText: string = '0';
  @State endText: string = `${MAX_WINDOW_BYTES}`;
  @State content: string = '';
  @State contentHint: string = '';
  @State parseHint: string = '';
  @State chapters: TxtTocChapter[] = [];
  @State fileFormat: number = 0;
  @State filePathLabel: string = '';
  @State locationText: string = '';
  private gated: boolean = !ServerRegistry.supports(ServerFeature.BOOK_TXT);
  private gatedFilePath: boolean = !ServerRegistry.supports(ServerFeature.BOOK_FILE_PATH);
  private gatedLocation: boolean = !ServerRegistry.supports(ServerFeature.BOOK_LOCATION);
  private formatItems: FilterChipItem[] = [{ label: 'EPUB', value: 0 }, { label: 'PDF', value: 1 }];

  aboutToAppear(): void {
    if (this.gated) {
      this.loading = false;
      return;
    }
    const rawParams = router.getParams();
    if (rawParams !== undefined) {
      const params = rawParams as Record<string, Object>;
      const rawId = params['bookId'];
      if (rawId !== undefined) {
        const bookId = Number(rawId);
        if (bookId > 0) {
          this.bookIdText = `${bookId}`;
        }
      }
    }
    void this.bootstrap();
  }

  private toast(text: string): void {
    this.getUIContext().getPromptAction().showToast({ message: text });
  }

  private setMsg(text: string, error: boolean): void {
    this.message = text;
    this.isError = error;
  }

  /** 读取并校验书籍 ID；无效时写提示并返回 0。 */
  private requireBookId(): number {
    const bookId = Number(this.bookIdText.trim());
    if (!(bookId > 0)) {
      this.setMsg('请填写有效的书籍 ID', true);
      return 0;
    }
    return bookId;
  }

  private async bootstrap(): Promise<void> {
    this.loading = true;
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.setMsg('请先在设置中配置服务器地址', true);
        return;
      }
      await TalebookService.ensureAuthenticated();
    } catch (e) {
      this.setMsg(`初始化失败：${e}`, true);
    } finally {
      this.loading = false;
    }
  }

  private async readContent(): Promise<void> {
    if (this.busy) {
      return;
    }
    const bookId = this.requireBookId();
    if (bookId <= 0) {
      return;
    }
    const rawStart = Number(this.startText.trim());
    const start = rawStart > 0 ? Math.floor(rawStart) : 0;
    let rawEnd = Number(this.endText.trim());
    if (!(rawEnd > start)) {
      rawEnd = start + MAX_WINDOW_BYTES;
    }
    const end = Math.min(rawEnd, start + MAX_WINDOW_BYTES);
    this.busy = true;
    try {
      const rsp: TxtReadResponse = await AdminImportApi.readTxtContent(bookId, start, end);
      if (!AdminImportApi.isOk(rsp)) {
        this.content = '';
        this.contentHint = '';
        this.setMsg(AdminImportApi.errorText(rsp).length > 0 ?
          AdminImportApi.errorText(rsp) : '读取内容失败', true);
        return;
      }
      const raw = rsp.content !== undefined ? rsp.content : '';
      // 服务端以 <br> 表示换行，此处还原便于阅读
      this.content = raw.replace(/<br>/g, '\n');
      this.contentHint = `字节区间 ${start} - ${end} · ${this.content.length} 字符`;
      this.setMsg('内容读取成功', false);
    } catch (e) {
      this.setMsg(`读取失败：${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  private async testParse(): Promise<void> {
    await this.runParse(true);
  }

  private async queueParse(): Promise<void> {
    await this.runParse(false);
  }

  /** testReady=true 仅查询解析状态（上游 test=1）；false 时未解析会加入解析队列（test=0）。 */
  private async runParse(testReady: boolean): Promise<void> {
    if (this.busy) {
      return;
    }
    const bookId = this.requireBookId();
    if (bookId <= 0) {
      return;
    }
    this.busy = true;
    try {
      const rsp: TxtParserResponse = await AdminImportApi.parseTxtBook(bookId, testReady);
      if (!AdminImportApi.isOk(rsp)) {
        this.chapters = [];
        this.parseHint = '';
        this.setMsg(AdminImportApi.errorText(rsp).length > 0 ?
          AdminImportApi.errorText(rsp) : '解析请求失败', true);
        return;
      }
      const data = rsp.data;
      if (data !== undefined && data.content !== undefined) {
        this.chapters = data.content;
        const encoding = data.encoding !== undefined && data.encoding.length > 0 ?
          data.encoding : '未知';
        const name = data.name !== undefined ? data.name : '';
        this.parseHint =
          `已解析${name.length > 0 ? ` · ${name}` : ''} · 编码 ${encoding} · 共 ${data.content.length} 章`;
        this.setMsg('目录已就绪', false);
        return;
      }
      this.chapters = [];
      const msg = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '';
      if (data !== undefined && data.wait !== undefined) {
        const que = data.que !== undefined ? data.que : 0;
        this.parseHint = `已加入解析队列 · 预计等待 ${Math.ceil(data.wait)} 秒 · 队列长度 ${que}`;
        this.setMsg('已加入解析队列', false);
      } else {
        this.parseHint = msg.length > 0 ? msg : '尚未解析';
        this.setMsg('该书籍尚未解析目录', true);
      }
    } catch (e) {
      this.setMsg(`解析失败：${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  private async queryFilePath(): Promise<void> {
    if (this.busy) {
      return;
    }
    const bookId = this.requireBookId();
    if (bookId <= 0) {
      return;
    }
    const format = this.fileFormat === 1 ? 'pdf' : 'epub';
    this.busy = true;
    try {
      const rsp: BookFilePathResponse = await AdminImportApi.getBookFilePath(bookId, format);
      if (!AdminImportApi.isOk(rsp)) {
        this.filePathLabel = '';
        this.setMsg(AdminImportApi.errorText(rsp).length > 0 ?
          AdminImportApi.errorText(rsp) : '查询文件路径失败', true);
        return;
      }
      const path = rsp.data !== undefined && rsp.data.path !== undefined ? rsp.data.path : '';
      this.filePathLabel = path.length > 0 ? `${format.toUpperCase()}：${path}` : '服务端未返回路径';
      this.setMsg('路径查询成功', false);
    } catch (e) {
      this.setMsg(`查询失败：${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  private async saveLocation(): Promise<void> {
    if (this.busy) {
      return;
    }
    const bookId = this.requireBookId();
    if (bookId <= 0) {
      return;
    }
    const location = this.locationText.trim();
    if (location.length > 20) {
      this.setMsg('位置信息过长（服务端限制 20 字符）', true);
      return;
    }
    this.busy = true;
    try {
      const rsp: AdminApiResult = await AdminImportApi.setBookLocation(bookId, location);
      if (!AdminImportApi.isOk(rsp)) {
        this.setMsg(AdminImportApi.errorText(rsp).length > 0 ?
          AdminImportApi.errorText(rsp) : '写入位置失败', true);
        return;
      }
      const msg = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '位置更新成功';
      this.setMsg(msg, false);
      this.toast(msg);
    } catch (e) {
      this.setMsg(`写入失败：${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: 'TXT 书籍工具',
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
    if (this.gated) {
      EmptyState({
        message: `当前服务端（${ServerRegistry.profile().displayName}）不支持 TXT 阅读与解析`,
      });
    } else if (this.loading) {
      LoadingState({});
    } else {
      Scroll() {
        Column({ space: 12 }) {
          Text('读取 TXT 内容片段、查询或触发目录解析，并维护书籍文件路径与馆藏位置。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');

          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(13)
              .fontColor(this.isError ? $r('app.color.error') : $r('app.color.success'))
              .width('100%');
          }

          Column({ space: 10 }) {
            TextInput({ placeholder: '书籍 ID', text: this.bookIdText })
              .type(InputType.Number)
              .height(40)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((value: string) => {
                this.bookIdText = value;
              });
          }
          .width('100%')
          .padding($r('app.float.card_padding'))
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          SectionTitle({ title: '内容片段读取' });
          Column({ space: 10 }) {
            Row({ space: 8 }) {
              TextInput({ placeholder: '起始字节', text: this.startText })
                .type(InputType.Number)
                .height(40)
                .layoutWeight(1)
                .borderRadius(8)
                .backgroundColor($r('app.color.page_background'))
                .onChange((value: string) => {
                  this.startText = value;
                });
              TextInput({ placeholder: '结束字节', text: this.endText })
                .type(InputType.Number)
                .height(40)
                .layoutWeight(1)
                .borderRadius(8)
                .backgroundColor($r('app.color.page_background'))
                .onChange((value: string) => {
                  this.endText = value;
                });
            }
            .width('100%');

            Text(`单次最多读取 ${MAX_WINDOW_BYTES} 字节；服务端以字节 seek，超出的结束位置会被截断。`)
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%');

            PrimaryButton({
              label: this.busy ? '读取中…' : '读取内容片段',
              buttonEnabled: !this.busy,
              onTap: () => {
                void this.readContent();
              },
            });

            if (this.contentHint.length > 0) {
              Text(this.contentHint)
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%');
            }
            if (this.content.length > 0) {
              Text(this.content)
                .fontSize(13)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .padding(8)
                .borderRadius(8)
                .backgroundColor($r('app.color.page_background'));
            }
          }
          .width('100%')
          .padding($r('app.float.card_padding'))
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          SectionTitle({ title: '目录解析' });
          Column({ space: 10 }) {
            SecondaryButton({
              label: '测试解析',
              buttonEnabled: !this.busy,
              onTap: () => {
                void this.testParse();
              },
            });
            SecondaryButton({
              label: '加入解析队列',
              buttonEnabled: !this.busy,
              onTap: () => {
                void this.queueParse();
              },
            });
            Text('「测试解析」只查询服务端是否已有解析结果；「加入解析队列」会在未解析时提交后台解析任务。')
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%');
            if (this.parseHint.length > 0) {
              Text(this.parseHint)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%');
            }
            if (this.chapters.length > 0) {
              Column({ space: 6 }) {
                ForEach(this.chapters.slice(0, MAX_CHAPTER_PREVIEW),
                  (chapter: TxtTocChapter, index: number) => {
                    Row({ space: 8 }) {
                      Text(`${index + 1}`)
                        .fontSize(12)
                        .fontColor($r('app.color.text_tertiary'))
                        .width(28);
                      Text(chapter.title !== undefined ? chapter.title : '')
                        .fontSize(13)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1);
                      Text(`#${chapter.start !== undefined ? chapter.start : 0}`)
                        .fontSize(11)
                        .fontColor($r('app.color.text_tertiary'));
                    }
                    .width('100%');
                  }, (chapter: TxtTocChapter, index: number) => `toc-${index}`);
                if (this.chapters.length > MAX_CHAPTER_PREVIEW) {
                  Text(`仅预览前 ${MAX_CHAPTER_PREVIEW} 章，共 ${this.chapters.length} 章`)
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                    .width('100%');
                }
              }
              .width('100%')
              .padding(8)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'));
            }
          }
          .width('100%')
          .padding($r('app.float.card_padding'))
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          if (!this.gatedFilePath) {
            SectionTitle({ title: '文件路径' });
            Column({ space: 10 }) {
              FilterChips({
                items: this.formatItems,
                selected: $fileFormat,
                onChange: (value: number) => {
                  this.fileFormat = value;
                },
              });
              SecondaryButton({
                label: '查询文件路径',
                buttonEnabled: !this.busy,
                onTap: () => {
                  void this.queryFilePath();
                },
              });
              if (this.filePathLabel.length > 0) {
                Text(this.filePathLabel)
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%');
              }
            }
            .width('100%')
            .padding($r('app.float.card_padding'))
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'));
          }

          if (!this.gatedLocation) {
            SectionTitle({ title: '馆藏位置' });
            Column({ space: 10 }) {
              TextInput({ placeholder: '位置（最多 20 字符）', text: this.locationText })
                .maxLength(20)
                .height(40)
                .borderRadius(8)
                .backgroundColor($r('app.color.page_background'))
                .onChange((value: string) => {
                  this.locationText = value;
                });
              PrimaryButton({
                label: '写入位置',
                buttonEnabled: !this.busy,
                onTap: () => {
                  void this.saveLocation();
                },
              });
            }
            .width('100%')
            .padding($r('app.float.card_padding'))
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'));
          }
        }
        .padding({ left: 16, right: 16, top: 4, bottom: 24 })
        .width('100%');
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off);
    }
  }
}
