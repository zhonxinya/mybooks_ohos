import { PageScaffold, EmptyState, LoadingState, SwipeDeleteAction, PrimaryButton, SecondaryButton, FilterChips, FilterChipItem } from '../components';
import { DownloadTask, DownloadTaskStatus } from '../services/TalebookService';
import { DownloadTaskService } from '../services/DownloadTaskService';
import { DateFormat } from '../utils/DateFormat';

const FILTER_ALL: number = 0;
const FILTER_TALEBOOK: number = 1;
const FILTER_SONOVEL: number = 2;

@Entry
@Component
struct DownloadManagerPage {
  @State tasks: DownloadTask[] = [];
  @State filteredTasks: DownloadTask[] = [];
  @State loading: boolean = true;
  @State processing: boolean = false;
  @State filterIndex: number = FILTER_ALL;
  @StorageProp('downloadTasksTick') @Watch('onTasksChanged') tasksTick: number = 0;
  private filterItems: FilterChipItem[] = [
    { label: '全部', value: FILTER_ALL },
    { label: 'Talebook', value: FILTER_TALEBOOK },
    { label: 'SoNovel', value: FILTER_SONOVEL },
  ];

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  aboutToAppear(): void {
    this.reloadTasks(true);
    this.processQueue();
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  onPageShow(): void {
    this.reloadTasks(false);
    this.processQueue();
  }

  private onTasksChanged(): void {
    this.reloadTasks(false);
    this.syncProcessingState();
  }

  private syncProcessingState(): void {
    this.processing = DownloadTaskService.isProcessing() ||
      this.tasks.some((task: DownloadTask) =>
        task.status === 'downloading' || task.status === 'pending');
  }

  private reloadTasks(showLoading: boolean): void {
    if (showLoading) {
      this.loading = true;
    }
    this.tasks = DownloadTaskService.getTasks();
    this.applyFilter();
    this.syncProcessingState();
    this.loading = false;
  }

  private applyFilter(): void {
    if (this.filterIndex === FILTER_TALEBOOK) {
      this.filteredTasks = this.tasks.filter((task: DownloadTask) => task.kind === 'talebook');
      return;
    }
    if (this.filterIndex === FILTER_SONOVEL) {
      this.filteredTasks = this.tasks.filter((task: DownloadTask) => task.kind !== 'talebook');
      return;
    }
    this.filteredTasks = this.tasks.slice();
  }

  private onFilterChanged(value: number): void {
    this.filterIndex = value;
    this.applyFilter();
  }

  /** @throws 内部系统调用（提示弹窗）可能抛出，由调用方处理 */
  private processQueue(showFeedback: boolean = false): void {
    this.reloadTasks(false);
    const pendingCount = this.tasks.filter((task: DownloadTask) => task.status === 'pending').length;
    const downloadingCount = this.tasks.filter((task: DownloadTask) => task.status === 'downloading').length;

    if (pendingCount === 0 && downloadingCount === 0) {
      if (showFeedback) {
        this.getUIContext().getPromptAction().showToast({ message: '暂无待下载任务' });
      }
      this.syncProcessingState();
      return;
    }

    DownloadTaskService.processQueue();
    this.syncProcessingState();
    if (showFeedback) {
      const maxConcurrent = DownloadTaskService.maxConcurrentDownloads();
      const active = Math.min(downloadingCount + pendingCount, maxConcurrent);
      this.getUIContext().getPromptAction().showToast({
        message: pendingCount > 0
          ? `正在并发下载（最多 ${maxConcurrent} 本），${pendingCount} 本等待中`
          : `正在下载中（${active}/${maxConcurrent}）`,
      });
    }
  }

  /**
   * 清空已完成任务。
   * @throws 内部系统调用（提示弹窗）可能抛出，由调用方处理
   */
  private clearCompletedTasks(): void {
    const completedCount = this.tasks.filter((task: DownloadTask) => task.status === 'completed').length;
    DownloadTaskService.clearCompleted();
    this.reloadTasks(false);
    if (completedCount > 0) {
      this.getUIContext().getPromptAction().showToast({ message: `已清空 ${completedCount} 个已完成任务` });
    } else {
      this.getUIContext().getPromptAction().showToast({ message: '没有已完成任务' });
    }
  }

  /** @throws 内部系统调用（提示弹窗）可能抛出，由调用方处理 */
  private openTask(task: DownloadTask): void {
    if (task.status === 'completed') {
      if (task.kind === 'talebook') {
        this.getUIContext().getPromptAction().showToast({
          message: `《${task.title}》已下载并加入书架`,
        });
      } else {
        this.getUIContext().getPromptAction().showToast({
          message: `《${task.title}》已在 SoNovel 服务器下载完成`,
        });
      }
      return;
    }
    if (task.status === 'failed') {
      this.getUIContext().getPromptAction().showToast({
        message: task.error.length > 0 ? task.error : '下载失败',
      });
      return;
    }
    if (task.status === 'pending') {
      this.getUIContext().getPromptAction().showToast({ message: '任务已排队，将按顺序下载' });
      this.processQueue(false);
      return;
    }
    if (task.status === 'downloading') {
      this.getUIContext().getPromptAction().showToast({
        message: task.message.length > 0 ? task.message : '正在下载中',
      });
    }
  }

  private showTaskActions(task: DownloadTask): void {
    if (task.status === 'failed') {
      this.getUIContext().getPromptAction().showActionMenu({
        title: task.title,
        buttons: [
          { text: '重试', color: '#007DFF' },
          { text: '删除', color: '#E84026' },
        ],
      }).then((result) => {
        if (result.index === 0) {
          DownloadTaskService.retry(task.id);
          this.processQueue(false);
        } else if (result.index === 1) {
          DownloadTaskService.remove(task.id);
        }
      }).catch(() => {});
      return;
    }
    if (task.status === 'completed') {
      this.getUIContext().getPromptAction().showActionMenu({
        title: task.title,
        buttons: [
          { text: '删除', color: '#E84026' },
        ],
      }).then((result) => {
        if (result.index === 0) {
          DownloadTaskService.remove(task.id);
        }
      }).catch(() => {});
    }
  }

  /** @throws 内部系统调用（提示弹窗）可能抛出，由调用方处理 */
  private deleteTask(task: DownloadTask): void {
    DownloadTaskService.remove(task.id);
    this.tasks = this.tasks.filter((item) => item.id !== task.id);
    this.getUIContext().getPromptAction().showToast({ message: '已删除' });
  }

  @Builder
  deleteAction(task: DownloadTask) {
    SwipeDeleteAction({ onDelete: () => this.deleteTask(task) });
  }

  private statusColor(status: DownloadTaskStatus): ResourceColor {
    if (status === 'completed') {
      return $r('app.color.brand_primary');
    }
    if (status === 'failed') {
      return '#E84026';
    }
    if (status === 'downloading') {
      return '#FF9500';
    }
    return $r('app.color.text_secondary');
  }

  private taskSubtitle(task: DownloadTask): string {
    if (task.status === 'downloading' && task.message.length > 0) {
      return task.message;
    }
    return `${DownloadTaskService.statusLabel(task.status)} · ${DateFormat.formatDateTime(task.updatedAt)}`;
  }

  @Builder
  taskItem(task: DownloadTask) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(task.title)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(`${task.author} · ${DownloadTaskService.kindLabel(task.kind)} · ${task.sourceName}`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(this.taskSubtitle(task))
          .fontSize(12)
          .fontColor(this.statusColor(task.status));
        if (task.status === 'downloading' && task.progress >= 0) {
          Progress({ value: task.progress, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(4)
            .color($r('app.color.brand_primary'));
        }
        if (task.error.length > 0 && task.status === 'failed') {
          Text(task.error)
            .fontSize(12)
            .fontColor('#E84026')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      if (task.status === 'downloading') {
        LoadingProgress()
          .width(24)
          .height(24)
          .color($r('app.color.brand_primary'));
      } else if (task.status === 'completed') {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize(20)
          .fontColor([$r('app.color.brand_primary')]);
      }
    }
    .width('100%')
    .padding(16)
    .onClick(() => this.openTask(task))
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction(() => this.showTaskActions(task)),
    );
  }

  @Builder
  managerContent() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        PrimaryButton({
          label: this.processing ? '下载中...' : '开始下载',
          fullWidth: false,
          buttonEnabled: true,
          onTap: () => this.processQueue(true),
        })
          .layoutWeight(1);
        SecondaryButton({
          label: '清空已完成',
          fullWidth: false,
          compact: true,
          onTap: () => this.clearCompletedTasks(),
        })
          .layoutWeight(1);
      }
      .width('100%');

      FilterChips({
        items: this.filterItems,
        selected: $filterIndex,
        onChange: (value: number) => this.onFilterChanged(value),
      })
        .width('100%');

      Text(`最多 ${DownloadTaskService.maxConcurrentDownloads()} 本并发下载，Talebook 下载完成后自动加入书架`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');

      Text('SoNovel 下载由服务器完成，不会保存到本地书架')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');

      if (this.loading) {
        LoadingState({});
      } else if (this.filteredTasks.length === 0) {
        EmptyState({
          message: this.tasks.length === 0 ? '暂无下载任务' : '当前筛选无任务',
          detail: this.filterIndex === FILTER_TALEBOOK
            ? '在 Talebook 书籍详情页点击下载'
            : this.filterIndex === FILTER_SONOVEL
              ? '在 SoNovel 搜索页选择书籍并下载'
              : 'Talebook 详情页或 SoNovel 搜索页均可添加任务',
          actionLabel: this.filterIndex === FILTER_TALEBOOK ? '去书库' : '去搜索',
          onAction: () => this.getUIContext().getRouter().pushUrl({
            url: this.filterIndex === FILTER_TALEBOOK ? 'pages/MainTabs' : 'pages/SoNovelSearchPage',
          }),
        });
      } else {
        List({ space: 8 }) {
          ForEach(this.filteredTasks, (task: DownloadTask) => {
            ListItem() {
              this.taskItem(task);
            }
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'))
            .swipeAction({
              end: {
                builder: () => {
                  this.deleteAction(task);
                },
              },
            });
          }, (task: DownloadTask) => task.id);
        }
        .layoutWeight(1)
        .width('100%');
      }
    }
    .width('100%')
    .height('100%')
    .padding($r('app.float.page_padding'));
  }

  build() {
    Column() {
      PageScaffold({
        title: '下载管理',
        showBack: true,
        content: () => {
          this.managerContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }
}
