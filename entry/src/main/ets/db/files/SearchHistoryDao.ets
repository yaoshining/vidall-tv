import relationalStore from '@ohos.data.relationalStore';
import { SearchHistoryEntry } from '../models/MediaEntity';
import { BusinessError } from "@kit.BasicServicesKit";
import { TABLE_SCOPED_SEARCH_HISTORY } from './DbConstants';
import { FileSourceDbCore } from './FileSourceDbCore';

/**
 * search_history 表的数据访问。
 * 来源键为必填，旧全局历史不参与读取。
 */
export class SearchHistoryDao {
  private core: FileSourceDbCore;

  constructor(core: FileSourceDbCore) {
    this.core = core;
  }

  /**
   * 新增或更新搜索历史（upsert by scope_key, keyword）。
   * 相同关键词重复搜索时，更新 searched_at 为当前时间。
   */
  async upsertSearchHistory(scopeKey: string, keyword: string): Promise<void> {
    if (scopeKey.trim().length === 0 || !this.core.isReady()) {
      return;
    }
    const store = this.core.getStore();
    const now = Date.now();
    try {
      // 标准 SQLite upsert：ON CONFLICT(scope_key, keyword) DO UPDATE
      await store.executeSql(
        `INSERT INTO ${TABLE_SCOPED_SEARCH_HISTORY} (scope_key, keyword, searched_at) VALUES (?, ?, ?)` +
        ` ON CONFLICT(scope_key, keyword) DO UPDATE SET searched_at = excluded.searched_at`,
        [scopeKey, keyword, now]
      );
      // 裁剪：只保留最近 15 条，防止表无限增长
      await store.executeSql(
        `DELETE FROM ${TABLE_SCOPED_SEARCH_HISTORY} WHERE scope_key = ? AND id NOT IN ` +
        `(SELECT id FROM ${TABLE_SCOPED_SEARCH_HISTORY} WHERE scope_key = ? ORDER BY searched_at DESC, id DESC LIMIT 15)`,
        [scopeKey, scopeKey]
      );
      console.info(`[DB][upsertSearchHistory] keyword=[${keyword.length}chars]`);
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[DB][upsertSearchHistory] 失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 获取搜索历史列表，按 searched_at 倒序排列。
   * @param limit 最大返回条数，默认 20
   */
  async getSearchHistory(scopeKey: string, limit: number = 20): Promise<SearchHistoryEntry[]> {
    if (scopeKey.trim().length === 0 || !this.core.isReady()) {
      return [];
    }
    const store = this.core.getStore();
    // 入口校验：防止 NaN / 负数 / 超出合理范围的值
    const safeLimit: number = (Number.isInteger(limit) && limit > 0 && limit <= 50) ? limit : 20;
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(
        `SELECT keyword, searched_at FROM ${TABLE_SCOPED_SEARCH_HISTORY}` +
        ` WHERE scope_key = ? ORDER BY searched_at DESC, id DESC LIMIT ${safeLimit}`,
        [scopeKey]
      );
      const result: SearchHistoryEntry[] = [];
      while (rs.goToNextRow()) {
        const entry = new SearchHistoryEntry();
        entry.keyword = rs.getString(rs.getColumnIndex('keyword'));
        entry.searchedAt = rs.getLong(rs.getColumnIndex('searched_at'));
        result.push(entry);
      }
      console.info(`[DB][getSearchHistory] 共 ${result.length} 条记录`);
      return result;
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[DB][getSearchHistory] 查询失败 code=${err.code} msg=${err.message}`);
      return [];
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  /**
   * 删除单条搜索历史。
   * @param keyword 要删除的关键词
   */
  async deleteSearchHistory(scopeKey: string, keyword: string): Promise<void> {
    if (scopeKey.trim().length === 0 || !this.core.isReady()) {
      return;
    }
    const store = this.core.getStore();
    try {
      await store.executeSql(
        `DELETE FROM ${TABLE_SCOPED_SEARCH_HISTORY} WHERE scope_key = ? AND keyword = ?`,
        [scopeKey, keyword]
      );
      console.info(`[DB][deleteSearchHistory] keyword=[${keyword.length}chars] 已删除`);
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[DB][deleteSearchHistory] 失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 清空当前来源搜索历史。
   */
  async clearSearchHistory(scopeKey: string): Promise<void> {
    if (scopeKey.trim().length === 0 || !this.core.isReady()) {
      return;
    }
    const store = this.core.getStore();
    try {
      await store.executeSql(
        `DELETE FROM ${TABLE_SCOPED_SEARCH_HISTORY} WHERE scope_key = ?`, [scopeKey]
      );
      console.info('[DB][clearSearchHistory] 当前来源搜索历史已清空');
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[DB][clearSearchHistory] 失败 code=${err.code} msg=${err.message}`);
    }
  }
}
