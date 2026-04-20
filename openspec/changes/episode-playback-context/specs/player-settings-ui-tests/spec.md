## MODIFIED Requirements

### Requirement: 播放器设置面板保持与当前实现一致的区块结构
系统 SHALL 保持播放器设置面板的当前结构：媒体库上下文下在顶部插入 `选集` 区块，后续仍保留原有的倍速与画面比例等设置区域。

#### Scenario: 有媒体库上下文时顶部先显示选集区块
- **WHEN** 播放器携带 `MediaLibraryContext` 打开设置面板
- **THEN** `选集` 区块位于倍速与画面比例等设置区域之前

#### Scenario: 无媒体库上下文时保留原有设置布局
- **WHEN** 播放器没有 `MediaLibraryContext`
- **THEN** 设置面板继续显示原有设置区域，且不插入 `选集` 区块

---

### Requirement: 选集分页文案与当前实现一致
系统 SHALL 使用与当前实现一致的分页文案，不再要求旧版滚动分页或旧版视觉元素。

#### Scenario: 第二段分页覆盖从第 7 集到最后一集
- **WHEN** 当前季总集数大于 6
- **THEN** 第二段分页标签显示为 `7-最后一集序号`

#### Scenario: 文档不再要求旧版分页视觉元素
- **WHEN** 审阅本 change 的设置面板相关要求
- **THEN** 不再包含 Tab、pager pill、focus ring、已看标记或旧版 UI 自动化场景
