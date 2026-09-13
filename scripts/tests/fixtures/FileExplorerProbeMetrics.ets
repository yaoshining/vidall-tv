export class FileExplorerProbeMetrics {
  static end: () => void = () => {};
  static removeFocused: () => void = () => {};
  static created: number = 0;
  static live: number = 0;
  static peak: number = 0;
  static start: number = 0;
  static firstVisibleMs: number = -1;
  static mode: string = '';
  static reset(mode: string): void {
    FileExplorerProbeMetrics.created = 0; FileExplorerProbeMetrics.live = 0; FileExplorerProbeMetrics.peak = 0; FileExplorerProbeMetrics.firstVisibleMs = -1;
    FileExplorerProbeMetrics.start = Date.now(); FileExplorerProbeMetrics.mode = mode;
  }
  static appear(): void { FileExplorerProbeMetrics.created++; FileExplorerProbeMetrics.live++; FileExplorerProbeMetrics.peak = Math.max(FileExplorerProbeMetrics.peak, FileExplorerProbeMetrics.live); }
  static disappear(): void { FileExplorerProbeMetrics.live--; }
  static visible(visible: boolean, ratio: number): void {
    if (visible && ratio > 0 && FileExplorerProbeMetrics.firstVisibleMs < 0) {
      FileExplorerProbeMetrics.firstVisibleMs = Date.now() - FileExplorerProbeMetrics.start;
    }
  }
  static report(): string {
    return `${FileExplorerProbeMetrics.mode} created=${FileExplorerProbeMetrics.created} live=${FileExplorerProbeMetrics.live} peak=${FileExplorerProbeMetrics.peak} firstVisibleMs=${FileExplorerProbeMetrics.firstVisibleMs}`;
  }
}
