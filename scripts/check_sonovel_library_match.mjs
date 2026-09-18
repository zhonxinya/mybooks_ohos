#!/usr/bin/env node
/**
 * SoNovel 搜索结果「是否已入库」判定逻辑的离线自检（无需设备）。
 *
 * 为什么需要它：`utils/LibraryMatch.ets` 的判定口径（书名 + 作者都相同）只能在设备上
 * 通过真实搜索结果体现，改动后要么装机验证、要么完全没有把关。该模块刻意保持
 * 「纯计算、无 ArkUI/网络依赖」，因此可以用 Node 的类型擦除直接跑 **源文件**（不是副本）：
 * 只把它复制成 `.ts` 到临时目录，并把仅作类型的 `BookItem` 导入换成内联类型。
 *
 * 用法（Node ≥ 22.6，仓库里 harmony-sdk 自带的 node 即可）：
 *   node scripts/check_sonovel_library_match.mjs
 *
 * 校验项（任一失败即退出码 1）：归一化、作者比对、缺作者退化、多作者写法、
 * 同名不同作者不误判、空书名不误判。
 */
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..');
const SOURCE = join(REPO, 'ohos/entry/src/main/ets/utils/LibraryMatch.ets');

/** 用内联类型替掉对 BookModels 的值导入：Node 的类型擦除不会移除 import，加载真模块会失败。 */
const TYPE_STUB = `interface BookItem {
  id: number;
  title: string;
  authors: string[];
  coverUrl: string;
  rating: number;
  tags: string[];
}
`;

function stageModule() {
  const dir = mkdtempSync(join(tmpdir(), 'library-match-check-'));
  const src = readFileSync(SOURCE, 'utf8');
  const stripped = src.replace(/^import \{ BookItem \} from '\.\.\/services\/BookModels';\n/m, TYPE_STUB);
  if (stripped === src) {
    throw new Error('未能替换 BookItem 导入，检查 LibraryMatch.ets 的导入写法是否变化');
  }
  const file = join(dir, 'LibraryMatch.ts');
  writeFileSync(file, stripped);
  return { dir, file };
}

function book(title, authors) {
  return { id: 1, title, authors, coverUrl: '', rating: 0, tags: [] };
}

function main() {
  const staged = stageModule();
  let failures = 0;
  const check = (name, actual, expected) => {
    const ok = actual === expected;
    if (!ok) {
      failures++;
    }
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  (得到 ${actual}，期望 ${expected})`);
  };

  return import(pathToFileURL(staged.file).href).then((mod) => {
    const { normalizeName, authorTokens, hasSameBook } = mod;

    console.log('--- normalizeName ---');
    check('去空白与书名号', normalizeName(' 《金枝》 '), '金枝');
    check('全角空格也去掉', normalizeName('金\u3000枝'), '金枝');
    check('大小写归一', normalizeName('Pride And Prejudice'), 'prideandprejudice');

    console.log('--- authorTokens ---');
    check('顿号拆分', JSON.stringify(authorTokens('张三、李四')), JSON.stringify(['张三', '李四']));
    check('中英文逗号都拆', JSON.stringify(authorTokens('张三, 李四，王五')), JSON.stringify(['张三', '李四', '王五']));
    check('空串无词元', JSON.stringify(authorTokens('  ')), JSON.stringify([]));

    console.log('--- hasSameBook ---');
    const library = [book('金枝', ['詹姆斯·乔治·弗雷泽']), book('创新主义', ['梁建章'])];
    check('书名+作者都相同 → 已入库',
      hasSameBook(library, '金枝', '詹姆斯·乔治·弗雷泽'), true);
    check('同名但作者不同 → 不算入库',
      hasSameBook(library, '金枝', '另一个作者'), false);
    check('书库书名带书名号/空格也能命中',
      hasSameBook([book('《金枝》 ', ['詹姆斯·乔治·弗雷泽'])], '金枝', '詹姆斯·乔治·弗雷泽'), true);
    check('书源没有作者时只比书名',
      hasSameBook(library, '金枝', ''), true);
    check('书库缺作者时只比书名',
      hasSameBook([book('金枝', [])], '金枝', '任意作者'), true);
    check('多作者写法任意一个命中即算',
      hasSameBook([book('合著', ['张三、李四'])], '合著', '李四'), true);
    check('书名不同 → 不算入库',
      hasSameBook(library, '三体', '刘慈欣'), false);
    check('空书名 → 不算入库',
      hasSameBook(library, '', '詹姆斯·乔治·弗雷泽'), false);
    check('书库为空 → 不算入库',
      hasSameBook([], '金枝', '詹姆斯·乔治·弗雷泽'), false);

    rmSync(staged.dir, { recursive: true, force: true });
    console.log(failures === 0 ? '\n全部通过' : `\n${failures} 项失败`);
    process.exit(failures === 0 ? 0 : 1);
  });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
