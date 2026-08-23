import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { IBestInit } from "@ibestservices/ibest-ui"
import { FileSourceDatabase } from '../db/files/FileSourceDatabase';
import { AppPreferences, PrefKey } from '../utils/AppPreferences';
import { emitter } from '@kit.BasicServicesKit';
import { PlayerEvents } from '../components/core/player/Constants';
import { ServiceLocator } from '../services/ServiceLocator';
import { LocalFreeEntitlementService } from '../services/entitlement/LocalFreeEntitlementService';
import { AccountService } from '../services/account/AccountService';
import { HuaweiAuthProvider } from '../services/account/providers/HuaweiAuthProvider';
import { AgcCloudAuthService } from '../services/account/AgcCloudAuthService';
import { AccountModel } from '../stores/account/AccountModel';
import { MetricsService } from '../services/metrics/MetricsService';
import { CompositeMetricsReporter } from '../services/metrics/CompositeMetricsReporter';
import { LocalFileReporter } from '../services/metrics/LocalFileReporter';
import { UmamiReporter, UmamiEventData } from '../services/analytics/UmamiReporter';
import { UmamiAnalyticsService } from '../services/analytics/UmamiAnalyticsService';
import bundleManager from '@ohos.bundle.bundleManager';
import deviceInfo from '@ohos.deviceInfo';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');

    // 初始化 MetricsService（共享 UmamiReporter 实例给 UmamiAnalyticsService）
    const umamiReporter = new UmamiReporter();
    MetricsService.initialize(this.context, new CompositeMetricsReporter([
      new LocalFileReporter(this.context),
      umamiReporter
    ]));
    hilog.info(DOMAIN, 'testTag', 'MetricsService initialized');

    // 初始化 UmamiAnalyticsService（复用同一 UmamiReporter 实例）
    UmamiAnalyticsService.initialize(umamiReporter);
    hilog.info(DOMAIN, 'testTag', 'UmamiAnalyticsService initialized');

    // 发送 app_launch 事件
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((info) => {
        const svc = UmamiAnalyticsService.getInstance();
        const appVersion = info.versionName;
        const osVersion = deviceInfo.osFullName;
        // 使用 version 字段（Issue 规范命名），同时保留 os_version 上报系统版本
        const eventData: UmamiEventData = { version: appVersion, os_version: osVersion };
        svc.trackEvent('system', 'app_launch', eventData);
        hilog.info(DOMAIN, 'testTag', `app_launch sent version=${appVersion}`);
      })
      .catch(() => {
        const eventData: UmamiEventData = { os_version: deviceInfo.osFullName };
        UmamiAnalyticsService.getInstance().trackEvent('system', 'app_launch', eventData);
      });

    // 初始化 EntitlementService (v1.x: LocalFree 实现，所有功能免费)
    const entitlementService = new LocalFreeEntitlementService();
    ServiceLocator.register('entitlement', entitlementService);
    hilog.info(DOMAIN, 'testTag', 'EntitlementService registered (LocalFree mode)');

    // 初始化 AGC 认证与 AccountService（须在 UI 构建前完成）
    try {
      AgcCloudAuthService.getInstance().initialize(this.context);
      hilog.info(DOMAIN, 'testTag', 'AGC Authentication initialized');
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'Failed to init AGC Authentication: %{public}s', JSON.stringify(e));
    }
    const accountService = AccountService.getInstance();
    accountService.registerProvider(new HuaweiAuthProvider());
    hilog.info(DOMAIN, 'testTag', 'AccountService initialized, HuaweiAuthProvider registered');

    // 并行初始化 AppPreferences 和数据库
    AppPreferences.init(this.context)
      .then(async () => {
        hilog.info(DOMAIN, 'testTag', 'AppPreferences initialized successfully');
        await AccountModel.getInstance().restore();
        await AppPreferences.set(PrefKey.TMDB_API_KEY, '8a4f81133468d801df27c9cdcb5c33af');
        const lastBreadcrumb = await AppPreferences.get(PrefKey.PLAYER_LAST_BREADCRUMB, '');
        if (lastBreadcrumb.length > 0) {
          const isNormalTerminal = lastBreadcrumb.includes('|release-done|');
          const maxLen = 240;
          const clipped = lastBreadcrumb.length > maxLen
            ? lastBreadcrumb.substring(0, maxLen) + '...'
            : lastBreadcrumb;
          if (!isNormalTerminal) {
            hilog.warn(DOMAIN, 'testTag', 'LAST_PLAYER_BREADCRUMB=%{public}s', clipped);
          } else {
            hilog.info(DOMAIN, 'testTag', 'LAST_PLAYER_BREADCRUMB(normal)=%{public}s', clipped);
          }
          await AppPreferences.set(PrefKey.PLAYER_LAST_BREADCRUMB, '');
        }
      })
      .catch(() => {
        hilog.error(DOMAIN, 'testTag', 'Failed to init AppPreferences');
      });

    FileSourceDatabase.getInstance(this.context).init()
      .then(() => {
        hilog.info(DOMAIN, 'testTag', 'Database initialized successfully');
      })
      .catch(() => {
        hilog.error(DOMAIN, 'testTag', 'Failed to init database');
      });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
    
    // Flush metrics before destroy
    if (MetricsService.isInitialized()) {
      MetricsService.getInstance().flush()
        .then(() => {
          hilog.info(DOMAIN, 'testTag', 'Metrics flushed on destroy');
        })
        .catch(() => {
          hilog.error(DOMAIN, 'testTag', 'Failed to flush metrics on destroy');
        });
    }
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
    
    // Flush metrics before going to background
    if (MetricsService.isInitialized()) {
      MetricsService.getInstance().flush()
        .then(() => {
          hilog.info(DOMAIN, 'testTag', 'Metrics flushed on background');
        })
        .catch(() => {
          hilog.error(DOMAIN, 'testTag', 'Failed to flush metrics on background');
        });
    }
    
    // 通知正在播放的播放器页面立即落盘进度
    emitter.emit(PlayerEvents.APP_BACKGROUND);
  }
}