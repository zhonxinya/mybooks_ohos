import {
  PageScaffold, LoadingState, EmptyState, FilterChips, FilterChipItem,
  ChipButton, PrimaryButton, SecondaryButton, TextButton, SectionTitle,
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import {
  AnnotationApi, AnnotationItem, AnnotationWriteInput,
  ANNOTATION_TYPE_HIGHLIGHT, ANNOTATION_TYPE_NOTE, ANNOTATION_TYPE_BOOKMARK,
  ANNOTATION_TYPE_CHAPTER_COMMENT, ANNOTATION_SCOPE_VISIBLE, ANNOTATION_SCOPE_PUBLIC,
  ANNOTATION_SCOPE_MINE, annotationTypeLabel,
} from '../services/AnnotationApi';

interface ColorPreset {
  label: string;
  value: string;
}

/**
 * 书内标注（按书）：
 *   GET    /api/book/{bookId}/annotations[?scope=]
 *   POST   /api/book/{bookId}/annotations          （新建 / 带 client_id 重新 POST = 更新）
 *   DELETE /api/book/{bookId}/annotations/{id}
 */
@Entry
@Component
struct BookAnnotationsPage {
  @State supported: boolean = true;
  @State loading: boolean = true;
  @State loadError: string = '';
  @State items: AnnotationItem[] = [];
  @State scopeIndex: number = 0;
  @State editorOpen: boolean = false;
  @State editingId: number = 0;
  @State formType: number = 1;
  @State formCfi: string = '';
  @State formChapter: string = '';
  @State formQuote: string = '';
  @State formContent: string = '';
  @State formColor: string = '#FFD400';
  @State formPrivate: boolean = true;
  @State saving: boolean = false;
  @State bookTitle: string = '';
  private bookId: number = 0;
  private formClientId: string = '';
  private typeItems: FilterChipItem[] = [
    { label: '高亮', value: 1 },
    { label: '笔记', value: 2 },
    { label: '书签', value: 3 },
    { label: '章节批注', value: 4 },
  ];
  private scopeItems: FilterChipItem[] = [
    { label: '可见', value: 0 },
    { label: '公开', value: 1 },
    { label: '我的', value: 2 },
  ];
  private colorPresets: ColorPreset[] = [
    { label: '黄', value: '#FFD400' },
    { label: '绿', value: '#7ED321' },
    { label: '蓝', value: '#4A90E2' },
    { label: '粉', value: '#FF6B9D' },
    { label: '无', value: '' },
  ];

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object> | null;
    this.bookId = Number(params?.['bookId'] ?? 0);
    this.bookTitle = String(params?.['bookTitle'] ?? '');
    this.supported = ServerRegistry.supports(ServerFeature.ANNOTATIONS);
    if (!this.supported || this.bookId <= 0) {
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

  private async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.loadError = '尚未配置书库地址';
        return;
      }
      await TalebookService.ensureAuthenticated();
      this.items = await AnnotationApi.listBookAnnotations(this.bookId, this.scopeValue());
    } catch (error) {
      this.loadError = error instanceof Error ? error.message : `${error}`;
    } finally {
      this.loading = false;
    }
  }

  private scopeValue(): string {
    switch (this.scopeIndex) {
      case 1:
        return ANNOTATION_SCOPE_PUBLIC;
      case 2:
        return ANNOTATION_SCOPE_MINE;
      default:
        return ANNOTATION_SCOPE_VISIBLE;
    }
  }

  private typeValue(): string {
    switch (this.formType) {
      case 2:
        return ANNOTATION_TYPE_NOTE;
      case 3:
        return ANNOTATION_TYPE_BOOKMARK;
      case 4:
        return ANNOTATION_TYPE_CHAPTER_COMMENT;
      default:
        return ANNOTATION_TYPE_HIGHLIGHT;
    }
  }

  private typeIndexOf(type: string): number {
    switch (type) {
      case ANNOTATION_TYPE_NOTE:
        return 2;
      case ANNOTATION_TYPE_BOOKMARK:
        return 3;
      case ANNOTATION_TYPE_CHAPTER_COMMENT:
        return 4;
      default:
        return 1;
    }
  }

  /** 客户端幂等标识（上游限制 ≤64 字符，用于去重与更新）。 */
  private newClientId(): string {
    const random = Math.floor(Math.random() * 1000000);
    return `ohos-${Date.now()}-${random}`;
  }

  private openCreate(): void {
    this.editingId = 0;
    this.formClientId = this.newClientId();
    this.formType = 1;
    this.formCfi = '';
    this.formChapter = '';
    this.formQuote = '';
    this.formContent = '';
    this.formColor = '#FFD400';
    this.formPrivate = true;
    this.editorOpen = true;
  }

  private openEdit(item: AnnotationItem): void {
    if (!item.canEdit) {
      this.toast('只能编辑自己的标注');
      return;
    }
    if (item.clientId.length === 0) {
      // 上游更新端点仅取 (reader_id, book_id, client_id) 命中记录；无 client_id 无法原地更新
      this.toast('该标注不是本客户端创建的，无法编辑');
      return;
    }
    this.editingId = item.id;
    this.formClientId = item.clientId;
    this.formType = this.typeIndexOf(item.annotationType);
    this.formCfi = item.cfi;
    this.formChapter = item.chapter;
    this.formQuote = item.quoteText;
    this.formContent = item.content;
    this.formColor = item.color;
    this.formPrivate = item.isPrivate;
    this.editorOpen = true;
  }

  private async save(): Promise<void> {
    const quote = this.formQuote.trim();
    const content = this.formContent.trim();
    if (quote.length === 0 && content.length === 0) {
      this.toast('引文与笔记至少填写一项');
      return;
    }
    this.saving = true;
    const input: AnnotationWriteInput = {
      annotationType: this.typeValue(),
      clientId: this.formClientId,
      isPrivate: this.formPrivate,
      cfi: this.formCfi.trim(),
      chapter: this.formChapter.trim(),
      quoteText: quote,
      content: content,
      color: this.formColor,
    };
    try {
      const result = this.editingId > 0
        ? await AnnotationApi.updateAnnotation(this.bookId, this.editingId, input)
        : await AnnotationApi.createAnnotation(this.bookId, input);
      this.toast(result.created ? '已新建标注' : '已更新标注');
      this.editorOpen = false;
      await this.load();
    } catch (error) {
      this.toast(`保存失败：${error instanceof Error ? error.message : error}`);
    } finally {
      this.saving = false;
    }
  }

  private confirmDelete(item: AnnotationItem): void {
    this.getUIContext().showAlertDialog({
      title: '删除标注',
      message: '确定删除该条标注吗？该操作不可恢复。',
      primaryButton: {
        value: '删除',
        action: () => {
          void this.remove(item);
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private async remove(item: AnnotationItem): Promise<void> {
    try {
      const result = await AnnotationApi.deleteAnnotation(this.bookId, item.id);
      this.toast(`已删除 ${result.deleted} 条`);
      await this.load();
    } catch (error) {
      this.toast(`删除失败：${error instanceof Error ? error.message : error}`);
    }
  }

  /** 上游时间戳为 ISO 字符串（如 2026-09-12T08:30:00），这里截到分钟并去掉 T。 */
  private formatTime(value: string): string {
    if (value.length < 16) {
      return value;
    }
    return value.slice(0, 16).replace('T', ' ');
  }

  build() {
    Column() {
      PageScaffold({
        title: this.bookTitle.length > 0 ? `${this.bookTitle} · 标注` : '书内标注',
        showBack: true,
        action: () => {
          this.actionArea();
        },
        content: () => {
          this.pageContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  actionArea() {
    TextButton({
      label: this.editorOpen ? '取消' : '新建',
      onTap: () => {
        if (this.editorOpen) {
          this.editorOpen = false;
        } else {
          this.openCreate();
        }
      },
    });
  }

  @Builder
  pageContent() {
    if (!this.supported) {
      EmptyState({ message: `${ServerRegistry.profile().displayName} 服务端不支持标注` });
    } else if (this.bookId <= 0) {
      EmptyState({ message: '缺少书籍参数' });
    } else if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      EmptyState({
        message: this.loadError,
        actionLabel: '重试',
        onAction: () => {
          void this.load();
        },
      });
    } else if (this.editorOpen) {
      this.editorPanel();
    } else {
      this.listPanel();
    }
  }

  @Builder
  listPanel() {
    Column() {
      FilterChips({
        items: this.scopeItems,
        selected: $scopeIndex,
        onChange: () => {
          void this.load();
        },
      });
      if (this.items.length === 0) {
        EmptyState({
          message: '本书暂无标注',
          actionLabel: '新建标注',
          onAction: () => this.openCreate(),
        });
      } else {
        List({ space: 8 }) {
          ForEach(this.items, (item: AnnotationItem) => {
            ListItem() {
              this.annotationRow(item);
            }
          }, (item: AnnotationItem) => `book-annotation-${item.id}`);
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 12, right: 12 });
      }
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  annotationRow(item: AnnotationItem) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(annotationTypeLabel(item.annotationType))
          .fontSize(11)
          .fontColor($r('app.color.brand_primary'))
          .backgroundColor($r('app.color.brand_primary_light'))
          .borderRadius(8)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 });
        if (item.isPrivate) {
          Text('私有')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'));
        }
        Text(item.authorName)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .layoutWeight(1);
      }
      .width('100%');

      if (item.chapter.length > 0) {
        Text(item.chapter)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
      }
      if (item.quoteText.length > 0) {
        Text(item.quoteText)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
      }
      if (item.content.length > 0) {
        Text(item.content)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
      }
      Row({ space: 8 }) {
        Text(this.formatTime(item.updatedAt.length > 0 ? item.updatedAt : item.createdAt))
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .layoutWeight(1);
        if (item.canEdit) {
          TextButton({
            label: '编辑',
            onTap: () => this.openEdit(item),
          });
          TextButton({
            label: '删除',
            tone: 'danger',
            onTap: () => this.confirmDelete(item),
          });
        }
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.card_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  fieldLabel(text: string) {
    Text(text)
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'))
      .width('100%');
  }

  @Builder
  editorPanel() {
    Scroll() {
      Column({ space: 10 }) {
        SectionTitle({ title: this.editingId > 0 ? '编辑标注' : '新建标注' });

        this.fieldLabel('类型');
        FilterChips({
          items: this.typeItems,
          selected: $formType,
          onChange: () => {},
        });

        this.fieldLabel('位置（CFI，可留空）');
        TextInput({ text: this.formCfi, placeholder: '如 epubcfi(/6/8!/4/2)' })
          .width('100%')
          .height($r('app.float.button_height_compact'))
          .borderRadius(8)
          .backgroundColor($r('app.color.card_background'))
          .onChange((value: string) => {
            this.formCfi = value;
          });

        this.fieldLabel('章节（可留空）');
        TextInput({ text: this.formChapter, placeholder: '如 第一章' })
          .width('100%')
          .height($r('app.float.button_height_compact'))
          .borderRadius(8)
          .backgroundColor($r('app.color.card_background'))
          .onChange((value: string) => {
            this.formChapter = value;
          });

        this.fieldLabel('引文（与笔记至少填写一项）');
        TextArea({ text: this.formQuote, placeholder: '原文摘录' })
          .width('100%')
          .height(72)
          .onChange((value: string) => {
            this.formQuote = value;
          });

        this.fieldLabel('笔记');
        TextArea({ text: this.formContent, placeholder: '写下你的想法' })
          .width('100%')
          .height(96)
          .onChange((value: string) => {
            this.formContent = value;
          });

        this.fieldLabel('颜色');
        Row({ space: 8 }) {
          ForEach(this.colorPresets, (preset: ColorPreset) => {
            ChipButton({
              label: preset.label,
              selected: this.formColor === preset.value,
              onTap: () => {
                this.formColor = preset.value;
              },
            });
          }, (preset: ColorPreset) => `color-${preset.value}`);
        }
        .width('100%');

        Row({ space: 8 }) {
          Text('私有（仅自己可见）')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1);
          Toggle({ type: ToggleType.Switch, isOn: this.formPrivate })
            .onChange((value: boolean) => {
              this.formPrivate = value;
            });
        }
        .width('100%');

        Row({ space: 12 }) {
          SecondaryButton({
            label: '取消',
            fullWidth: false,
            onTap: () => {
              this.editorOpen = false;
            },
          })
            .layoutWeight(1);
          PrimaryButton({
            label: this.saving ? '保存中…' : (this.editingId > 0 ? '保存修改' : '创建标注'),
            fullWidth: false,
            buttonEnabled: !this.saving,
            onTap: () => {
              void this.save();
            },
          })
            .layoutWeight(1);
        }
        .width('100%');
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, bottom: 16 });
    }
    .layoutWeight(1)
    .width('100%');
  }
}
