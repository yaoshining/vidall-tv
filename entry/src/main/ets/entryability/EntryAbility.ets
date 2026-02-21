import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { IBestInit } from "@ibestservices/ibest-ui"
import { FileSourceDatabase } from '../db/files/FileSourceDatabase';
import { AppPreferences, PrefKey } from '../utils/AppPreferences';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');

    // 并行初始化 AppPreferences 和数据库
    AppPreferences.init(this.context)
      .then(async () => {
        hilog.info(DOMAIN, 'testTag', 'AppPreferences initialized successfully');
        await AppPreferences.set(PrefKey.TMDB_API_KEY, '8a4f81133468d801df27c9cdcb5c33af');
      })
      .catch((err: Error) => {
        hilog.error(DOMAIN, 'testTag', 'Failed to init AppPreferences: %{public}s', JSON.stringify(err));
      });

    FileSourceDatabase.getInstance(this.context).init()
      .then(() => {
        hilog.info(DOMAIN, 'testTag', 'Database initialized successfully');
      })
      .catch((err: Error) => {
        hilog.error(DOMAIN, 'testTag', 'Failed to init database: %{public}s', JSON.stringify(err));
      });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');

      windowStage.getMainWindow((err, window) => {
        if (err.code) {
          console.error('获取主窗口失败: ' + JSON.stringify(err));
          return;
        }

        window.setWindowKeepScreenOn(true)
          .then(() => {
            console.log("禁止熄屏成功！")
          })
          .catch(() => {
            console.error("禁止熄屏失败")
          })
      })

      IBestInit(windowStage, this.context)

    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}