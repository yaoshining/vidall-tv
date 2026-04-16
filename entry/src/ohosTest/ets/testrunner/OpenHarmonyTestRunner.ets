import TestRunner from '@ohos.application.testRunner';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';

let abilityDelegator: AbilityDelegatorRegistry.AbilityDelegator;
let abilityDelegatorArguments: AbilityDelegatorRegistry.AbilityDelegatorArgs;

async function onAbilityCreate(moduleName: string): Promise<void> {
  console.log(`onAbilityCreate moduleName=${moduleName}`);
}

export default class OpenHarmonyTestRunner implements TestRunner {
  constructor() {}

  onPrepare(): void {
    console.info('OpenHarmonyTestRunner OnPrepare');
  }

  async onRun(): Promise<void> {
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

    const want = {
      bundleName: bundleName,
      abilityName: testAbilityName,
    };

    abilityDelegator.startAbility(want, () => {});
  }
}
