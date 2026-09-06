/** 懒加载网格适配器；仅在搜索响应被接受后原子替换结果。 */
@ObservedV2
export class SearchResultSource<T> implements IDataSource {
  private items: T[] = [];
  // 父级条件渲染必须在 LazyForEach 尚未注册监听器时也能收到数量变化。
  @Trace private count: number = 0;
  private listeners: DataChangeListener[] = [];
  totalCount(): number { return this.count; }
  getData(index: number): T { return this.items[index]; }
  replace(items: T[]): void {
    this.items = items;
    this.count = items.length;
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }
  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener); }
  }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) { this.listeners.splice(index, 1); }
  }
}
