import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import fs from '@ohos.file.fs';

/**
 * 刮削失败原始错误信息的临时存储。
 *
 * - 目录：`<cacheDir>/scrape-failures/`，App 关闭后可被系统清理，不持久化。
 * - context 由 UI 启动时通过 `setContext()` 注入（service 层无法直接获取 UIAbilityContext）。
 * - writeLog 返回 logKey（文件名），readLog 按 logKey 读回内容。
 */
export class ScrapeFailureLogStore {
  private static context: common.Context | null = null;
  private static sequence: number = 0;

  static setContext(context: common.Context): void {
    ScrapeFailureLogStore.context = context;
  }

  private static getDir(): string {
    const ctx = ScrapeFailureLogStore.context;
    if (ctx !== null) {
      return ctx.cacheDir + '/scrape-failures';
    }
    return '/tmp/scrape-failures';
  }

  private static ensureDir(): void {
    try {
      fs.mkdirSync(ScrapeFailureLogStore.getDir(), true);
    } catch (e) {
      const be = e as BusinessError;
      // 13900015 = 目录已存在，忽略；其余仅告警不影响主流程
      if (be.code !== 13900015) {
        console.warn(`[ScrapeFailureLogStore] mkdirSync 失败 code=${be.code}: ${be.message}`);
      }
    }
  }

  /** 追加写入一条失败原始日志，返回可读回的 logKey；写入失败返回空串（不抛异常，避免中断主流程）。 */
  static async writeLog(detail: string): Promise<string> {
    ScrapeFailureLogStore.ensureDir();
    const timestamp = Date.now();
    ScrapeFailureLogStore.sequence++;
    const logKey = `scrape-failure-${timestamp}-${ScrapeFailureLogStore.sequence}.txt`;
    const path = `${ScrapeFailureLogStore.getDir()}/${logKey}`;
    try {
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, detail);
      } finally {
        fs.closeSync(file);
      }
      return logKey;
    } catch (e) {
      const be = e as BusinessError;
      console.warn(`[ScrapeFailureLogStore] writeLog 失败: ${be.message}`);
      return '';
    }
  }

  /** 按 logKey 读回日志内容；读取失败返回空串。 */
  static async readLog(logKey: string): Promise<string> {
    const path = `${ScrapeFailureLogStore.getDir()}/${logKey}`;
    try {
      return fs.readTextSync(path);
    } catch {
      return '';
    }
  }

  /** 清空临时日志目录（App 启动时调用，实现"关 app 可清理"）。 */
  static async clearAll(): Promise<void> {
    const dir = ScrapeFailureLogStore.getDir();
    try {
      const entries = fs.listFileSync(dir);
      for (let index = 0; index < entries.length; index++) {
        fs.unlinkSync(`${dir}/${entries[index]}`);
      }
      fs.rmdirSync(dir);
    } catch {
      // 目录不存在或已清空，忽略
    }
  }
}
