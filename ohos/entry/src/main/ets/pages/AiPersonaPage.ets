import { promptAction } from '@kit.ArkUI';
import { PageScaffold, PrimaryButton, SecondaryButton, SectionTitle } from '../components';
import { AiPersona } from '../services/AiPersona';

/**
 * 灵魂与记忆管理页（OpenClaw 式）：
 * - 灵魂 = SOUL.md 人格文件，TextArea 直接编辑；
 * - 记忆 = MEMORY.md 条目列表，可逐条删除、可手动补记。
 * 两者在每次对话构建时注入 system prompt（见 AiAssistantPage.buildContext）。
 */
@Entry
@Component
struct AiPersonaPage {
  @State soul: string = '';
  @State memories: string[] = [];
  @State newMemory: string = '';

  aboutToAppear(): void {
    this.soul = AiPersona.loadSoul();
    this.memories = AiPersona.loadMemories();
  }

  private onSaveSoul(): void {
    AiPersona.saveSoul(this.soul);
    try {
      promptAction.showToast({ message: '灵魂已保存，下次对话生效' });
    } catch (_error) {
    }
  }

  private onResetSoul(): void {
    this.soul = AiPersona.resetSoul();
    try {
      promptAction.showToast({ message: '已恢复默认灵魂' });
    } catch (_error) {
    }
  }

  private onAddMemory(): void {
    const text: string = this.newMemory.trim();
    if (text.length === 0) {
      return;
    }
    const result: string = AiPersona.appendMemory(text);
    this.memories = AiPersona.loadMemories();
    this.newMemory = '';
    try {
      promptAction.showToast({ message: result });
    } catch (_error) {
    }
  }

  private onRemoveMemory(index: number): void {
    const result: string = AiPersona.removeMemory(index + 1);
    this.memories = AiPersona.loadMemories();
    try {
      promptAction.showToast({ message: result });
    } catch (_error) {
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '灵魂与记忆',
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
    Scroll() {
      Column({ space: 16 }) {
        SectionTitle({ title: '灵魂（人格设定）' });
        Text('AI 助手的性格与原则，将作为最高优先级人格注入每次对话。')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
        TextArea({ text: this.soul, placeholder: '描述 AI 应有的性格、语气、原则…' })
          .height(260)
          .fontSize(14)
          .onChange((v: string) => {
            this.soul = v;
          });
        Row({ space: 12 }) {
          PrimaryButton({ label: '保存灵魂', onTap: () => this.onSaveSoul() });
          SecondaryButton({ label: '恢复默认', onTap: () => this.onResetSoul() });
        }
        .width('100%');

        SectionTitle({ title: '记忆（跨对话）' });
        Text('AI 会通过 save_memory 记住你的偏好与约定；也可在这里手动补记或删除。')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
        if (this.memories.length === 0) {
          Text('还没有记忆。试试对 AI 助手说「记住我喜欢刘慈欣的长篇」。')
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .padding({ top: 8, bottom: 8 });
        } else {
          ForEach(this.memories, (item: string, index: number) => {
            Row({ space: 8 }) {
              Text(`${index + 1}. ${item}`)
                .fontSize(14)
                .layoutWeight(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .maxLines(3);
              Text('删除')
                .fontSize(13)
                .fontColor($r('app.color.error'))
                .onClick(() => this.onRemoveMemory(index));
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 });
          }, (item: string, index: number) => `${index}-${item}`);
        }
        Row({ space: 12 }) {
          TextInput({ text: this.newMemory, placeholder: '手动补一条记忆' })
            .layoutWeight(1)
            .onChange((v: string) => {
              this.newMemory = v;
            });
          SecondaryButton({
            label: '添加',
            fullWidth: false,
            compact: true,
            onTap: () => this.onAddMemory(),
          });
        }
        .width('100%');
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 24 });
    }
    .scrollBar(BarState.Auto)
    .align(Alignment.Top)
    .width('100%')
    .height('100%');
  }
}
