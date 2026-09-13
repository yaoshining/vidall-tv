import { Core } from '@ohos/hypium';
import fs from '@ohos.file.fs';

// 与 Hypium 1.0.25 的覆盖率落盘共用 Previewer 文件通道，不解析 console/hilog。
export class StructuredReport {
  constructor(fileSystem = fs) {
    this.id = 'vidall-structured';
    this.fs = fileSystem;
    this.cases = [];
    this.hookErrors = [];
    this.pending = null;
  }

  init(core) {
    this.spec = core.getDefaultService('spec');
    this.suite = core.getDefaultService('suite');
    core.subscribeEvent('spec', this);
    core.subscribeEvent('suite', this);
    // Core.init 在 OhReport 注册前调用，保证文件在 SDK finishTest 之前写完。
    core.subscribeEvent('task', this);
  }

  taskStart() {
    if (globalThis.__testMode__ !== 'unitTest') {
      throw new Error('结构化报告仅支持 Previewer 单测');
    }
    const directory = globalThis.__savePath__.replace(/js_coverage\.json$/, '');
    this.active = this.fs.accessSync(directory + 'gate-context.json');
    if (!this.active) return;
    const input = this.fs.openSync(directory + 'gate-context.json', this.fs.OpenMode.READ_ONLY);
    try {
      const buffer = new ArrayBuffer(4096);
      const length = this.fs.readSync(input.fd, buffer);
      if (length <= 0 || length >= buffer.byteLength) throw new Error('运行身份文件长度不合法');
      let text = '';
      for (const byte of new Uint8Array(buffer, 0, length)) text += String.fromCharCode(byte);
      this.context = JSON.parse(text);
    } finally {
      this.fs.closeSync(input);
    }
    this.path = directory + 'gate-results.json';
    this.expected = this.spec.getTestTotal();
    this.startedAt = Date.now();
  }

  suiteStart() {}
  suiteDone() {
    if (!this.active) return;
    const suite = this.suite.currentRunningSuite;
    if (suite.hookError) {
      this.hookErrors.push(String(suite.hookError.message || suite.hookError));
    }
  }
  specStart() {
    if (!this.active) return;
    if (this.pending) throw new Error('上一用例未完成');
    this.pending = this.spec.currentRunningSpec;
  }
  specDone() {
    if (!this.active) return;
    const spec = this.spec.currentRunningSpec;
    if (!this.pending || this.pending !== spec) throw new Error('用例开始和结束不匹配');
    this.cases.push({
      id: this.cases.length + 1,
      name: spec.description,
      suite: this.suite.getCurrentRunningSuiteDesc(),
      status: spec.isSkip ? 'skipped' : spec.error ? 'broken' : spec.fail ? 'failed' : 'passed'
    });
    this.pending = null;
  }
  taskDone() {
    if (!this.active) return;
    if (this.pending) throw new Error('最后一个用例未完成');
    const summary = this.suite.getSummary();
    const report = {
      schema: 1, runtime: 'Previewer', run_id: this.context.run_id,
      commit_sha: this.context.commit_sha, execution_started_at: this.context.started_at,
      started_at: this.startedAt, finished_at: Date.now(), complete: true,
      expected: this.expected, summary: {
        total: summary.total, passed: summary.pass, failed: summary.failure,
        errors: summary.error, ignored: summary.ignore
      }, cases: this.cases, hook_errors: this.hookErrors
    };
    const file = this.fs.openSync(this.path, this.fs.OpenMode.CREATE | this.fs.OpenMode.READ_WRITE | this.fs.OpenMode.TRUNC);
    try {
      this.fs.writeSync(file.fd, JSON.stringify(report), { encoding: 'utf-8' });
    } finally {
      this.fs.closeSync(file);
    }
  }
  incorrectFormat() { throw new Error('测试过滤参数不合法'); }
  incorrectTestSuiteFormat() { throw new Error('包含未执行测试套件'); }
}

export function installStructuredReport() {
  Core.getInstance().addService('report', new StructuredReport());
}
