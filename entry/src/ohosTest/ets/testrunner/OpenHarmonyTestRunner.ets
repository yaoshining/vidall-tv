import TestRunner from '@ohos.application.testRunner';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import UIAbility from '@ohos.app.ability.UIAbility';
import type Want from '@ohos.app.ability.Want';

let abilityDelegator: AbilityDelegatorRegistry.AbilityDelegator;
let abilityDelegatorArguments: AbilityDelegatorRegistry.AbilityDelegatorArgs;

function onAbilityCreate(_ability: UIAbility): void {
  console.log('onAbilityCreate');
}

export default class OpenHarmonyTestRunner implements TestRunner {
  constructor() {}

  onPrepare(): void {
    console.info('OpenHarmonyTestRunner OnPrepare');
  }

  onRun(): void {
    console.log('OpenHarmonyTestRunner onRun run');
    abilityDelegator = AbilityDelegatorRegistry.getAbilityDelegator();
    abilityDelegatorArguments = AbilityDelegatorRegistry.getArguments();
    const bundleName = abilityDelegatorArguments.bundleName;
    const testAbilityName = 'TestAbility';

    const lMonitor: AbilityDelegatorRegistry.AbilityMonitor = {
      abilityName: testAbilityName,
      onAbilityCreate: onAbilityCreate,
    };

    abilityDelegator.addAbilityMonitor(lMonitor, () => {});

    const want: Want = {
      bundleName: bundleName,
      abilityName: testAbilityName,
    };

    abilityDelegator.startAbility(want, () => {});
  }
}
