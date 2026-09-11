import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  DownloadTask, DownloadTaskKind, DownloadTaskStatus, SoNovelBookPayload,
  TalebookDownloadPayload, TalebookService,
} from './TalebookService';
import { SoNovelDownloadProgress, SoNovelService } from './SoNovelService';
import { AccountStore } from './AccountStore';
import { ACCOUNT_LEGACY_ID, isLegacyAccount } from '../models/AccountModels';
import { ErrorFormat } from '../utils/ErrorFormat';

const TASKS_KEY: string = 'download_tasks';

export class DownloadTaskService {
  // /download-progress 为全局 SSE，并发时无法区分任务；并发下载仅依赖 book-fetch 结果。
  private static readonly MAX_CONCURRENT_DOWNLOADS: number = 3;
  private static readonly MAX_SETTLED_TASKS: number = 40;
  private static readonly PERSIST_DEBOUNCE_MS: number = 800;
  private static activeTaskIds: Set<string> = new Set();
  private static progressNotifyTimer: number = -1;
  private static persistTimer: number = -1;
  private static tasksCache: DownloadTask[] | null = null;
  private static persistDirty: boolean = false;

  static notifyChanged(): void {
    AppStorage.setOrCreate('downloadTasksTick', Date.now());
  }

  private static normalizeTask(task: DownloadTask): DownloadTask {
    return {
      id: task.id,
      kind: task.kind ?? 'sonovel',
      title: task.title,
      author: task.author,
      sourceName: task.sourceName,
      status: task.status,
      error: ErrorFormat.message(task.error ?? ''),
      filePath: task.filePath ?? '',
      format: task.format,
      bookId: task.bookId,
      progress: task.progress ?? 0,
      message: task.message ?? '',
      createdAt: task.createdAt,
      updatedAt: task.updatedAt,
      payload: task.payload,
      talebookPayload: task.talebookPayload,
    };
  }

  static getTasks(): DownloadTask[] {
    if (DownloadTaskService.tasksCache !== null) {
      return DownloadTaskService.tasksCache;
    }
    const raw = TalebookService.prefGet(TASKS_KEY, '[]');
    try {
      const tasks = JSON.parse(raw) as DownloadTask[];
      DownloadTaskService.tasksCache = tasks.map((task: DownloadTask) =>
        DownloadTaskService.normalizeTask(task));
    } catch (_error) {
      DownloadTaskService.tasksCache = [];
    }
    return DownloadTaskService.tasksCache;
  }

  static saveTasks(tasks: DownloadTask[], notify: boolean = true, persistNow: boolean = false): void {
    DownloadTaskService.tasksCache = DownloadTaskService.pruneTasks(tasks);
    DownloadTaskService.persistDirty = true;
    if (persistNow) {
      DownloadTaskService.flushPersist();
    } else {
      DownloadTaskService.schedulePersist();
    }
    if (notify) {
      DownloadTaskService.notifyChanged();
    }
  }

  private static pruneTasks(tasks: DownloadTask[]): DownloadTask[] {
    const active: DownloadTask[] = [];
    const settled: DownloadTask[] = [];
    for (let i = 0; i < tasks.length; i++) {
      const status = tasks[i].status;
      if (status === 'pending' || status === 'downloading') {
        active.push(tasks[i]);
      } else {
        settled.push(tasks[i]);
      }
    }
    if (settled.length > DownloadTaskService.MAX_SETTLED_TASKS) {
      settled.sort((a: DownloadTask, b: DownloadTask) => b.updatedAt - a.updatedAt);
      settled.length = DownloadTaskService.MAX_SETTLED_TASKS;
    }
    return active.concat(settled);
  }

  private static schedulePersist(): void {
    if (DownloadTaskService.persistTimer >= 0) {
      return;
    }
    DownloadTaskService.persistTimer = setTimeout(() => {
      DownloadTaskService.persistTimer = -1;
      DownloadTaskService.flushPersist();
    }, DownloadTaskService.PERSIST_DEBOUNCE_MS);
  }

  static flushPersist(): void {
    if (DownloadTaskService.persistTimer >= 0) {
      clearTimeout(DownloadTaskService.persistTimer);
      DownloadTaskService.persistTimer = -1;
    }
    if (!DownloadTaskService.persistDirty || DownloadTaskService.tasksCache === null) {
      return;
    }
    TalebookService.prefSet(TASKS_KEY, JSON.stringify(DownloadTaskService.tasksCache));
    DownloadTaskService.persistDirty = false;
  }

  private static scheduleProgressNotify(): void {
    if (DownloadTaskService.progressNotifyTimer >= 0) {
      return;
    }
    DownloadTaskService.progressNotifyTimer = setTimeout(() => {
      DownloadTaskService.progressNotifyTimer = -1;
      DownloadTaskService.notifyChanged();
    }, 250);
  }

  private static flushProgressNotify(): void {
    if (DownloadTaskService.progressNotifyTimer < 0) {
      return;
    }
    clearTimeout(DownloadTaskService.progressNotifyTimer);
    DownloadTaskService.progressNotifyTimer = -1;
  }

  static isProcessing(): boolean {
    return DownloadTaskService.activeTaskIds.size > 0;
  }

  static maxConcurrentDownloads(): number {
    return DownloadTaskService.MAX_CONCURRENT_DOWNLOADS;
  }

  private static useSseProgress(): boolean {
    return DownloadTaskService.MAX_CONCURRENT_DOWNLOADS === 1;
  }

  static downloadingCount(): number {
    return DownloadTaskService.activeTaskIds.size;
  }

  static activeCount(): number {
    return DownloadTaskService.getTasks().filter((task: DownloadTask) =>
      task.status === 'pending' || task.status === 'downloading').length;
  }

  static enqueue(payload: SoNovelBookPayload): DownloadTask {
    const tasks = DownloadTaskService.getTasks();
    const duplicate = tasks.find((task: DownloadTask) =>
      task.kind === 'sonovel' &&
      task.payload !== undefined &&
      task.payload.sourceId === payload.sourceId &&
      task.payload.url === payload.url &&
      (task.status === 'pending' || task.status === 'downloading'));
    if (duplicate !== undefined) {
      return duplicate;
    }

    const format = (payload.format ?? 'epub').toLowerCase();
    const task: DownloadTask = {
      id: util.generateRandomUUID(true),
      kind: 'sonovel',
      title: payload.bookName,
      author: payload.author,
      sourceName: payload.sourceName,
      status: 'pending',
      error: '',
      filePath: '',
      format: format.toUpperCase(),
      bookId: DownloadTaskService.buildSoNovelBookId(payload),
      progress: 0,
      message: '等待中',
      createdAt: Date.now(),
      updatedAt: Date.now(),
      payload: {
        sourceId: payload.sourceId,
        sourceName: payload.sourceName,
        url: payload.url,
        bookName: payload.bookName,
        author: payload.author,
        category: payload.category,
        latestChapter: payload.latestChapter,
        lastUpdateTime: payload.lastUpdateTime,
        status: payload.status,
        format: format,
        language: payload.language ?? 'zh-CN',
      },
    };
    tasks.unshift(task);
    DownloadTaskService.saveTasks(tasks, true, true);
    return task;
  }

  static enqueueTalebook(payload: TalebookDownloadPayload): DownloadTask {
    const tasks = DownloadTaskService.getTasks();
    const duplicate = tasks.find((task: DownloadTask) =>
      task.kind === 'talebook' &&
      task.talebookPayload !== undefined &&
      task.talebookPayload.bookId === payload.bookId &&
      task.talebookPayload.format.toLowerCase() === payload.format.toLowerCase() &&
      (task.status === 'pending' || task.status === 'downloading'));
    if (duplicate !== undefined) {
      return duplicate;
    }

    const format = payload.format.toUpperCase();
    const task: DownloadTask = {
      id: util.generateRandomUUID(true),
      kind: 'talebook',
      title: payload.bookName,
      author: payload.author,
      sourceName: 'Talebook',
      status: 'pending',
      error: '',
      filePath: '',
      format: format,
      bookId: `${payload.bookId}`,
      progress: 0,
      message: '等待中',
      createdAt: Date.now(),
      updatedAt: Date.now(),
      accountId: AccountStore.activeId(),
      talebookPayload: payload,
    };
    tasks.unshift(task);
    DownloadTaskService.saveTasks(tasks, true, true);
    return task;
  }

  static remove(taskId: string): void {
    const tasks = DownloadTaskService.getTasks().filter((task: DownloadTask) => task.id !== taskId);
    DownloadTaskService.saveTasks(tasks, true, true);
  }

  static clearCompleted(): void {
    const tasks = DownloadTaskService.getTasks().filter((task: DownloadTask) =>
      task.status !== 'completed');
    DownloadTaskService.saveTasks(tasks, true, true);
  }

  static retry(taskId: string): void {
    const tasks = DownloadTaskService.getTasks();
    const index = tasks.findIndex((task: DownloadTask) => task.id === taskId);
    if (index < 0) {
      return;
    }
    tasks[index].status = 'pending';
    tasks[index].error = '';
    tasks[index].progress = 0;
    tasks[index].message = '等待中';
    tasks[index].updatedAt = Date.now();
    DownloadTaskService.saveTasks(tasks, true, true);
  }

  static processQueue(): void {
    DownloadTaskService.recoverStaleTasks();
    DownloadTaskService.failForeignAccountTasks();
    DownloadTaskService.pumpWorkers();
  }

  /**
   * 把不属于当前账号的待下载 talebook 任务标记为失败。
   *
   * 任务队列存在全局偏好中（不随账号隔离），而 talebook 下载走当前账号的服务器地址；
   * 若切换账号后仍执行旧任务，会向错误的服务器请求同 id 的书。SoNovel 任务不受影响（其服务为全局配置）。
   * 空 accountId 视为历史默认账号（升级前入队的任务）。
   */
  private static failForeignAccountTasks(): void {
    const rawActive = AccountStore.activeId();
    const current = isLegacyAccount(rawActive) ? ACCOUNT_LEGACY_ID : rawActive;
    const tasks = DownloadTaskService.getTasks();
    let changed = false;
    for (const task of tasks) {
      if (task.status !== 'pending' || task.kind !== 'talebook') {
        continue;
      }
      const rawOwner = task.accountId ?? '';
      const owner = isLegacyAccount(rawOwner) ? ACCOUNT_LEGACY_ID : rawOwner;
      if (owner !== current) {
        task.status = 'failed';
        task.error = '已切换账号，请重新下载';
        task.message = '账号已切换';
        task.updatedAt = Date.now();
        changed = true;
      }
    }
    if (changed) {
      DownloadTaskService.saveTasks(tasks, true, true);
    }
  }

  private static pumpWorkers(): void {
    while (DownloadTaskService.activeTaskIds.size < DownloadTaskService.MAX_CONCURRENT_DOWNLOADS) {
      const taskId = DownloadTaskService.claimPendingTask();
      if (taskId.length === 0) {
        break;
      }
      DownloadTaskService.activeTaskIds.add(taskId);
      DownloadTaskService.runTask(taskId);
    }
  }

  private static claimPendingTask(): string {
    const tasks = DownloadTaskService.getTasks();
    const index = tasks.findIndex((task: DownloadTask) => task.status === 'pending');
    if (index < 0) {
      return '';
    }
    const taskId = tasks[index].id;
    const kind = tasks[index].kind ?? 'sonovel';
    tasks[index].status = 'downloading';
    tasks[index].error = '';
    tasks[index].progress = kind === 'talebook' ? -1 : (DownloadTaskService.useSseProgress() ? 0 : -1);
    tasks[index].message = kind === 'talebook' ? '正在从 Talebook 下载...' : '正在书源获取与转换...';
    tasks[index].updatedAt = Date.now();
    DownloadTaskService.saveTasks(tasks, true, true);
    return taskId;
  }

  private static async runTask(taskId: string): Promise<void> {
    let succeeded = false;
    try {
      const tasks = DownloadTaskService.getTasks();
      const task = tasks.find((item: DownloadTask) => item.id === taskId);
      if (task === undefined) {
        return;
      }
      const kind = task.kind ?? 'sonovel';
      if (kind === 'talebook') {
        await DownloadTaskService.runTalebookTask(taskId, task);
      } else {
        if (task.payload === undefined) {
          throw new Error('缺少 SoNovel 下载参数');
        }
        await SoNovelService.fetchBookWithProgress(task.payload, (progress: SoNovelDownloadProgress) => {
          DownloadTaskService.updateProgress(taskId, progress);
        }, DownloadTaskService.useSseProgress());
      }
      succeeded = true;
      DownloadTaskService.markCompleted(taskId);
    } catch (error) {
      DownloadTaskService.markFailed(taskId, ErrorFormat.message(error as Object));
    } finally {
      DownloadTaskService.ensureTaskSettled(taskId, succeeded);
      DownloadTaskService.activeTaskIds.delete(taskId);
      DownloadTaskService.pumpWorkers();
      DownloadTaskService.flushPersist();
      DownloadTaskService.notifyChanged();
    }
  }

  private static async runTalebookTask(taskId: string, task: DownloadTask): Promise<void> {
    const payload = task.talebookPayload;
    if (payload === undefined) {
      throw new Error('缺少 Talebook 下载参数');
    }
    const envelope = await TalebookService.downloadBookAsync(payload.bookId, payload.format, payload.destPath);
    if (!TalebookService.isApiSuccess(envelope)) {
      throw new Error(envelope.error.length > 0 ? envelope.error : '下载失败');
    }
    try {
      if (!fs.accessSync(payload.destPath)) {
        throw new Error('文件未写入');
      }
    } catch (_error) {
      throw new Error('文件未写入');
    }
    TalebookService.upsertDownloadRecord({
      bookId: `${payload.bookId}`,
      title: payload.bookName,
      author: payload.author,
      coverUrl: payload.cover,
      filePath: payload.destPath,
      format: payload.format,
      downloadTime: Date.now(),
    });
    const tasks = DownloadTaskService.getTasks();
    const index = tasks.findIndex((item: DownloadTask) => item.id === taskId);
    if (index >= 0) {
      tasks[index].filePath = payload.destPath;
      DownloadTaskService.saveTasks(tasks, false);
    }
  }

  private static recoverStaleTasks(): void {
    const now = Date.now();
    const tasks = DownloadTaskService.getTasks();
    let changed = false;
    for (let i = 0; i < tasks.length; i++) {
      const task = tasks[i];
      if (task.status !== 'downloading') {
        continue;
      }
      if (DownloadTaskService.activeTaskIds.has(task.id)) {
        continue;
      }
      tasks[i].status = 'pending';
      tasks[i].progress = 0;
      tasks[i].message = '等待中';
      tasks[i].error = '';
      tasks[i].updatedAt = now;
      changed = true;
    }
    if (changed) {
      DownloadTaskService.saveTasks(tasks, true, true);
    }
  }

  private static updateProgress(taskId: string, progress: SoNovelDownloadProgress): void {
    const tasks = DownloadTaskService.getTasks();
    const index = tasks.findIndex((task: DownloadTask) => task.id === taskId);
    if (index < 0 || tasks[index].status !== 'downloading') {
      return;
    }
    tasks[index].progress = progress.progress;
    tasks[index].message = progress.message;
    tasks[index].updatedAt = Date.now();
    DownloadTaskService.saveTasks(tasks, false);
    DownloadTaskService.scheduleProgressNotify();
  }

  private static markCompleted(taskId: string): void {
    DownloadTaskService.flushProgressNotify();
    const tasks = DownloadTaskService.getTasks();
    const index = tasks.findIndex((task: DownloadTask) => task.id === taskId);
    if (index < 0) {
      return;
    }
    tasks[index].status = 'completed';
    tasks[index].progress = 100;
    tasks[index].message = '下载完成';
    tasks[index].error = '';
    tasks[index].updatedAt = Date.now();
    DownloadTaskService.saveTasks(tasks, true, true);
  }

  private static markFailed(taskId: string, message: string): void {
    DownloadTaskService.flushProgressNotify();
    const tasks = DownloadTaskService.getTasks();
    const index = tasks.findIndex((task: DownloadTask) => task.id === taskId);
    if (index < 0) {
      return;
    }
    tasks[index].status = 'failed';
    tasks[index].error = message;
    tasks[index].message = '下载失败';
    tasks[index].updatedAt = Date.now();
    DownloadTaskService.saveTasks(tasks, true, true);
  }

  private static ensureTaskSettled(taskId: string, succeeded: boolean): void {
    const tasks = DownloadTaskService.getTasks();
    const index = tasks.findIndex((task: DownloadTask) => task.id === taskId);
    if (index < 0) {
      return;
    }
    if (tasks[index].status !== 'downloading') {
      return;
    }
    if (succeeded) {
      DownloadTaskService.markCompleted(taskId);
    } else {
      DownloadTaskService.markFailed(taskId, tasks[index].error.length > 0 ? tasks[index].error : '下载异常结束');
    }
  }

  private static buildSoNovelBookId(payload: SoNovelBookPayload): string {
    let hash = 0;
    const text = `${payload.sourceId}:${payload.url}`;
    for (let i = 0; i < text.length; i++) {
      hash = ((hash << 5) - hash + text.charCodeAt(i)) | 0;
    }
    return `sonovel_${payload.sourceId}_${Math.abs(hash)}`;
  }

  static kindLabel(kind: DownloadTaskKind): string {
    return kind === 'talebook' ? 'Talebook' : 'SoNovel';
  }

  static statusLabel(status: DownloadTaskStatus): string {
    if (status === 'pending') {
      return '等待中';
    }
    if (status === 'downloading') {
      return '下载中';
    }
    if (status === 'completed') {
      return '已完成';
    }
    return '失败';
  }
}
