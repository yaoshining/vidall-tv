# Search lifecycle and TV regression checks

`SearchWorkspacePage` and `MediaResultPage` use `SearchSession<T>` for request
ownership. The loader is a `() => Promise<T[]>` and contains all provider-specific
work. The current pages query `FileSourceDatabase`; there is no server-search or
source-picker integration in these pages yet. A future provider switch must call
`prepare(true)` immediately, before starting or debouncing the new loader, to
remove results belonging to the previous source.

## State transitions

- Empty input / clear: `invalidate(true)` → `idle`, clearing results and timers.
- Input intent: `prepare()` immediately increments the generation, then the
  workspace debounces for 800 ms. History selection and retry cancel that timer
  and execute immediately.
- Request: `loading`, or `refreshing` while previous results remain visible.
- Accepted success: `results` or `empty`; only accepted responses reload the grid.
- Failure / 15-second timeout: `error`, with a generic visible message and a
  focusable retry button. Provider exception text is never displayed. A timeout
  invalidates the response; it does not cancel the underlying provider operation.
- Navigation hide / disappearance / back: invalidate and cancel pending debounce.
  Returning resumes a search interrupted by navigation, and restores the selected
  result when returning from details.

Results use fixed-height, six-column `Grid` + `LazyForEach`, with two cached rows,
so offscreen posters are not all built at once. The existing 200-row query cap
remains; this change does not add database pagination. The workspace exposes
“浏览结果” and “返回输入”; Up from the first row returns to input. Back from a
focused workspace result first returns to input; Back again leaves the page.
Result IDs are based on media IDs. The filtered result page restores the selected
card and sends Up from the first row to the filter reset control.

## Automated validation

`entry/src/test/SearchSession.test.ets` is registered in `List.test.ets`. It covers
intent-time invalidation, clear/source replacement/leave, late failures,
refresh/error/empty/retry, and timeout followed by a late success.

The same tests can run on the host:

```sh
TYPESCRIPT_PATH=/path/to/typescript/lib/typescript.js node scripts/tests/search-session.cjs
```

The host runner removes only ArkUI observation decorators and supplies Hypium
assertions. It verifies the actual lifecycle logic, not ArkUI reactivity or focus.
Run `devecocli build` for ArkTS compilation and `devecocli run --device <TV>` for
runtime checks.

## Device acceptance checklist

- Rapidly type multiple queries, clear during a request, leave, and re-enter;
  no old results may reappear.
- Open a result, return, and verify the same card remains focused and visible.
- Browse 200 results using D-pad; verify Up/Back escape routes and visible focus.
- Inject provider rejection and a response delayed beyond 15 seconds; verify
  generic error, retained previous results, and remote-control retry.
- Repeat the lifecycle suite with a server loader when server search is wired in.
- Measure first display and long-list scrolling on the target physical TV;
  emulator startup and host tests do not establish device performance.

Physical-TV performance, server integration, and human review remain release
acceptance steps; no numerical performance claim is made by these tests.
