import { router } from '@kit.ArkUI';
import {
  PageScaffold, PrimaryButton, SecondaryButton, SettingCell, LoadingState
} from '../components';
import {
  TalebookApi, apiErrorMessage, ToolboxDataResponse, BookBarnApplyTokenResponse
} from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';

@Entry
@Component
struct BookbarnAcceptorToolPage {
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;

  @State enableBookbarn: boolean = false;
  @State enableReceiving: boolean = false;
  @State token: string = '';
  @State collectionHour: number = 3;
  @State hourText: string = '3';
  @State statusHint: string = '';

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
      await this.loadStatus();
    } finally {
      this.loading = false;
    }
  }

  private applyStatusData(data: Record<string, Object> | undefined): void {
    if (data === undefined) {
      return;
    }
    this.enableBookbarn = Boolean(data['enable_bookbarn']);
    this.enableReceiving = Boolean(data['enable_receiving_books']);
    this.token = String(data['token'] ?? '');
    const hour = Number(data['collection_hour'] ?? 3);
    this.collectionHour = (hour >= 0 && hour <= 23) ? hour : 3;
    this.hourText = `${this.collectionHour}`;
    const bits: string[] = [];
    bits.push(this.enableBookbarn ? 'BookBarn 已启用' : 'BookBarn 未启用');
    bits.push(this.enableReceiving ? '正在接收推送' : '接收已关闭');
    bits.push(`收取小时 ${this.collectionHour}`);
    this.statusHint = bits.join(' · ');
  }

  private async loadStatus(): Promise<void> {
    try {
      const rsp: ToolboxDataResponse = await TalebookApi.bookbarnAcceptorStatus();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '获取状态失败', true);
        return;
      }
      this.applyStatusData(rsp.data);
      this.setMsg(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '状态已刷新', false);
    } catch (e) {
      this.setMsg(`${e}`, true);
    }
  }

  private async toggleReceiving(enabled: boolean): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const rsp: ToolboxDataResponse = await TalebookApi.bookbarnAcceptorToggle(enabled);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '切换失败', true);
        // 回滚开关显示
        this.enableReceiving = !enabled;
        return;
      }
      if (rsp.data !== undefined) {
        this.applyStatusData(rsp.data);
      } else {
        this.enableReceiving = enabled;
      }
      this.setMsg(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg :
        (enabled ? '已开启接收' : '已关闭接收'), false);
      this.toast(this.message);
    } catch (e) {
      this.enableReceiving = !enabled;
      this.setMsg(`${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  private async applyToken(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const rsp: BookBarnApplyTokenResponse = await TalebookApi.bookbarnAcceptorApplyToken();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '申请 Token 失败', true);
        return;
      }
      if (rsp.token !== undefined && rsp.token.length > 0) {
        this.token = rsp.token;
      }
      this.setMsg(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : 'Token 已更新', false);
      this.toast(this.message);
      await this.loadStatus();
    } catch (e) {
      this.setMsg(`${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  private async saveHour(): Promise<void> {
    if (this.busy) {
      return;
    }
    const hour = Number(this.hourText.trim());
    if (!(hour >= 0 && hour <= 23) || hour !== Math.floor(hour)) {
      this.setMsg('收取小时需为 0–23 的整数', true);
      return;
    }
    this.busy = true;
    try {
      const rsp: ToolboxDataResponse = await TalebookApi.bookbarnAcceptorSetCollectionHour(hour);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '设置失败', true);
        return;
      }
      if (rsp.data !== undefined) {
        this.applyStatusData(rsp.data);
      } else {
        this.collectionHour = hour;
      }
      this.setMsg(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : `已设置收取小时为 ${hour}`, false);
      this.toast(this.message);
    } catch (e) {
      this.setMsg(`${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  private maskToken(token: string): string {
    if (token.length === 0) {
      return '（无）';
    }
    if (token.length <= 8) {
      return '********';
    }
    return `${token.substring(0, 4)}…${token.substring(token.length - 4)}`;
  }

  build() {
    Column() {
      PageScaffold({
        title: 'BookBarn 接收',
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
          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(13)
              .fontColor(this.isError ? $r('app.color.error') : $r('app.color.success'))
              .width('100%');
          }
          if (this.statusHint.length > 0) {
            Text(this.statusHint)
              .fontSize(13)
              .fontColor($r('app.color.brand_primary'))
              .width('100%');
          }

          Column() {
            SettingCell({
              title: 'BookBarn 总开关',
              subtitle: this.enableBookbarn ? '站点已启用 BookBarn' : '站点未启用 BookBarn（只读）',
              showToggle: true,
              toggleOn: this.enableBookbarn,
              onToggle: (_v: boolean) => {
                this.toast('总开关由站点配置控制，请在服务端设置 ENABLE_BOOKBARN');
                // 保持显示与服务器一致
                void this.loadStatus();
              },
            });
            SettingCell({
              title: '接收推送书籍',
              subtitle: this.enableReceiving ? '当前接受 BookBarn 推送' : '已停止接收',
              showToggle: true,
              toggleOn: this.enableReceiving,
              onToggle: (v: boolean) => {
                this.enableReceiving = v;
                void this.toggleReceiving(v);
              },
            });
            SettingCell({
              title: '当前 Token',
              subtitle: this.maskToken(this.token),
              showChevron: true,
              onTap: () => {
                if (this.token.length > 0) {
                  this.toast(this.token);
                } else {
                  this.toast('暂无 Token');
                }
              },
            });
          }
          .width('100%')
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          Column({ space: 10 }) {
            Text('每日收取小时（0–23，服务器本地时区）')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%');
            TextInput({ placeholder: '收取小时', text: this.hourText })
              .height(40)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((v: string) => {
                this.hourText = v;
              });
            SecondaryButton({
              label: this.busy ? '保存中…' : '保存收取小时',
              buttonEnabled: !this.busy,
              onTap: () => {
                void this.saveHour();
              },
            });
          }
          .width('100%')
          .padding(12)
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          PrimaryButton({
            label: this.busy ? '处理中…' : '申请 / 刷新 Token',
            buttonEnabled: !this.busy,
            onTap: () => {
              void this.applyToken();
            },
          });
          SecondaryButton({
            label: '刷新状态',
            buttonEnabled: !this.busy,
            onTap: () => {
              void this.loadStatus();
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
