# playback-metrics-collection

## Purpose

定义播放指标的采集内容与聚合规则，涵盖播放成功率、首帧时间、字幕使用、扫描覆盖率、本地持久化、性能约束及隐私合规要求。

---
## Requirements
### Requirement: Playback Success Rate Tracking

The system SHALL record every playback attempt and its outcome (success or failure) for calculating playback success rate.

#### Scenario: Successful playback recorded
- **WHEN** a video playback starts and the first frame is rendered
- **THEN** the system records a successful playback attempt

#### Scenario: Failed playback recorded
- **WHEN** a video playback attempt fails due to error (file not found, codec error, etc.)
- **THEN** the system records a failed playback attempt with error category

#### Scenario: Success rate calculation
- **WHEN** metrics are aggregated at the end of day
- **THEN** success rate is calculated as (successful_attempts / total_attempts) * 100

### Requirement: First Frame Time Measurement

The system SHALL measure the time from playback initiation to first video frame rendered for monitoring startup performance.

#### Scenario: First frame time captured
- **WHEN** user initiates playback (manual or auto-play)
- **THEN** system starts timer and records duration when first video frame is rendered

#### Scenario: Percentile aggregation
- **WHEN** metrics are aggregated
- **THEN** system calculates p50, p90, and p99 percentiles for first frame time

#### Scenario: Failed playback excludes timing
- **WHEN** playback fails before first frame
- **THEN** no first frame time metric is recorded for that attempt

### Requirement: Subtitle Usage Tracking

The system SHALL track subtitle language selection and usage patterns to understand user preferences.

#### Scenario: Subtitle language recorded
- **WHEN** user manually selects a subtitle language during playback
- **THEN** system records the selected language code (ISO 639-1 or 639-2)

#### Scenario: No subtitle usage recorded
- **WHEN** user plays video without selecting subtitles
- **THEN** system records subtitle usage as null/none

#### Scenario: Language aggregation
- **WHEN** metrics are aggregated
- **THEN** system counts usage per language and calculates percentage of playbacks with subtitles

### Requirement: Scanning Coverage Metrics

The system SHALL track media scanning operations and calculate coverage to monitor scanning effectiveness.

#### Scenario: Scan operation recorded
- **WHEN** a media library scan completes
- **THEN** system records total items scanned and items successfully matched with metadata

#### Scenario: Coverage calculation
- **WHEN** scan metrics are recorded
- **THEN** coverage is calculated as (items_with_metadata / total_items) * 100

#### Scenario: Multiple scans aggregated
- **WHEN** multiple scans occur in a day
- **THEN** system aggregates total coverage across all scans

### Requirement: Local Metrics Persistence

The system SHALL persist collected metrics to local storage with daily granularity and time-based retention.

#### Scenario: Daily metrics file created
- **WHEN** first metric is recorded on a new day
- **THEN** system creates a new JSON file named YYYY-MM-DD.json in app preferences directory

#### Scenario: In-memory aggregation
- **WHEN** metrics are recorded during app session
- **THEN** system updates in-memory aggregates without writing to disk

#### Scenario: Flush on lifecycle events
- **WHEN** app enters background or terminates normally
- **THEN** system flushes in-memory metrics to disk

#### Scenario: Retention policy enforcement
- **WHEN** app starts
- **THEN** system deletes metrics files older than 30 days

#### Scenario: 本地持久化与 Umami 云端上报同时生效
- **WHEN** metrics are recorded during app session
- **THEN** local JSON persistence remains the backup path while the same metrics may also be sent to Umami asynchronously

### Requirement: Performance Constraints

The system SHALL ensure metrics collection does not negatively impact playback performance.

#### Scenario: Low overhead recording
- **WHEN** a metric is recorded
- **THEN** the operation completes in less than 1ms

#### Scenario: Non-blocking persistence
- **WHEN** metrics are flushed to disk
- **THEN** the operation runs asynchronously and does not block UI or playback threads

### Requirement: Privacy Compliance

The system SHALL collect only metrics needed for playback, subtitle and scan analytics, and MUST avoid exposing sensitive identifiers in logs or remote payloads beyond the explicitly approved pseudonymous device UUID used for Umami identify.

#### Scenario: No raw file path in remote analytics
- **WHEN** metrics are transformed into Umami event payloads
- **THEN** file paths are not included in remote analytics data

#### Scenario: Pseudonymous device UUID allowed for identify
- **WHEN** remote analytics identifies a device in Umami
- **THEN** the system uses a persisted pseudonymous device UUID instead of a vendor account ID or user identity

#### Scenario: Metrics no longer limited to local storage only
- **WHEN** remote analytics is enabled via the default composite reporter
- **THEN** playback, subtitle and scan metrics may be transmitted to the configured Umami service in addition to being stored locally

