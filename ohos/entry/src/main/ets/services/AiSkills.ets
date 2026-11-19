/**
 * AI 助手内置技能：把「怎么用工具问出好结果」固化成现成提示词模板。
 * 纯数据 + 纯函数，可离线回归；UI 只做展示与填入输入框（AiAssistantPage）。
 */

export interface AiSkill {
  /** chip / 卡片标题 */
  label: string;
  /** 一行说明：这个技能会做什么 */
  hint: string;
  /** 填入输入框的完整提示词（含工具使用指引） */
  prompt: string;
}

export const AI_SKILLS: AiSkill[] = [
  {
    label: '写书评',
    hint: '结构化的 Markdown 书评',
    prompt: '请为《》写一篇书评。先用 search_books 在书架确认这本书，再用 book_detail 取标签和简介作参考。' +
      '要求：Markdown 输出，含「一句话推荐理由」「三个亮点」「适合谁读」三节，300 字左右，语气真诚、不堆砌形容词。',
  },
  {
    label: '摘要这本书',
    hint: '先查真实数据，再概括',
    prompt: '请概括《》的核心内容。先 search_books 找到这本书，用 book_detail 获取官方简介，再结合你自己的知识概括；' +
      '书架上找不到就直说，不要编。输出：一句话主线 + 3~5 个要点。',
  },
  {
    label: '定阅读计划',
    hint: '基于你的真实阅读进度',
    prompt: '先用 reading_history 看我最近在读的书目和进度，再针对《》（如果我没填书名，就选我进度最慢的那本）' +
      '给出本周阅读计划：每天读多少、安排在什么时间，简短可执行。',
  },
  {
    label: '苏格拉底导读',
    hint: '用提问带你读进去',
    prompt: '请用苏格拉底式提问引导我读《》：先问一个开放性问题，等我回答后再追问，一次只问一个问题；' +
      '必要时用 book_notes 参考我已经写过的批注，把问题接在我的思考后面。',
  },
  {
    label: '找书并下载',
    hint: '搜书源→确认→下进本地书架',
    prompt: '帮我在书源里找《》：先用 search_sonovel 搜到候选（把书名/url/书源念给我核对），' +
      '我确认后用 add_sonovel_task 加入下载队列，之后用 list_download_tasks 向我汇报进度；' +
      '成品会自动进本地书架，完成后提醒我去读。',
  },
  {
    label: '建个书单',
    hint: '起名→搜书→逐本入单',
    prompt: '帮我建一个主题为「」的书单：先 create_booklist 创建，再用 search_books 找出 5 本候选并列出，' +
      '我挑选后用 add_books_to_booklist 加进去；每步写操作都做之前先征求我的确认。',
  },
];
