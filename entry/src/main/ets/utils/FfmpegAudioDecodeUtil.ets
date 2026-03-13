import { FFAbortController, FFmpeg } from '@sj/ffmpeg';

export interface FfmpegAudioDecodeResult {
  success: boolean;
  outputPath: string;
  errorMessage?: string;
}

/**
 * FFmpeg 音频软解工具（Phase 1: 输出 WAV 文件）。
 *
 * 说明：
 * - 当前阶段先把 AC-3/DTS 等音轨统一转为 PCM WAV，验证软解链路可用性。
 * - 后续接入 AudioRenderer 时，可直接复用该工具并替换输出目的地（文件/管道）。
 */
export class FfmpegAudioDecodeUtil {
  static async decodeFirstAudioTrackToWav(
    url: string,
    outputPath: string,
    headers?: Record<string, string>,
    timeoutMs: number = 120000,
    maxDecodeSeconds: number = 90,
    startSeconds: number = 0,
    targetChannels: number = 2
  ): Promise<FfmpegAudioDecodeResult> {
    let headersStr = '';
    if (headers) {
      const keys = Object.keys(headers);
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        headersStr += `${key}: ${headers[key]}\r\n`;
      }
    }

    const commands: string[] = [
      'ffmpeg',
      '-y',
      '-v', 'error'
    ];

    if (headersStr.length > 0) {
      commands.push('-headers', headersStr);
    }

    if (startSeconds > 0) {
      commands.push('-ss', `${startSeconds}`);
    }

    const safeChannels = targetChannels <= 1 ? 1 : (targetChannels >= 8 ? 8 : (targetChannels >= 6 ? 6 : 2));

    commands.push(
      '-i', url,
      '-map', '0:a:0',
      '-vn',
      '-t', `${maxDecodeSeconds}`,
      '-ac', `${safeChannels}`,
      '-ar', '48000',
      '-sample_fmt', 's16',
      '-f', 'wav',
      outputPath
    );

    const abortController = new FFAbortController();

    return new Promise<FfmpegAudioDecodeResult>((resolve) => {
      let settled = false;
      let outputText = '';

      const finish = (result: FfmpegAudioDecodeResult): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timeoutId);
        resolve(result);
      };

      const timeoutId = setTimeout(() => {
        abortController.abort(new Error('ffmpeg decode timeout'));
        const result: FfmpegAudioDecodeResult = {
          success: false,
          outputPath,
          errorMessage: `ffmpeg decode timeout: ${timeoutMs}ms`
        };
        finish(result);
      }, timeoutMs);

      FFmpeg.execute(commands, {
        outputCallback: (msg: string) => {
          outputText += msg;
        },
        signal: abortController.signal
      }).then(() => {
        const result: FfmpegAudioDecodeResult = {
          success: true,
          outputPath
        };
        finish(result);
      }).catch((e: Error) => {
        let message = e.message;
        if (outputText.length > 0) {
          const tail = outputText.length > 500 ? outputText.substring(outputText.length - 500) : outputText;
          message = `${message} | ffmpeg: ${tail}`;
        }
        const result: FfmpegAudioDecodeResult = {
          success: false,
          outputPath,
          errorMessage: message
        };
        finish(result);
      });
    });
  }
}
