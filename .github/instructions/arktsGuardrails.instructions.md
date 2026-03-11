---
applyTo: "entry/src/main/ets/**/*.ets"
description: "ArkTS 编译护栏。用于 HarmonyOS ArkTS 页面、组件、控制器、工具类开发与修复。关键词：ArkTS、编译错误、any、unknown、catch、Promise、aboutToAppear、NavDestination、build限制、arkts-no-any-unknown。"
---

# ArkTS 编译护栏

## 基础约束

- 禁止 `any` / `unknown` 类型，必须使用明确类型
- `throw` 只能抛 `Error` 或其子类
- `build()` 内只能写 UI 组件语法，不能写普通变量声明和非 UI 赋值语句
- 对象字面量作为返回值、入参、`map()` 回调结果时，优先先声明显式类型变量再返回或传递

## catch 与 Promise

- `catch` 子句不能写类型注解，只能写 `catch (e)`
- 若需要读取错误信息，在 `catch` 体内转成 `BusinessError`
- Promise 链上的 `.catch((e) => {})`、`.then((v) => {})` 回调参数同样可能被 ArkTS 推断为 `unknown`
- 如果回调参数未使用，必须直接写成无参回调，例如 `.catch(() => {})`
- 如果确实需要使用回调参数，优先抽成具备显式类型的辅助方法，不要直接内联匿名回调参数

## 生命周期与 NavDestination

- `aboutToAppear`、`aboutToDisappear` 等生命周期必须定义为 `@ComponentV2 struct` 的方法
- 不要把 `aboutToAppear`、`aboutToDisappear` 链在 `NavDestination()` 返回的属性对象上
- `NavDestinationAttribute` 不支持这些生命周期方法，链式调用会直接触发编译错误

## 本仓库高频错误复盘

- 遇到 `arkts-no-any-unknown`，优先检查：`catch`、Promise 回调参数、匿名函数参数推断
- 遇到 `Property 'aboutToAppear' does not exist on type 'NavDestinationAttribute'`，优先检查是否把生命周期错误写到了 `NavDestination()` 链上
- 改完 ArkTS 文件后，优先做文件级错误检查，先清类型错误，再清作用域或生命周期错误