# metrics-instrumentation-api

## Purpose

定义指标上报的架构契约，包括 MetricsReporter 接口、依赖注入模式、默认本地实现（LocalFileReporter）及扩展点，确保业务模块与上报实现解耦。

---
## Requirements
### Requirement: MetricsReporter Interface

The system SHALL provide a MetricsReporter interface that defines the contract for metrics collection, enabling future extension without changing instrumentation code.

#### Scenario: Interface defines core operations
- **WHEN** business code needs to record metrics
- **THEN** it uses MetricsReporter interface methods: recordPlaybackAttempt, recordSubtitleUsage, recordScanCoverage, flush

#### Scenario: Multiple implementations supported
- **WHEN** system initializes metrics reporting
- **THEN** it can use LocalFileReporter (default) or any future implementation conforming to interface

### Requirement: Dependency Injection for Reporter

The system SHALL use dependency injection to provide MetricsReporter implementation to components that record metrics.

#### Scenario: Reporter injected at initialization
- **WHEN** app initializes
- **THEN** a single MetricsReporter instance is created and injected into player, scanner, and subtitle modules

#### Scenario: Test reporter for unit tests
- **WHEN** running unit tests
- **THEN** a mock MetricsReporter can be injected to verify instrumentation without file I/O

#### Scenario: MetricsService 默认注入双写 reporter
- **WHEN** `MetricsService.initialize()` 在生产代码路径中被调用
- **THEN** system creates a composite MetricsReporter that delegates to both `LocalFileReporter` and `UmamiReporter`

### Requirement: LocalFileReporter Implementation

The system SHALL provide a LocalFileReporter as the default implementation that stores metrics in JSON files.

#### Scenario: LocalFileReporter persists to JSON
- **WHEN** LocalFileReporter.flush() is called
- **THEN** it writes aggregated metrics to YYYY-MM-DD.json in app preferences directory

#### Scenario: LocalFileReporter manages retention
- **WHEN** LocalFileReporter initializes
- **THEN** it deletes metrics files older than 30 days

### Requirement: Extension Points for Future Analytics

The system SHALL design the architecture to allow adding remote analytics reporting without modifying instrumentation points.

#### Scenario: Future remote reporter added
- **WHEN** a RemoteAnalyticsReporter implementation is created in the future
- **THEN** it implements MetricsReporter interface and can be swapped via dependency injection without changing business code

#### Scenario: Composite reporter pattern supported
- **WHEN** both local and remote reporting are needed simultaneously
- **THEN** a CompositeReporter can delegate to multiple implementations (e.g., LocalFileReporter + RemoteAnalyticsReporter)

#### Scenario: UmamiReporter 作为当前远端实现接入
- **WHEN** remote analytics is enabled by default for the app
- **THEN** `UmamiReporter` acts as the remote MetricsReporter implementation behind the composite reporter

### Requirement: Error Handling and Resilience

The system SHALL handle metrics collection errors gracefully without impacting core application functionality.

#### Scenario: Metrics failure does not crash app
- **WHEN** metrics recording or persistence fails (e.g., disk full, permission denied)
- **THEN** error is logged but app continues normal operation

#### Scenario: Failed flush retried on next lifecycle event
- **WHEN** flush operation fails
- **THEN** in-memory metrics are retained and retry attempted on next flush trigger

### Requirement: Thread Safety

The system SHALL ensure MetricsReporter operations are thread-safe for concurrent access from multiple components.

#### Scenario: Concurrent metric recording
- **WHEN** multiple threads record metrics simultaneously (e.g., player and scanner)
- **THEN** operations complete without data corruption or race conditions

#### Scenario: Flush during recording
- **WHEN** flush operation runs while metrics are being recorded
- **THEN** operations are serialized or use appropriate locking to prevent data loss

### Requirement: Metrics Schema Versioning

The system SHALL version the metrics JSON schema to support future schema evolution without breaking compatibility.

#### Scenario: Schema version field present
- **WHEN** metrics are written to file
- **THEN** JSON includes "schema_version" field (current: 1)

#### Scenario: Read old schema gracefully
- **WHEN** reading metrics from older schema version
- **THEN** system handles missing fields gracefully (default to zero/null) and writes using current schema

