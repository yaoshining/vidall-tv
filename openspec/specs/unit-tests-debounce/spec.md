# unit-tests-debounce

## Purpose

验证 `DebounceUtil` 与 `CancellableFunction` 的核心行为，包括防抖实例创建、初始状态正确性及 `cancel()` 的幂等性。

## Requirements

### Requirement: DebounceUtil 防抖实例创建
`DebounceUtil.debounce(func, delay)` 应返回 `CancellableFunction` 实例，且默认延迟为 300ms。

#### Scenario: 使用默认延迟创建防抖实例
- **WHEN** 调用 `DebounceUtil.debounce(fn)`（不传 delay）
- **THEN** 返回一个 `CancellableFunction` 实例

#### Scenario: 使用自定义延迟创建防抖实例
- **WHEN** 调用 `DebounceUtil.debounce(fn, 500)`
- **THEN** 返回一个 `CancellableFunction` 实例

### Requirement: CancellableFunction 初始状态
新创建的 `CancellableFunction` 在未调用 `call()` 之前，内部 timeoutId 应为 undefined。

#### Scenario: 构造后状态为空
- **WHEN** 使用 `new CancellableFunction(fn, 300)` 创建实例
- **THEN** `cancel()` 可安全调用而不抛出异常（幂等）

### Requirement: CancellableFunction.cancel 幂等性
`cancel()` SHALL 可以被多次调用而不抛出异常，无论当前是否有待执行的回调。

#### Scenario: 未调用 call 时 cancel 不崩溃
- **WHEN** 直接调用 `cancel()` 而未先调用 `call()`
- **THEN** 不抛出异常

#### Scenario: 连续多次 cancel 不崩溃
- **WHEN** 连续调用 `cancel()` 两次
- **THEN** 不抛出异常
