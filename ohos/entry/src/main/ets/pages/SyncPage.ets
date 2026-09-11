import { router } from '@kit.ArkUI';
import {
  PageScaffold, PrimaryButton, SecondaryButton, DangerButton, SettingCell, EmptyState, LoadingState,
  SectionTitle, FilterChips, FilterChipItem,
} from '../components';
import {
  SyncApi, SyncRecord, SyncImportAnchor, SyncPullResult, syncErrorMessage,
} from '../services/SyncApi';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { DateFormat } from '../utils/DateFormat';

/** 拉取结果中用于列表展示的一行。 */
interface SyncRecordRow {
  key: string;
  kind: string;
  id: string;
  bookHash: string;
  updatedLabel: string;
  deleted: boolean;
}

/** 单次拉取最多展示的记录行数（避免长列表一次性渲染）。 */
const MAX_ROWS: number = 100;
/** 毫秒级时间戳下界：小于该值按秒级时间戳原样展示（updated_at 单位由客户端决定）。 */
const MILLIS_THRESHOLD: number = 1000000000000;
const PUSH_TEMPLATE: string = '{\n  "books": [],\n  "notes": [],\n  "configs": []\n}';
const ANCHOR_TEMPLATE: string = '[\n  { "id": "a1", "text": "正文片段", "chapterHint": "第一章", "note": "批注内容" }\n]';
/** 推送体允许的 kind（对应服务端 MyReaderSyncService.KINDS）。 */
const PUSH_KINDS: string[] = ['books', 'notes', 'configs'];

/** mybooks `/api/sync` 客户端：拉取 / 推送 / 第三方批注导入 / 清理导入。 */
@Entry
@Component
struct SyncPage {
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State notConfigured: boolean = false;
  @State unsupported: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;

  /** 拉取参数 */
  @State sinceText: string = '0';
  @State typeIndex: number = 0;
  @State bookHashText: string = '';
  @State ownShared: boolean = false;
  @State pullRows: SyncRecordRow[] = [];
  @State pullHint: string = '';

  /** 服务端同步状态/统计（since=0 全量拉取的条数） */
  @State statsHint: string = '';
  @State booksCount: number = 0;
  @State notesCount: number = 0;
  @State configsCount: number = 0;

  /** 推送 */
  @State pushText: string = PUSH_TEMPLATE;

  /** 导入 */
  @State importBookIdText: string = '';
  @State importAnchorsText: string = ANCHOR_TEMPLATE;
  @State importDryRun: boolean = true;
  @State importForce: boolean = false;
  @State importFirstMatch: boolean = false;
  @State importHint: string = '';

  /** 清理导入 */
  @State clearBookIdText: string = '';

  private typeItems: FilterChipItem[] = [
    { label: '全部', value: 0 },
    { label: 'books', value: 1 },
    { label: 'notes', value: 2 },
    { label: 'configs', value: 3 },
  ];

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
        this.notConfigured = true;
        return;
      }
      if (!ServerRegistry.supports(ServerFeature.SYNC)) {
        this.unsupported = true;
        return;
      }
      await TalebookService.ensureAuthenticated();
      await this.refreshStats();
    } catch (error) {
      this.setMsg(error instanceof Error ? error.message : `${error}`, true);
    } finally {
      this.loading = false;
    }
  }

  /** 拉取当前 type 选择对应的服务端 type 参数（'' 表示不传，服务端返回全部 kind）。 */
  private selectedType(): string {
    if (this.typeIndex === 1) {
      return 'books';
    }
    if (this.typeIndex === 2) {
      return 'notes';
    }
    if (this.typeIndex === 3) {
      return 'configs';
    }
    return '';
  }

  /** updated_at/deleted_at 单位由客户端决定：毫秒级转本地时间，秒级原样展示。 */
  private timestampLabel(value: number): string {
    if (value <= 0) {
      return '—';
    }
    if (value >= MILLIS_THRESHOLD) {
      return DateFormat.formatDateTime(value);
    }
    return `${value}（秒）`;
  }

  private appendRows(out: SyncRecordRow[], kind: string, records: SyncRecord[]): void {
    for (let i = 0; i < records.length; i++) {
      if (out.length >= MAX_ROWS) {
        return;
      }
      const record = records[i];
      const id = record.id ?? '（无 id）';
      const deletedAt = record.deleted_at ?? 0;
      out.push({
        key: `${kind}-${i}-${id}`,
        kind: kind,
        id: id,
        bookHash: record.book_hash ?? '—',
        updatedLabel: deletedAt > 0
          ? `已删除 · ${this.timestampLabel(deletedAt)}`
          : `更新于 ${this.timestampLabel(record.updated_at ?? 0)}`,
        deleted: deletedAt > 0,
      });
    }
  }

  private buildRows(result: SyncPullResult): SyncRecordRow[] {
    const rows: SyncRecordRow[] = [];
    this.appendRows(rows, 'books', result.books);
    this.appendRows(rows, 'notes', result.notes);
    this.appendRows(rows, 'configs', result.configs);
    return rows;
  }

  /** since=0 全量拉取，刷新顶部统计（服务端无独立统计接口，用记录条数代替）。 */
  private async refreshStats(): Promise<void> {
    const result = await SyncApi.pull(0);
    const failure = syncErrorMessage(result.err, result.msg);
    if (failure.length > 0) {
      this.setMsg(failure, true);
      this.statsHint = '';
      return;
    }
    this.booksCount = result.books.length;
    this.notesCount = result.notes.length;
    this.configsCount = result.configs.length;
    this.statsHint = DateFormat.formatDateTime(Date.now());
  }

  private async doPull(): Promise<void> {
    if (this.busy) {
      return;
    }
    const since = Number(this.sinceText.trim());
    if (isNaN(since)) {
      this.setMsg('since 必须是数字（时间戳）', true);
      return;
    }
    const type = this.selectedType();
    this.busy = true;
    try {
      const result = await SyncApi.pull(since, type.length > 0 ? type : undefined,
        this.bookHashText.trim(), this.ownShared ? 0 : 1);
      const failure = syncErrorMessage(result.err, result.msg);
      if (failure.length > 0) {
        this.setMsg(failure, true);
        this.toast(failure);
        return;
      }
      const rows = this.buildRows(result);
      this.pullRows = rows;
      const suffix = type.length > 0 ? `（type=${type}）` : '';
      const total = result.books.length + result.notes.length + result.configs.length;
      this.pullHint = `since=${since}${suffix} 返回 ${total} 条，展示 ${rows.length} 行`;
      this.setMsg('拉取完成', false);
      this.toast('拉取完成');
      await this.refreshStats();
    } catch (error) {
      const text = error instanceof Error ? error.message : `${error}`;
      this.setMsg(text, true);
      this.toast(text);
    } finally {
      this.busy = false;
    }
  }

  /** 校验推送文本域：非空、合法 JSON 对象、出现过的 kind 必须是数组。 */
  private validatePushBody(text: string): boolean {
    if (text.length === 0) {
      this.setMsg('推送内容为空，请填写 JSON', true);
      return false;
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(text) as Object;
    } catch (_e) {
      this.setMsg('推送内容不是合法的 JSON', true);
      return false;
    }
    if (Array.isArray(parsed)) {
      this.setMsg('推送内容必须是 JSON 对象（含 books / notes / configs）', true);
      return false;
    }
    const body = parsed as Record<string, Object>;
    const present: string[] = [];
    for (const kind of PUSH_KINDS) {
      const value = body[kind];
      if (value === undefined || value === null) {
        continue;
      }
      if (!Array.isArray(value)) {
        this.setMsg(`${kind} 必须是数组`, true);
        return false;
      }
      present.push(kind);
    }
    if (present.length === 0) {
      this.setMsg('推送内容需至少包含 books / notes / configs 之一', true);
      return false;
    }
    return true;
  }

  private async doPush(): Promise<void> {
    if (this.busy) {
      return;
    }
    const text = this.pushText.trim();
    if (!this.validatePushBody(text)) {
      return;
    }
    this.busy = true;
    try {
      const result = await SyncApi.pushRaw(text);
      const failure = syncErrorMessage(result.err, result.msg);
      if (failure.length > 0) {
        this.setMsg(failure, true);
        this.toast(failure);
        return;
      }
      const total = result.books.length + result.notes.length + result.configs.length;
      const detail = `books ${result.books.length} · notes ${result.notes.length} · configs ${result.configs.length}`;
      this.setMsg(`推送完成：服务端采纳 ${total} 条（${detail}）`, false);
      this.toast(total > 0 ? `推送完成，采纳 ${total} 条` : '推送成功，无记录被采纳');
      await this.refreshStats();
    } catch (error) {
      const msg = error instanceof Error ? error.message : `${error}`;
      this.setMsg(msg, true);
      this.toast(msg);
    } finally {
      this.busy = false;
    }
  }

  /** 校验锚点文本域：合法 JSON 数组、非空、每项都有 id（兼容 chapterHint / chapter_hint）。 */
  private parseAnchors(text: string, bookId: number): SyncImportAnchor[] | null {
    if (!(bookId > 0)) {
      this.setMsg('请填写有效的书籍 ID（book_id）', true);
      return null;
    }
    if (text.length === 0) {
      this.setMsg('锚点内容为空，请填写 JSON 数组', true);
      return null;
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(text) as Object;
    } catch (_e) {
      this.setMsg('锚点内容不是合法的 JSON', true);
      return null;
    }
    if (!Array.isArray(parsed)) {
      this.setMsg('锚点内容必须是 JSON 数组', true);
      return null;
    }
    const rows = parsed as Array<Record<string, Object>>;
    if (rows.length === 0) {
      this.setMsg('锚点数组不能为空', true);
      return null;
    }
    const anchors: SyncImportAnchor[] = [];
    for (let i = 0; i < rows.length; i++) {
      const id = `${rows[i]['id'] ?? ''}`.trim();
      if (id.length === 0) {
        this.setMsg(`第 ${i + 1} 个锚点缺少 id`, true);
        return null;
      }
      anchors.push({
        id: id,
        text: `${rows[i]['text'] ?? ''}`,
        chapterHint: `${rows[i]['chapterHint'] ?? rows[i]['chapter_hint'] ?? ''}`,
        note: `${rows[i]['note'] ?? ''}`,
      });
    }
    return anchors;
  }

  private async doImport(): Promise<void> {
    if (this.busy) {
      return;
    }
    const bookId = Number(this.importBookIdText.trim());
    const anchors = this.parseAnchors(this.importAnchorsText.trim(), bookId);
    if (anchors === null) {
      return;
    }
    this.busy = true;
    try {
      const result = await SyncApi.importAnchors({
        bookId: bookId,
        anchors: anchors,
        onAmbiguous: this.importFirstMatch ? 'first_match' : 'error',
        dryRun: this.importDryRun,
        force: this.importForce,
      });
      const failure = syncErrorMessage(result.err, result.msg);
      if (failure.length > 0) {
        this.setMsg(failure, true);
        this.toast(failure);
        return;
      }
      const mode = result.dry_run ? '预览' : '导入';
      this.importHint = `${mode}完成：book_hash ${result.book_hash ?? '—'}，定位 ${result.results.length} 个锚点`
        + `${result.pushed !== undefined ? '，已提交写入' : ''}`;
      this.setMsg(this.importHint, false);
      this.toast(`${mode}完成`);
      if (!result.dry_run) {
        await this.refreshStats();
      }
    } catch (error) {
      const msg = error instanceof Error ? error.message : `${error}`;
      this.setMsg(msg, true);
      this.toast(msg);
    } finally {
      this.busy = false;
    }
  }

  private async doClear(): Promise<void> {
    if (this.busy) {
      return;
    }
    const bookId = Number(this.clearBookIdText.trim());
    if (!(bookId > 0)) {
      this.setMsg('请填写有效的书籍 ID（book_id）', true);
      return;
    }
    this.busy = true;
    try {
      const result = await SyncApi.clearImported(bookId);
      const failure = syncErrorMessage(result.err, result.msg);
      if (failure.length > 0) {
        this.setMsg(failure, true);
        this.toast(failure);
        return;
      }
      const cleared = result.cleared ?? 0;
      this.importHint = `清理完成：book_hash ${result.book_hash ?? '—'}，清理 ${cleared} 条导入批注`;
      this.setMsg(this.importHint, false);
      this.toast(`已清理 ${cleared} 条`);
      await this.refreshStats();
    } catch (error) {
      const msg = error instanceof Error ? error.message : `${error}`;
      this.setMsg(msg, true);
      this.toast(msg);
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '数据同步',
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
    } else if (this.notConfigured) {
      EmptyState({
        message: '未配置服务器',
        detail: '请先在服务器配置中填写书库地址与账号',
        actionLabel: '去配置',
        onAction: () => router.pushUrl({ url: 'pages/TalebookConfigPage' }),
      });
    } else if (this.unsupported) {
      EmptyState({ message: `${ServerRegistry.profile().displayName} 服务端不支持同步` });
    } else {
      Scroll() {
        Column({ space: 12 }) {
          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(13)
              .fontColor(this.isError ? $r('app.color.error') : $r('app.color.success'))
              .width('100%');
          }
          this.statsCard();
          this.pullSection();
          this.pullRowsList();
          this.pushSection();
          this.importSection();
          this.clearSection();
        }
        .padding({ left: 16, right: 16, top: 12, bottom: 24 })
        .width('100%');
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off);
    }
  }

  @Builder
  statsCard() {
    Column() {
      SettingCell({
        title: '服务端',
        subtitle: '拉取 / 推送 / 导入均需登录该服务端',
        valueText: ServerRegistry.profile().displayName,
      });
      Divider().color($r('app.color.divider')).strokeWidth(0.5);
      SettingCell({ title: 'books', valueText: `${this.booksCount}` });
      SettingCell({ title: 'notes', valueText: `${this.notesCount}` });
      SettingCell({ title: 'configs', valueText: `${this.configsCount}` });
      Divider().color($r('app.color.divider')).strokeWidth(0.5);
      SettingCell({
        title: '最近统计时间',
        subtitle: 'since=0 全量拉取的记录条数',
        valueText: this.statsHint.length > 0 ? this.statsHint : '—',
      });
    }
    .width('100%')
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  pullSection() {
    Column({ space: 12 }) {
      SectionTitle({ title: '拉取（pull）' });

      Column({ space: 12 }) {
        Column({ space: 6 }) {
          Text('since（时间戳，必填）')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'));
          TextInput({ placeholder: '0 表示全量', text: this.sinceText })
            .height(44)
            .fontSize(14)
            .borderRadius(8)
            .backgroundColor($r('app.color.page_background'))
            .type(InputType.Number)
            .onChange((value: string) => {
              this.sinceText = value;
            });
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start);

        Column({ space: 6 }) {
          Text('book_hash（可选，限定单本书）')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'));
          TextInput({ placeholder: '留空表示不限定', text: this.bookHashText })
            .height(44)
            .fontSize(14)
            .borderRadius(8)
            .backgroundColor($r('app.color.page_background'))
            .onChange((value: string) => {
              this.bookHashText = value;
            });
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start);

        SettingCell({
          title: '并入其他用户的共享批注（own=0）',
          subtitle: '需填写 book_hash；受服务端 ENABLE_SHARED_NOTES 控制',
          showToggle: true,
          toggleOn: this.ownShared,
          onToggle: (value: boolean) => {
            this.ownShared = value;
          },
        });
      }
      .width('100%')
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));

      FilterChips({
        items: this.typeItems,
        selected: $typeIndex,
        onChange: (value: number) => {
          this.typeIndex = value;
        },
      });

      SecondaryButton({
        label: this.busy ? '处理中…' : '拉取',
        buttonEnabled: !this.busy,
        onTap: () => {
          void this.doPull();
        },
      });
    }
    .width('100%');
  }

  @Builder
  pullRowsList() {
    Column({ space: 8 }) {
      Text(this.pullHint.length > 0 ? this.pullHint : '尚未拉取；结果最多展示前 100 条')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      ForEach(this.pullRows, (row: SyncRecordRow) => {
        Column({ space: 2 }) {
          Row({ space: 8 }) {
            Text(row.kind)
              .fontSize(12)
              .fontColor($r('app.color.on_brand'))
              .backgroundColor($r('app.color.brand_primary'))
              .borderRadius(8)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 });
            Text(row.id)
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
          }
          .width('100%');

          Text(`book_hash: ${row.bookHash}`)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });

          Text(row.updatedLabel)
            .fontSize(11)
            .fontColor(row.deleted ? $r('app.color.error') : $r('app.color.text_secondary'))
            .width('100%');
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding($r('app.float.card_padding'))
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'));
      }, (row: SyncRecordRow) => row.key);
    }
    .width('100%');
  }

  @Builder
  pushSection() {
    Column({ space: 12 }) {
      SectionTitle({ title: '推送（push）' });

      Column({ space: 6 }) {
        Text('请求体（JSON：books / notes / configs）')
          .fontSize(15)
          .fontColor($r('app.color.text_primary'));
        TextArea({ text: this.pushText })
          .height(160)
          .fontSize(13)
          .borderRadius(8)
          .backgroundColor($r('app.color.page_background'))
          .onChange((value: string) => {
            this.pushText = value;
          });
        Text('按 (book_hash, record_id) 做 last-write-wins 合并，仅回传实际采纳的记录。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'));
      }
      .width('100%')
      .padding($r('app.float.card_padding'))
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));

      Row({ space: 12 }) {
        SecondaryButton({
          label: '重置模板',
          compact: true,
          fullWidth: false,
          buttonEnabled: !this.busy,
          onTap: () => {
            this.pushText = PUSH_TEMPLATE;
          },
        });
        PrimaryButton({
          label: this.busy ? '处理中…' : '推送',
          fullWidth: false,
          buttonEnabled: !this.busy,
          onTap: () => {
            void this.doPush();
          },
        });
      }
      .width('100%');
    }
    .width('100%');
  }

  @Builder
  importSection() {
    Column({ space: 12 }) {
      SectionTitle({ title: '导入批注（import）' });

      Column({ space: 12 }) {
        Column({ space: 6 }) {
          Text('book_id（需具备 EPUB 格式）')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'));
          TextInput({ placeholder: '书籍 ID', text: this.importBookIdText })
            .height(44)
            .fontSize(14)
            .borderRadius(8)
            .backgroundColor($r('app.color.page_background'))
            .type(InputType.Number)
            .onChange((value: string) => {
              this.importBookIdText = value;
            });
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start);

        Column({ space: 6 }) {
          Text('anchors（JSON 数组，每项需带 id）')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'));
          TextArea({ text: this.importAnchorsText })
            .height(140)
            .fontSize(13)
            .borderRadius(8)
            .backgroundColor($r('app.color.page_background'))
            .onChange((value: string) => {
              this.importAnchorsText = value;
            });
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start);

        SettingCell({
          title: '仅预览（dry_run）',
          subtitle: '关闭后定位成功即提交写入服务端',
          showToggle: true,
          toggleOn: this.importDryRun,
          onToggle: (value: boolean) => {
            this.importDryRun = value;
          },
        });
        SettingCell({
          title: '强制重新定位（force）',
          subtitle: '绕过重复导入的 CFI 去重（如替换过 EPUB）',
          showToggle: true,
          toggleOn: this.importForce,
          onToggle: (value: boolean) => {
            this.importForce = value;
          },
        });
        SettingCell({
          title: '歧义时取首个匹配',
          subtitle: 'on_ambiguous=first_match；关闭则为 error',
          showToggle: true,
          toggleOn: this.importFirstMatch,
          onToggle: (value: boolean) => {
            this.importFirstMatch = value;
          },
        });

        if (this.importHint.length > 0) {
          Text(this.importHint)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
        }
      }
      .width('100%')
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));

      PrimaryButton({
        label: this.busy ? '处理中…' : (this.importDryRun ? '执行导入（预览）' : '执行导入（提交）'),
        buttonEnabled: !this.busy,
        onTap: () => {
          void this.doImport();
        },
      });
    }
    .width('100%');
  }

  @Builder
  clearSection() {
    Column({ space: 12 }) {
      SectionTitle({ title: '清理导入（import/clear）' });

      Column({ space: 6 }) {
        Text('book_id')
          .fontSize(15)
          .fontColor($r('app.color.text_primary'));
        TextInput({ placeholder: '书籍 ID', text: this.clearBookIdText })
          .height(44)
          .fontSize(14)
          .borderRadius(8)
          .backgroundColor($r('app.color.page_background'))
          .type(InputType.Number)
          .onChange((value: string) => {
            this.clearBookIdText = value;
          });
        Text('仅清理本用户该书经 import 写入的 wxread- 批注，不影响其他批注。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'));
      }
      .width('100%')
      .padding($r('app.float.card_padding'))
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));

      DangerButton({
        label: this.busy ? '处理中…' : '清理导入批注',
        buttonEnabled: !this.busy,
        onTap: () => {
          void this.doClear();
        },
      });
    }
    .width('100%');
  }
}
