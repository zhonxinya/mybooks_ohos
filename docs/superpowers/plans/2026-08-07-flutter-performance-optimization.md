# Flutter Performance Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the unavailable Flureadium dependency and make the native EPUB reader predictable in memory use, background pagination, and WebView loading work.

**Architecture:** EPUB navigation remains in `NativeEpubReaderPage`; `EpubReaderController` exposes side-effect-free pagination for a specified chapter. A small, pure cache-window helper decides which chapter resources stay resident, so the UI owns WebView lifecycle while the controller owns pagination.

**Tech Stack:** Flutter OHOS SDK, Dart isolates, `webview_flutter`, Provider, `flutter_test`, Git submodules, `flutter analyze`, `flutter build hap`.

---

## Current State

- The working tree already contains uncommitted Flureadium removal edits and a bounded-concurrency Kavita loading change. Preserve these edits; do not reset or overwrite them.
- `flutter analyze` previously failed because `pubspec.yaml` referenced the missing local package `third_party/flureadium/flureadium`.
- The native reader already uses `EpubPaginationEngine` in an isolate, but it reloads WebView content from `build()` and preloads chapters by temporarily changing the active chapter.

### Task 1: Finish Flureadium Removal And Restore Dependency Resolution

**Files:**
- Modify: `pubspec.yaml`
- Modify: `pubspec.lock` (generated only)
- Modify: `lib/pages/reader/reader_page.dart`
- Modify: `lib/pages/reader/epub_reader_page.dart`
- Delete: `lib/pages/reader/flureadium_reader_page.dart`
- Modify: `ohos/entry/oh-package.json5`
- Modify: `ohos/oh-package.json5`
- Delete: Git submodule `third_party/flureadium`
- Delete: `docs/Flutter flureadium 接口规格说明.md`
- Delete: `docs/Flutter flureadium_platform_interface 接口规格说明.md`

- [ ] **Step 1: Confirm that both EPUB entry points use the native reader.**

```dart
import 'package:talebook/pages/reader/native_epub_reader_page.dart';

if (fmt == 'epub') {
  return NativeEpubReaderPage(
    filePath: widget.filePath,
    downloadUrl: widget.downloadUrl,
    bookId: widget.bookId,
    bookTitle: widget.bookTitle,
    location: widget.location,
  );
}
```

Run:

```powershell
rg -n -i "flureadium|Flureadium" lib pubspec.yaml ohos
```

Expected: no runtime, Flutter, or OHOS dependency reference remains.

- [ ] **Step 2: Regenerate the lockfile from the edited manifest.**

Run:

```powershell
flutter pub get
```

Expected: exit code `0`; `pubspec.lock` has no `flureadium` or `flureadium_platform_interface` package entry.

- [ ] **Step 3: Remove stale package specifications and the empty Git link.**

Run:

```powershell
git rm -f third_party/flureadium
rg -n -i "flureadium|Flureadium" docs pubspec.lock
```

Expected: no output after deleting the two obsolete interface specification documents listed above; repository documentation then matches the shipped dependency graph.

- [ ] **Step 4: Run static analysis before proceeding.**

Run:

```powershell
flutter analyze
```

Expected: exit code `0` with no error-level diagnostics.

- [ ] **Step 5: Commit the dependency cleanup independently.**

```powershell
git add pubspec.yaml pubspec.lock lib/pages/reader/reader_page.dart lib/pages/reader/epub_reader_page.dart lib/pages/reader/flureadium_reader_page.dart ohos/entry/oh-package.json5 ohos/oh-package.json5 docs
git add -u third_party/flureadium
git commit -m "refactor(reader): remove flureadium dependency"
```

### Task 2: Add A Tested Chapter Cache Window

**Files:**
- Create: `lib/services/epub/chapter_cache_window.dart`
- Create: `test/services/epub/chapter_cache_window_test.dart`
- Modify: `pubspec.yaml` (add `flutter_test` from the Flutter SDK if it is not already declared)

- [ ] **Step 1: Write the failing boundary tests.**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:talebook/services/epub/chapter_cache_window.dart';

void main() {
  const window = ChapterCacheWindow(radius: 1);

  test('keeps the active chapter and one neighbor on each side', () {
    expect(
      window.retainedIndices(currentIndex: 3, chapterCount: 8),
      {2, 3, 4},
    );
  });

  test('clamps the cache window at the first chapter', () {
    expect(window.retainedIndices(currentIndex: 0, chapterCount: 8), {0, 1});
  });

  test('clamps the cache window at the final chapter', () {
    expect(window.retainedIndices(currentIndex: 7, chapterCount: 8), {6, 7});
  });
}
```

- [ ] **Step 2: Run the test and confirm the expected missing-import failure.**

Run:

```powershell
flutter test test/services/epub/chapter_cache_window_test.dart
```

Expected: fail because `ChapterCacheWindow` does not exist yet.

- [ ] **Step 3: Implement the pure cache-window contract.**

```dart
class ChapterCacheWindow {
  final int radius;

  const ChapterCacheWindow({this.radius = 1}) : assert(radius >= 0);

  Set<int> retainedIndices({
    required int currentIndex,
    required int chapterCount,
  }) {
    if (chapterCount <= 0) return {};
    final first = currentIndex > radius ? currentIndex - radius : 0;
    final candidateLast = currentIndex + radius;
    final last = candidateLast < chapterCount ? candidateLast : chapterCount - 1;
    return {for (var index = first; index <= last; index++) index};
  }
}
```

- [ ] **Step 4: Run the unit test and analyzer.**

Run:

```powershell
flutter test test/services/epub/chapter_cache_window_test.dart
flutter analyze
```

Expected: both commands exit `0`.

- [ ] **Step 5: Commit the isolated cache policy.**

```powershell
git add pubspec.yaml lib/services/epub/chapter_cache_window.dart test/services/epub/chapter_cache_window_test.dart
git commit -m "feat(reader): add bounded chapter cache window"
```

### Task 3: Make Native EPUB Preloading Side-Effect Free

**Files:**
- Modify: `lib/services/epub/epub_reader_controller.dart`
- Modify: `lib/pages/reader/native_epub_reader_page.dart`
- Create: `test/services/epub/epub_reader_controller_test.dart`

- [ ] **Step 1: Write a failing controller test for off-screen pagination.**

Create `test/services/epub/epub_reader_controller_test.dart` with this complete fixture and expectation:

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:talebook/models/reader/epub_models.dart';
import 'package:talebook/services/epub/epub_reader_controller.dart';

void main() {
  final document = EpubDocument(
    metadata: const EpubMetadata(title: 'Test EPUB'),
    manifest: const {
      'first': EpubManifestItem(
        id: 'first',
        href: 'first.xhtml',
        mediaType: 'application/xhtml+xml',
      ),
      'second': EpubManifestItem(
        id: 'second',
        href: 'second.xhtml',
        mediaType: 'application/xhtml+xml',
      ),
    },
    spine: const ['first', 'second'],
    toc: const [],
    content: {
      'first.xhtml': Uint8List.fromList(utf8.encode('<html><body>First</body></html>')),
      'second.xhtml': Uint8List.fromList(utf8.encode('<html><body>Second</body></html>')),
    },
  );

  test('off-screen pagination leaves the active chapter unchanged', () async {
    final controller = EpubReaderController(document: document);

    final pages = await controller.paginateChapterAt(
      chapterIndex: 1,
      viewportWidth: 400,
      viewportHeight: 800,
      fontSize: 16,
      lineHeight: 1.5,
    );

    expect(pages, isNotEmpty);
    expect(controller.currentChapterIndex.value, 0);
  });
}
```

The test must not call `jumpToChapter`; its result proves the preload API is independent from reader navigation.

- [ ] **Step 2: Run the test and confirm it fails because the API is absent.**

Run:

```powershell
flutter test test/services/epub/epub_reader_controller_test.dart
```

Expected: compile failure for missing `paginateChapterAt`.

- [ ] **Step 3: Add the pagination API without changing reader state.**

Refactor the isolate call into a helper accepting HTML and pagination parameters. `paginateChapterAt` must derive HTML from `document` and the specified chapter index, then return the result without assigning `currentChapterIndex`, `currentPageIndex`, `_cachedPageHtml`, or `_totalPagesInChapter`.

```dart
Future<List<String>> paginateChapterAt({
  required int chapterIndex,
  required double viewportWidth,
  required double viewportHeight,
  required double fontSize,
  required double lineHeight,
  double letterSpacing = 0,
}) {
  final html = _renderedHtmlForChapter(chapterIndex);
  return _paginateHtml(
    html: html,
    viewportWidth: viewportWidth,
    viewportHeight: viewportHeight,
    fontSize: fontSize,
    lineHeight: lineHeight,
    letterSpacing: letterSpacing,
  );
}
```

Implement `_renderedHtmlForChapter` with the same cache used by `currentChapterHtml` and implement `_paginateHtml` as the existing `Isolate.run` call:

```dart
String _renderedHtmlForChapter(int chapterIndex) {
  if (chapterIndex < 0 || chapterIndex >= document.spine.length) {
    throw RangeError.index(chapterIndex, document.spine, 'chapterIndex');
  }
  final cached = _renderedHtmlCache[chapterIndex];
  if (cached != null) return cached;
  final href = document.getSpineHref(chapterIndex)!;
  final html = _buildRenderedHtml(
    _parser.getChapterHtml(document, chapterIndex),
    href,
  );
  _renderedHtmlCache[chapterIndex] = html;
  return html;
}

Future<List<String>> _paginateHtml({
  required String html,
  required double viewportWidth,
  required double viewportHeight,
  required double fontSize,
  required double lineHeight,
  required double letterSpacing,
}) {
  return Isolate.run(() => EpubPaginationEngine.splitIntoPages(
        html: html,
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
        fontSize: fontSize,
        lineHeight: lineHeight,
        letterSpacing: letterSpacing,
      ));
}
```

- [ ] **Step 4: Replace `_preloadChapterAsync` chapter hopping.**

In `NativeEpubReaderPage`, replace the `jumpToChapter(targetIndex)` and restore sequence with `paginateChapterAt(chapterIndex: targetIndex, ...)`. Keep writes to `_pageHtmlPaths[targetIndex]`; do not call `_recordProgress`, mutate a `ValueNotifier`, or invoke `setState` from the background preload path.

- [ ] **Step 5: Verify behavior and commit.**

Run:

```powershell
flutter test test/services/epub/epub_reader_controller_test.dart
flutter analyze
```

Expected: test and analysis exit `0`.

```powershell
git add lib/services/epub/epub_reader_controller.dart lib/pages/reader/native_epub_reader_page.dart test/services/epub/epub_reader_controller_test.dart
git commit -m "fix(reader): preload EPUB chapters without navigation"
```

### Task 4: Bound WebView And Chapter Resource Lifetime

**Files:**
- Modify: `lib/pages/reader/native_epub_reader_page.dart`
- Modify: `lib/services/epub/chapter_cache_window.dart`
- Test: `test/services/epub/chapter_cache_window_test.dart`

- [ ] **Step 1: Use the cache window when a chapter becomes active.**

Add the following fields to the page state:

```dart
static const _chapterCacheWindow = ChapterCacheWindow(radius: 1);
final Set<String> _loadedHtmlPaths = <String>{};
```

Call `_evictChapterResources(activeChapterIndex)` from `_onChapterChanged` after scheduling the active chapter preload. The retained indexes must come from `_chapterCacheWindow.retainedIndices(currentIndex: activeChapterIndex, chapterCount: _document!.spine.length)`.

- [ ] **Step 2: Load WebView content only when a controller is created.**

Change `_getPageController` to receive `htmlPath`. Create and configure a `WebViewController` once per `(chapterIndex, pageIndex)` key, then call `loadFile(htmlPath)` only when `_loadedHtmlPaths.add(htmlPath)` returns `true`. Remove `controller.loadFile(htmlPath)` from the `PageView.builder` body.

- [ ] **Step 3: Evict resources outside the active window.**

For each chapter index absent from the retained set:

```dart
_pageControllers.remove(chapterIndex);
_pageHtmlPaths.remove(chapterIndex);
_loadedHtmlPaths.removeWhere((path) => path.contains('${Platform.pathSeparator}chapter_$chapterIndex${Platform.pathSeparator}'));
```

Delete only the matching `chapter_<index>` directory below `_cacheDirPath`, after confirming its resolved path begins with the EPUB cache directory path. Do not delete the current, preceding, or next chapter directory.

- [ ] **Step 4: Extend cache-window tests and validate.**

Add a `radius: 2` assertion for `currentIndex: 3, chapterCount: 8` returning `{1, 2, 3, 4, 5}`. Then run:

```powershell
flutter test test/services/epub/chapter_cache_window_test.dart
flutter analyze
```

Expected: both commands exit `0`.

- [ ] **Step 5: Commit the lifecycle optimization.**

```powershell
git add lib/pages/reader/native_epub_reader_page.dart lib/services/epub/chapter_cache_window.dart test/services/epub/chapter_cache_window_test.dart
git commit -m "perf(reader): bound EPUB WebView cache"
```

### Task 5: Verify Kavita Bounded-Concurrency Loading

**Files:**
- Modify: `lib/pages/kavita/kavita_series_list_body.dart`
- Create: `lib/utils/bounded_concurrent_loader.dart`
- Create: `test/utils/bounded_concurrent_loader_test.dart`

- [ ] **Step 1: Extract the batching loop into an injected loader.**

Create this reusable helper:

```dart
Future<List<R>> loadSuccessfulInBatches<T, R extends Object>(
  Iterable<T> items,
  Future<R?> Function(T item) load, {
  required int concurrency,
}) async {
  if (concurrency < 1) {
    throw ArgumentError.value(concurrency, 'concurrency', 'must be positive');
  }

  final input = items.toList(growable: false);
  final results = <R>[];
  for (var start = 0; start < input.length; start += concurrency) {
    final end = start + concurrency < input.length
        ? start + concurrency
        : input.length;
    final batch = await Future.wait(input.sublist(start, end).map(load));
    results.addAll(batch.whereType<R>());
  }
  return results;
}
```

In `KavitaSeriesListBody`, pass each `KavitaLibrary` to a loader that returns `null` after handling a per-library request error. Flatten the returned `List<List<KavitaSeries>>` in order.

- [ ] **Step 2: Write a failing concurrency test.**

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:talebook/utils/bounded_concurrent_loader.dart';

void main() {
  test('starts the next batch only after the current batch completes', () async {
    final first = Completer<String?>();
    final second = Completer<String?>();
    final third = Completer<String?>();
    final fourth = Completer<String?>();
    final completers = {'one': first, 'two': second, 'three': third, 'four': fourth};
    var started = 0;

    final result = loadSuccessfulInBatches<String, String>(
      ['one', 'two', 'three', 'four'],
      (item) {
        started++;
        return completers[item]!.future;
      },
      concurrency: 3,
    );

    expect(started, 3);
    first.complete('one');
    await Future<void>.delayed(Duration.zero);
    expect(started, 4);
    second.complete('two');
    third.complete('three');
    fourth.complete('four');
    expect(await result, ['one', 'two', 'three', 'four']);
  });
}
```

- [ ] **Step 3: Run the test, implement the extracted function, and rerun it.**

Run:

```powershell
flutter test test/utils/bounded_concurrent_loader_test.dart
flutter analyze
```

Expected: the test fails before extraction, then both commands exit `0` after the implementation.

- [ ] **Step 4: Commit the verified network optimization.**

```powershell
git add lib/pages/kavita/kavita_series_list_body.dart lib/utils/bounded_concurrent_loader.dart test/utils/bounded_concurrent_loader_test.dart
git commit -m "perf(kavita): bound library series requests"
```

### Task 6: Build And Profile On HarmonyOS

**Files:**
- Modify: no source file unless diagnostics expose a defect

- [ ] **Step 1: Run the full validation suite.**

Run:

```powershell
flutter test
flutter analyze
flutter build hap
```

Expected: all commands exit `0`.

- [ ] **Step 2: Perform reader acceptance checks on a device.**

Open a large local EPUB, change chapters five times, change font size and theme, return to the bookshelf, then reopen the same EPUB. Confirm the reader position persists, no visible chapter jump occurs during preload, and the process memory stabilizes after navigating beyond three chapters.

- [ ] **Step 3: Capture a DevTools trace.**

Record a 20-second trace while turning pages and opening the control panel. Confirm that page turns do not repeatedly invoke WebView file loads, no build frame exceeds 16 ms during idle navigation, and raster frames do not show recurring off-screen layers from the reader surface.

- [ ] **Step 4: Record diagnostics without changing source.**

Store the DevTools trace outside the repository and attach its capture time, device model, and Flutter SDK version to the pull request or release note. Do not create a commit when the acceptance checks require no source change.

## Plan Review

- Dependency resolution is restored before Flutter code verification.
- Reader cache behavior has a pure unit-tested boundary contract.
- Background pagination has an explicit regression test proving it cannot navigate the active reader.
- WebView resource retention is bounded to the active chapter and one neighbor on each side.
- Kavita loading keeps bounded concurrency and gains a regression test.
- Full static analysis, test execution, HarmonyOS packaging, and device profiling are mandatory before integration.
