export interface FfmpegExecuteOptions {
  outputCallback?: (msg: string) => void;
  signal?: FFAbortSignal;
}

export class FFAbortSignal {
  aborted: boolean = false;
  reason?: Error;
}

export class FFAbortController {
  private abortSignal: FFAbortSignal = new FFAbortSignal();

  get signal(): FFAbortSignal {
    return this.abortSignal;
  }

  abort(reason?: Error): void {
    this.abortSignal.aborted = true;
    this.abortSignal.reason = reason;
  }
}

export class FFmpeg {
  static execute(commands: string[], options?: FfmpegExecuteOptions): Promise<void> {
    const cmd = commands.length > 0 ? commands.join(' ') : '(empty)';
    const msg = `[NativeFfmpegCompat] FFmpeg.execute 暂未接入自研 NAPI，命令未执行: ${cmd}`;
    if (options && options.outputCallback) {
      options.outputCallback(msg);
    }
    return Promise.reject(new Error(msg));
  }
}