import { common, Want } from '@kit.AbilityKit';
import { ChipButton } from './ChipButton';

export interface FriendLink {
  text: string;
  href: string;
}

@Component
export struct FriendsLinksRow {
  links: FriendLink[] = [];

  private openLink(href: string): void {
    if (href.length === 0) {
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: href,
    };
    context.startAbility(want).catch(() => {
    });
  }

  build() {
    if (this.links.length === 0) {
      Column();
    } else {
      Column({ space: 8 }) {
        Text('友情链接')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .padding({ left: 16, right: 16 });

        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.links, (link: FriendLink) => {
              ChipButton({
                label: link.text.length > 0 ? link.text : link.href,
                onTap: () => this.openLink(link.href),
              });
            }, (link: FriendLink) => `${link.text}-${link.href}`);
          }
          .padding({ left: 16, right: 16, bottom: 16 });
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%');
      }
      .width('100%');
    }
  }
}
