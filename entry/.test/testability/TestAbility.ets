
    import AbilityConstant from '@ohos.app.ability.AbilityConstant';
    import hilog from '@ohos.hilog';
    import UIAbility from '@ohos.app.ability.UIAbility';
    import Want from '@ohos.app.ability.Want';
    import window from '@ohos.window';
    
    export default class EntryAbility extends UIAbility {
        onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {
            hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onCreate');
            // 暴露 Context 给需要 DB / 文件系统的测试用例
            globalThis.abilityContext = this.context;
        }
    
        onDestroy() {
            hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onDestroy');
        }
    
        onWindowStageCreate(windowStage: window.WindowStage) {
            // Main window is created, set main page for this ability
            hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    
            windowStage.loadContent('../../../.test/testability/pages/Index', (err, data) => {
                if (err.code) {
                    hilog.error(0x0000, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err) ?? '');
                    return;
                }
                hilog.info(0x0000, 'testTag', 'Succeeded in loading the content. Data: %{public}s', JSON.stringify(data) ?? '');
            });
        }
    
        onWindowStageDestroy() {
            // Main window is destroyed, release UI related resources
            hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
        }
    
        onForeground() {
            // Ability has brought to foreground
            hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onForeground');
        }
    
        onBackground() {
            // Ability has back to background
            hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onBackground');
        }
    }
  