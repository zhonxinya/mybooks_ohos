import { promptAction } from '@kit.ArkUI';
import { AccountManager, AccountSwitchOutcome } from '../services/AccountManager';
import { AccountStore } from '../services/AccountStore';
import { AccountRecord } from '../models/AccountModels';
import { ServerKind, ServerRegistry } from '../services/ServerProfile';

/**
 * 账号快速切换面板。
 *
 * 用法：宿主在根节点上挂 `bindSheet`，并把开关交给本组件托管：
 *
 *     @State showAccountPicker: boolean = false;
 *     ...
 *     .bindSheet($$this.showAccountPicker, this.accountPickerSheet(), { ... })
 *
 *     @Builder
 *     accountPickerSheet() {
 *       AccountPicker({ show: $showAccountPicker });
 *     }
 *
 * 开关放在宿主而不是组件内部，是因为 ArkUI 的 `bindSheet` 必须挂在构建节点上，
 * 无法从子组件内部打开宿主的 Sheet。
 *
 * 用 Sheet 而不是原生 ActionMenu：ActionMenu 条目多时会超出屏幕且不可滚动
 * （实测 2 个账号就已贴近屏幕底部），而账号数没有上限。
 */
@Component
export struct AccountPicker {
  @Link show: boolean;
  /** 切换进行中：防止连点。 */
  @State switching: boolean = false;

  /** 可快速切换的书库账号（排除 SoNovel，它不参与书库身份切换）。 */
  private candidates(): AccountRecord[] {
    return AccountManager.switchableAccounts();
  }

  private rowSubtitle(record: AccountRecord): string {
    const host: string = record.url.length > 0 ? record.url : '未设置地址';
    return `${record.serverKind === ServerKind.TALEBOOK ? 'Talebook' : 'MyBooks'} · ${host}`;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async switchTo(record: AccountRecord): Promise<void> {
    if (this.switching || AccountStore.isActive(record.id)) {
      return;
    }
    this.switching = true;
    const name: string = AccountManager.displayNameOf(record);
    this.toast(`正在切换到 ${name}…`);
    try {
      const outcome: AccountSwitchOutcome = await AccountManager.switchTo(record.id);
      if (!outcome.attempt.ok) {
        this.toast(`切换到 ${name} 失败：${outcome.attempt.reason}。可在「账号与服务器」中核对地址与密码`);
        return;
      }
      // 整栈重建：各页面 aboutToAppear 会读取新账号配置并重新拉取数据
      this.getUIContext().getRouter().clear();
      this.getUIContext().getRouter().replaceUrl({ url: 'pages/MainTabs' });
      this.toast(outcome.corrected
        ? `已切换到 ${name}（服务端类型识别为 ${ServerRegistry.profile().displayName}）`
        : `已切换到 ${name}`);
    } catch (error) {
      this.toast(`切换失败：${error}`);
    } finally {
      this.switching = false;
    }
  }

  build() {
    Scroll() {
      Column() {
        ForEach(this.candidates(), (record: AccountRecord, index: number) => {
          if (index > 0) {
            Divider().color($r('app.color.divider')).strokeWidth(0.5);
          }
          this.accountRow(record);
        }, (record: AccountRecord) => `switch-${record.id}-${AccountStore.isActive(record.id)}`);
      }
      .width('100%')
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));
    }
    .width('100%')
    .constraintSize({ maxHeight: 420 })
    .padding({ left: 16, right: 16, bottom: 8 });
  }

  @Builder
  accountRow(record: AccountRecord) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(AccountManager.displayNameOf(record))
            .fontSize(16)
            .fontColor($r('app.color.text_primary'));
          if (AccountStore.isActive(record.id)) {
            Text('当前')
              .fontSize(11)
              .fontColor($r('app.color.on_brand'))
              .backgroundColor($r('app.color.brand_primary'))
              .borderRadius($r('app.float.badge_radius'))
              .padding({ left: 6, right: 6, top: 1, bottom: 1 });
          }
        }
        .width('100%');
        Text(this.rowSubtitle(record))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      if (!AccountStore.isActive(record.id)) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([$r('app.color.text_tertiary')]);
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(() => {
      this.show = false;
      if (!AccountStore.isActive(record.id)) {
        void this.switchTo(record);
      }
    });
  }
}
