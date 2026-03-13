import { FFAbortController, FFmpeg } from './NativeFfmpegCompat';
import { fileIo } from '@kit.CoreFileKit';

export interface FfmpegFrameExtractResult {
  success: boolean;
  outputPath: string;
  errorMessage?: string;
}

export interface FfmpegFrameSequenceExtractResult {
  success: boolean;
  outputPaths: string[];
  frameTimesMs: number[];
  errorMessage?: string;
}

export interface FfmpegFrameExtractOptions {
  quality?: number;
  maxWidth?: number;
}

export class FfmpegVideoFrameUtil {
  private static formatFrameIndex(index: number): string {
    if (index >= 1000) {
      return `${index}`;
    }
    if (index >= 100) {
      return `0${index}`;
    }
    if (index >= 10) {
      return `00${index}`;
    }
    return `000${index}`;
  }

  static async extractFrameSequenceToJpeg(
    url: string,
    outputPrefixPath: string,
    headers?: Record<string, string>,
    startSeconds: number = 0,
    durationSeconds: number = 1.5,
    fps: number = 6,
    timeoutMs: number = 12000,
    options?: FfmpegFrameExtractOptions
  ): Promise<FfmpegFrameSequenceExtractResult> {
    let headersStr = '';
    if (headers) {
      const keys = Object.keys(headers);
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        headersStr += `${key}: ${headers[key]}\r\n`;
      }
    }

    const quality = options?.quality ?? 8;
    const maxWidth = options?.maxWidth ?? 640;

    const outputPattern = `${outputPrefixPath}_%04d.jpg`;
    const safeDuration = durationSeconds > 0 ? durationSeconds : 1.5;
    const safeFps = fps > 0 ? fps : 6;
    const expectedFrameCount = Math.max(1, Math.floor(safeDuration * safeFps));
    const abortController = new FFAbortController();

    const commandVariants: string[][] = [];

    const primary: string[] = [
      'ffmpeg',
      '-y',
      '-threads', '2',
      '-v', 'error'
    ];
    if (headersStr.length > 0) {
      primary.push('-headers', headersStr);
    }
    primary.push(
      '-noaccurate_seek',
      '-ss', `${startSeconds}`,
      '-i', url,
      '-an',
      '-sn',
      '-dn',
      '-frames:v', `${expectedFrameCount}`,
      '-vf', `fps=${safeFps},scale=${maxWidth}:-2:force_original_aspect_ratio=decrease`,
      '-q:v', `${quality}`,
      '-f', 'image2',
      outputPattern
    );
    commandVariants.push(primary);

    const fallback1: string[] = [
      'ffmpeg',
      '-y',
      '-threads', '2',
      '-v', 'error'
    ];
    if (headersStr.length > 0) {
      fallback1.push('-headers', headersStr);
    }
    fallback1.push(
      '-ss', `${startSeconds}`,
      '-i', url,
      '-an',
      '-sn',
      '-frames:v', `${expectedFrameCount}`,
      '-vf', `fps=${safeFps},scale=${maxWidth}:-2`,
      '-q:v', `${quality}`,
      '-f', 'image2',
      outputPattern
    );
    commandVariants.push(fallback1);

    const fallback2: string[] = [
      'ffmpeg',
      '-y',
      '-threads', '2',
      '-v', 'error'
    ];
    if (headersStr.length > 0) {
      fallback2.push('-headers', headersStr);
    }
    fallback2.push(
      '-ss', `${startSeconds}`,
      '-i', url,
      '-an',
      '-sn',
      '-frames:v', `${expectedFrameCount}`,
      '-vf', `scale=${maxWidth}:-2`,
      '-q:v', `${quality}`,
      '-f', 'image2',
      outputPattern
    );
    commandVariants.push(fallback2);

    return new Promise<FfmpegFrameSequenceExtractResult>((resolve) => {
      let settled = false;
      let lastErrorMessage = '';

      const finish = (result: FfmpegFrameSequenceExtractResult): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timeoutId);
        resolve(result);
      };

      const runAttempt = (attemptIndex: number): void => {
        if (attemptIndex >= commandVariants.length) {
          const failResult: FfmpegFrameSequenceExtractResult = {
            success: false,
            outputPaths: [],
            frameTimesMs: [],
            errorMessage: lastErrorMessage.length > 0 ? lastErrorMessage : 'frame sequence extract failed'
          };
          finish(failResult);
          return;
        }

        let outputText = '';
        FFmpeg.execute(commandVariants[attemptIndex], {
          outputCallback: (msg: string) => {
            outputText += msg;
          },
          signal: abortController.signal
        }).then(() => {
          const startMs = Math.floor(startSeconds * 1000);
          const frameStepMs = Math.max(1, Math.floor(1000 / safeFps));
          const collected = FfmpegVideoFrameUtil.collectExistingSequenceFrames(
            outputPrefixPath,
            expectedFrameCount,
            startMs,
            frameStepMs
          );

          if (collected.outputPaths.length > 0) {
            const okResult: FfmpegFrameSequenceExtractResult = {
              success: true,
              outputPaths: collected.outputPaths,
              frameTimesMs: collected.frameTimesMs
            };
            finish(okResult);
            return;
          }

          lastErrorMessage = `no frame output (attempt ${attemptIndex + 1})`;
          runAttempt(attemptIndex + 1);
        }).catch((err: Error) => {
          lastErrorMessage = outputText.length > 0 ? outputText : err.message;
          runAttempt(attemptIndex + 1);
        });
      };

      const timeoutId = setTimeout(() => {
        abortController.abort(new Error('ffmpeg frame sequence extract timeout'));
        const result: FfmpegFrameSequenceExtractResult = {
          success: false,
          outputPaths: [],
          frameTimesMs: [],
          errorMessage: `frame sequence extract timeout ${timeoutMs}ms`
        };
        finish(result);
      }, timeoutMs);

      runAttempt(0);
    });
  }

  private static collectExistingSequenceFrames(
    outputPrefixPath: string,
    expectedFrameCount: number,
    startMs: number,
    frameStepMs: number
  ): FfmpegFrameSequenceExtractResult {
    const paths: string[] = [];
    const frameTimes: number[] = [];
    for (let i = 1; i <= expectedFrameCount; i++) {
      const path = `${outputPrefixPath}_${FfmpegVideoFrameUtil.formatFrameIndex(i)}.jpg`;
      let exists = false;
      try {
        const stat = fileIo.statSync(path);
        if (stat.size > 0) {
          exists = true;
        }
      } catch (_) {
        exists = false;
      }
      if (exists) {
        paths.push(path);
        frameTimes.push(startMs + (i - 1) * frameStepMs);
      }
    }

    const result: FfmpegFrameSequenceExtractResult = {
      success: paths.length > 0,
      outputPaths: paths,
      frameTimesMs: frameTimes
    };
    return result;
  }

  static async extractFrameToJpeg(
    url: string,
    outputPath: string,
    headers?: Record<string, string>,
    seekSeconds: number = 1,
    timeoutMs: number = 15000,
    options?: FfmpegFrameExtractOptions
  ): Promise<FfmpegFrameExtractResult> {
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
      '-threads', '2',
      '-v', 'error'
    ];

    const quality = options?.quality ?? 4;
    const maxWidth = options?.maxWidth ?? 960;

    if (headersStr.length > 0) {
      commands.push('-headers', headersStr);
    }

    commands.push(
      '-noaccurate_seek',
      '-ss', `${seekSeconds}`,
      '-i', url,
      '-an',
      '-sn',
      '-dn',
      '-frames:v', '1',
      '-vf', `scale=${maxWidth}:-2:force_original_aspect_ratio=decrease`,
      '-q:v', `${quality}`,
      '-f', 'image2',
      outputPath
    );

    const abortController = new FFAbortController();

    return new Promise<FfmpegFrameExtractResult>((resolve) => {
      let settled = false;
      let outputText = '';

      const finish = (result: FfmpegFrameExtractResult): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timeoutId);
        resolve(result);
      };

      const timeoutId = setTimeout(() => {
        abortController.abort(new Error('ffmpeg frame extract timeout'));
        const result: FfmpegFrameExtractResult = {
          success: false,
          outputPath,
          errorMessage: `frame extract timeout ${timeoutMs}ms`
        };
        finish(result);
      }, timeoutMs);

      FFmpeg.execute(commands, {
        outputCallback: (msg: string) => {
          outputText += msg;
        },
        signal: abortController.signal
      }).then(() => {
        const result: FfmpegFrameExtractResult = {
          success: true,
          outputPath
        };
        finish(result);
      }).catch((err: Error) => {
        const msg = outputText.length > 0 ? outputText : err.message;
        const result: FfmpegFrameExtractResult = {
          success: false,
          outputPath,
          errorMessage: msg
        };
        finish(result);
      });
    });
  }
}
