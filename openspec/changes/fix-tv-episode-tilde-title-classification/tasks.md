## 1. 修复文件名标题清洗

- [x] 1.1 在 `entry/src/main/ets/lib/ScrapeClient.ets` 的 `parseFileName`，将 title 清洗 `.replace(/[._-]/g, ' ')` 扩展为 `.replace(/[._~-]/g, ' ')`，并在质量匹配前归一化分隔符（`. _ ~ -` 均视为空格），确保 `01_4K.mp4` 也能截断质量标签。验证：模拟 `parseFileName('01~4K.mp4')` 返回 `title='01'`，`parseFileName('01_4K.mp4')` 返回 `title='01'`，`parseFileName('Breaking.Bad.S01E01.1080p.mkv')` 返回 `seasonNumber=1`、`episodeNumber=1`、`mediaType='tv'`。

## 2. 补充测试

- [x] 2.1 在 `entry/src/test/ScrapeClient.test.ets` 补充 `parseFileName('01~4K.mp4')` → `title='01'`、`mediaType='movie'` 的用例。
- [x] 2.2 在 `entry/src/test/VideoScannerUtil.test.ets` 补充 `classifyVideoScrapeTarget('01~4K.mp4', '/Videos/TV Series/重器/01~4K.mp4', ctx)` → `mediaType='tv'` 的用例（验证不再为 unknown/movie）。
- [x] 2.3 补充标准 `SxxExx` 文件名不受 `~` 改动影响的回归用例。验证：新建用例随 `UnitTestBuild` 编译通过。

## 3. 收尾验证

- [x] 3.1 运行 `openspec validate --changes`，确认包含新变更 `fix-tv-episode-tilde-title-classification` 校验通过。
- [x] 3.2 当前 worktree `assembleHap` + `UnitTestBuild` 通过；可重新安装到电视验证 `01~4K.mp4` 完整进入季详情页。
