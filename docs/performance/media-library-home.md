# 本地媒体库首页限量查询验证

## 基线与范围

从最新 main `b57ad6d7fbc588d38229fb5f9d48250a88170755` 创建 `codex/media-library-home-queries`。
该提交为 PR #334 的合并提交；已用 `git merge-base --is-ancestor` 确认同时包含
PR #333 合并提交 `db82e689c001dc9f36d654fd51a7187c49d209ec`。
不修改布局、播放器、凭据加密、文件浏览器；不自动合并。

## 消费者核对与接口语义

| 消费者 | 调整与保留行为 |
| --- | --- |
| MediaLibraryTab | 最近添加20、电影30、电视剧30、未观看20由DAO返回；移除页面重复slice。电影栏标题单独使用全库电影文件计数。空态使用全库stats.total，保持仅含未刮削文件的旧行为。 |
| MediaLibraryModel.loadContinueWatching | 原recentlyAdded全库Map改为最多20个原候选按键查询；仍先取20条进度再按剧去重，缺失媒体不递补，未开始下一集与旧剧级key规则不变。保留全量进度读取以维护其他文件源卡片使用的movieProgressMap。重复媒体保留最早扫描文件，同扫描时间按原Map最后覆盖的较大videoId选择。 |
| PlayHistoryPage | 仍调用默认无限量getAllMediaItems。 |
| MediaResultPage / SearchWorkspacePage | 仍直接使用searchMediaItems，保留既有默认50、选项上限500/调用方200及原搜索去重行为；未被首页窗口截断。 |
| 电影、剧集详情与年份完整列表 | getMediaItemByVideoId、getMediaItemsByTvSeriesId、getMediaItemsByYear均保持原语义。 |
| 模型的recentlyAdded/unwatched/byRating | 全仓搜索确认除首页空态/诊断和继续观看外无消费者；移除这些全量缓存。 |

评分区间仍为[5,6)、[6,7)、[7,8)、[8,9)、[9,10)，10分不进入9分档；同剧每集各计一次。
顶部电影/电视剧数量仍为去重实体数，电影栏标题仍按media_type=movie文件数。
年代仍以全库去重年份生成；年代count代表年份数量，不擅自改成视频数。
最近添加沿用每季/电影各取20后稳定合并排序取20的有界算法（同时间剧季优先）；剧集栏先分组再LIMIT30。

未观看新增查询在SQL中按原评分、标题、实体ID、videoId排序选代表，按剧/电影去重后取20，保留原展示有效性过滤，再在模型中按scannedAt重排。
**唯一有意差异**：旧搜索先取200个文件，多于200集的高分剧可能挤掉所有其他影片。首页新查询对全库轻量候选先去重再限20；250集+40电影样例由旧版1项变成20项。共享搜索接口本身未改变。此边界修复遵循“截断在正确分组之后”的要求。

## 失败与竞态

保留#334的loadVersion、continueWatchingVersion，每个新增await后检查版本。
主库全部查询结果就绪后同步提交；任何查询失败保留旧快照，过期失败不改loading或输出过期错误。
为首页使用的年代、统计、剧集、最近添加和扫描时间读取添加默认false的错误透传参数，首页显式启用；其余消费者默认错误行为不变。
移除诊断性全库filter/sample、年份的两次诊断计数查询、未刮削文件列表诊断查询；保留错误日志和主库加载耗时日志。
继续观看的元数据查询失败保留旧列表与电影进度映射。
这里的“完整快照”指一次模型加载的同步提交，未新增数据库跨查询事务。

## 主机性能测量

环境：Apple M1 Max、Darwin 25.6.0、arm64、Node v26.4.0、SQLite 3.53.3，内存数据库。
生产建表SQL与既有idx_scrape_info_tvs_ep索引由夹具读取/复用；没有为基准额外添加优化索引。
执行真实ArkTS DAO转译代码、真实SQL和MediaItem解析器；旧版代码直接由git读取上述#334提交。
搜索拼音转换依赖使用主机替身；此处性能测量搜索词为空，定向搜索回归使用精确汉字标题，不覆盖拼音效果。

数据固定：40%电影、50%剧集、10%未刮削；每剧20集/两季；13种循环评分含空值及所有边界，固定扫描时间和刮削时间；进度表为空。
数据生成和转译不计时。每组先交替预热2轮，再交替顺序测7轮；每次前显式GC。
查询耗时包括SQLite prepare/execute/all返回行的主机开销；DAO耗时另含解析、旧诊断遍历、评分分档和结果整理，不包括布局/渲染、继续观看异步阶段与磁盘冷启动。
两版均关闭console输出，但旧诊断SQL和数据遍历仍执行。每轮比较最终可见结果，全部一致。

| 视频数 | SQL查询耗时中位数（前→后） | DAO耗时中位数（前→后） | MediaItem创建数（前→后） | SQL返回总行数（前→后） | 查询数（前→后） |
| --- | --- | --- | --- | --- | --- |
| 1,000 | 10.62 → 5.09 ms | 14.21 → 5.41 ms | 2,490 → 70 | 2,719 → 198 | 16 → 12 |
| 10,000 | 95.54 → 39.87 ms | 122.95 → 40.23 ms | 22,912 → 70 | 24,046 → 203 | 16 → 12 |

MediaItem数量包括所有解析器调用及最近添加电影对象，不把同一对象被多个数组引用重复计数；不包括SeriesGroup/聚合对象。
SeriesGroup创建数量分别为45（千条库）和50（万条库），前后不变；全部查询返回行计入SQL行数，包括统计、年份和旧诊断结果。
**没有真机性能测量，不据此宣称真机性能提升。** 原始7轮数据见 [JSON](media-library-home-benchmark.json)。

复现（Node >=22且支持node:sqlite）：

```sh
npm install --prefix /tmp/vidall-home-test --no-package-lock --ignore-scripts typescript@5.6.3
TYPESCRIPT_PATH=/tmp/vidall-home-test/node_modules/typescript node --test entry/src/test/media_library_session_test.cjs
TYPESCRIPT_PATH=/tmp/vidall-home-test/node_modules/typescript node --test entry/src/test/media_library_home_test.cjs
TYPESCRIPT_PATH=/tmp/vidall-home-test/node_modules/typescript node --expose-gc entry/src/test/media_library_home_benchmark.cjs
python3 -B -m unittest discover -s scripts/ci -p 'test_test_gate.py' -v
devecocli build
```

## 验证结果与边界

- 模型竞态/失败恢复：33项通过，包括每一个主库查询晚到/失败、继续观看新增元数据await保护、前20候选不递补、全量电影进度映射。
- DAO+真实SQLite：18项通过，包括0/13/1000/10000条混合库等价性、电影重复文件计数、评分端点、全库搜索/年份/详情、未观看判断、超长剧集、两季与剧级混合、同时间顺序、数据库失败与未就绪。
- 测试门禁样例：15项通过，未修改#333设备门禁判定或放宽检查。
- CI保留Node20模型回归，新增Node22的真实SQLite回归job。
- deveco-cli构建通过（default/debug assembleHap）；依赖和已有ArkUI警告保留。
- 平台数据库冒烟：`MediaLibraryHomeDatabase.test.ets` 的3个用例已注册到 `entry/src/ohosTest/ets/test/List.test.ets` 的真实集成入口，直接在真实relationalStore上执行四个新增接口；覆盖空库、重复电影/评分10端点/两季分组，以及已观看标记、0%下一集与继续观看查找。通过 `MEDIA_LIBRARY_HOME_SMOKE=true` 在注册旧UI/扫描用例前返回，只运行这3条；平台运行结果以当前提交的集成CI为准。
- 每个冒烟用例使用 `VIDALL_HOME_QUERY_SMOKE_<timestamp>_<seq>.db` 的独立store与独立Core，不使用生产门面单例、不切换全局数据库名，finally关闭并删除该专用测试库。最小schema仅包含生产查询使用的列，测试不清空用户媒体库。
- 先前UnitTestBuild运行实际为796通过/2失败：有数据两例返回空，未放宽门禁。迁移后使用仓库TestContext.require提供的TestAbility UIAbilityContext（含模块信息），并在seed后回读断言videos=5、scrape_info=5，防止把未写入样例当查询验证；关闭和删除专用库均await并记录日志。导入链仅包含DAO、Core、纯工具及平台API，无生产库初始化调用。
- 使用 `devecocli build --modules entry@ohosTest` 构建真实集成测试HAP；集成工作流增加默认false的专用冒烟开关，保留原编译、执行、门禁和设备互斥。
- 设备/模拟器端到端界面与遥控器回归、设备1000/10000条冷/热加载及持续内存占用尚未验证；平台冒烟和主机性能测试均不替代这些验证。
