import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Hypium } from '@ohos/hypium';
import testsuite from '../test/List.test';
import UIAbility from '@ohos.app.ability.UIAbility';
import type Want from '@ohos.app.ability.Want';
import type AbilityConstant from '@ohos.app.ability.AbilityConstant';
import type window from '@ohos.window';

export default class TestAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    console.info('TestAbility onCreate')
    const abilityDelegator = AbilityDelegatorRegistry.getAbilityDelegator()
    const abilityDelegatorArguments = AbilityDelegatorRegistry.getArguments()
    console.info(`start run testcase!!!`)
    Hypium.hypiumTest(abilityDelegator, abilityDelegatorArguments, testsuite)
  }

  onDestroy(): void {
    console.info('TestAbility onDestroy')
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    console.info('TestAbility onWindowStageCreate')
    windowStage.loadContent('testability/pages/Index', (err) => {
      if (err?.code) {
        console.error(`TestAbility, Failed to load the content. Cause: ${JSON.stringify(err)}`)
      }
    })
  }

  onWindowStageDestroy(): void {
    console.info('TestAbility onWindowStageDestroy')
  }

  onForeground(): void {
    console.info('TestAbility onForeground')
  }

  onBackground(): void {
    console.info('TestAbility onBackground')
  }
}
