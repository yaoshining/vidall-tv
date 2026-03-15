import { audio } from '@kit.AudioKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CommonConstants } from '../../../common/constants/CommonConstants';

const TAG = '[FfmpegAudioRendererSink]';

interface WavFormatInfo {
  sampleRate: number;
  channels: number;
  bitsPerSample: number;
  dataOffset: number;
  dataSize: number;
}

interface WavSegment {
  path: string;
  file: fileIo.File;
  format: WavFormatInfo;
  readOffset: number;
  dataEnd: number;
}

export class FfmpegAudioRendererSink {
  private static activeSink?: FfmpegAudioRendererSink;

  private renderer?: audio.AudioRenderer;
  private format?: WavFormatInfo;
  private segmentQueue: WavSegment[] = [];
  private currentSegment?: WavSegment;
  private inputCompleted: boolean = false;

  private renderBufferSize: number = 4096;
  private bytesPlayed: number = 0;
  private totalEnqueuedBytes: number = 0;
  private writingTaskRunning: boolean = false;
  private writingTaskPromise?: Promise<void>;
  private playing: boolean = false;

  durationMs: number = 0;

  async loadWav(wavPath: string): Promise<void> {
    await this.release();
    await this.enqueueWav(wavPath);

    if (!this.format) {
      throw new Error('初始化音频格式失败');
    }

    const rendererOptions: audio.AudioRendererOptions = {
      streamInfo: {
        samplingRate: this.mapSamplingRate(this.format.sampleRate),
        channels: this.mapChannels(this.format.channels),
        sampleFormat: this.mapSampleFormat(this.format.bitsPerSample),
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      },
      rendererInfo: {
        usage: audio.StreamUsage.STREAM_USAGE_MOVIE,
        rendererFlags: 0
      }
    };

    this.renderer = await audio.createAudioRenderer(rendererOptions);
    this.renderBufferSize = await this.renderer.getBufferSize();

    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `loadWav 成功: rate=${this.format.sampleRate} ch=${this.format.channels} bits=${this.format.bitsPerSample}` +
      ` queueMs=${this.getBufferedDurationMs()} buf=${this.renderBufferSize}`);
  }

  async enqueueWav(wavPath: string): Promise<void> {
    const file = fileIo.openSync(wavPath, fileIo.OpenMode.READ_ONLY);
    const stat = fileIo.statSync(wavPath);
    const fileSize = stat.size;
    const parsed = this.parseWavHeader(file, fileSize);

    if (!this.format) {
      this.format = parsed;
    } else {
      if (
        this.format.sampleRate !== parsed.sampleRate ||
        this.format.channels !== parsed.channels ||
        this.format.bitsPerSample !== parsed.bitsPerSample
      ) {
        fileIo.closeSync(file);
        throw new Error('WAV 参数不一致，无法连续拼接播放');
      }
    }

    const segment: WavSegment = {
      path: wavPath,
      file,
      format: parsed,
      readOffset: parsed.dataOffset,
      dataEnd: parsed.dataOffset + parsed.dataSize
    };
    this.segmentQueue.push(segment);
    this.totalEnqueuedBytes += parsed.dataSize;
    this.durationMs = this.calcDurationMs(parsed.dataSize, parsed.sampleRate, parsed.channels, parsed.bitsPerSample);
  }

  markInputCompleted(completed: boolean): void {
    this.inputCompleted = completed;
  }

  getBufferedDurationMs(): number {
    if (!this.format) {
      return 0;
    }
    const remainingBytes = this.totalEnqueuedBytes - this.bytesPlayed;
    const safeRemaining = remainingBytes > 0 ? remainingBytes : 0;
    return this.calcDurationMs(
      safeRemaining,
      this.format.sampleRate,
      this.format.channels,
      this.format.bitsPerSample
    );
  }

  async play(): Promise<void> {
    if (!this.renderer || !this.format) {
      throw new Error('AudioRendererSink 未初始化');
    }

    if (this.playing) {
      return;
    }

    if (FfmpegAudioRendererSink.activeSink && FfmpegAudioRendererSink.activeSink !== this) {
      await FfmpegAudioRendererSink.activeSink.forceStopForTakeover();
    }

    await this.renderer.start();
    this.playing = true;
    FfmpegAudioRendererSink.activeSink = this;

    if (!this.writingTaskRunning) {
      this.writingTaskPromise = this.runWriteLoop();
    }
  }

  async pause(): Promise<void> {
    if (!this.renderer) {
      return;
    }

    this.playing = false;
    if (FfmpegAudioRendererSink.activeSink === this) {
      FfmpegAudioRendererSink.activeSink = undefined;
    }
    try {
      await this.renderer.stop();
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `pause stop 异常: code=${err.code} msg=${err.message}`);
    }
  }

  async seek(timeMs: number): Promise<void> {
    if (!this.format) {
      return;
    }
    // 连续队列模式下，seek 由上层重建队列处理，这里保留空实现兼容接口。
    const safeTime = timeMs;
    if (safeTime < 0) {
      return;
    }
  }

  getCurrentPositionMs(): number {
    if (!this.format) {
      return 0;
    }
    const bytesPerFrame = this.format.channels * (this.format.bitsPerSample / 8);
    const byteRate = this.format.sampleRate * bytesPerFrame;
    if (byteRate <= 0) {
      return 0;
    }
    return Math.floor((this.bytesPlayed / byteRate) * 1000);
  }

  hasEnded(): boolean {
    return this.inputCompleted && this.currentSegment === undefined && this.segmentQueue.length === 0;
  }

  async release(): Promise<void> {
    this.playing = false;
    if (FfmpegAudioRendererSink.activeSink === this) {
      FfmpegAudioRendererSink.activeSink = undefined;
    }

    if (this.renderer) {
      try {
        await this.renderer.release();
      } catch (e) {
        const err = e as BusinessError;
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `renderer release 异常: code=${err.code} msg=${err.message}`);
      }
      this.renderer = undefined;
    }

    if (this.currentSegment) {
      this.safeCloseSegment(this.currentSegment);
      this.currentSegment = undefined;
    }
    while (this.segmentQueue.length > 0) {
      const seg = this.segmentQueue.shift();
      if (seg) {
        this.safeCloseSegment(seg);
      }
    }

    this.format = undefined;
    this.durationMs = 0;
    this.inputCompleted = false;
    this.bytesPlayed = 0;
    this.totalEnqueuedBytes = 0;
  }

  private async runWriteLoop(): Promise<void> {
    if (!this.renderer || !this.format) {
      return;
    }

    this.writingTaskRunning = true;

    try {
      while (this.renderer && this.playing) {
        if (!this.currentSegment) {
          const nextSeg = this.segmentQueue.shift();
          if (nextSeg) {
            this.currentSegment = nextSeg;
          } else {
            if (this.inputCompleted) {
              break;
            }
            await this.delay(20);
            continue;
          }
        }

        const seg = this.currentSegment;
        if (!seg) {
          continue;
        }

        const remaining = seg.dataEnd - seg.readOffset;
        if (remaining <= 0) {
          this.safeCloseSegment(seg);
          this.currentSegment = undefined;
          continue;
        }

        const chunkSize = remaining < this.renderBufferSize ? remaining : this.renderBufferSize;
        const buf = new ArrayBuffer(chunkSize);
        const readLen = fileIo.readSync(seg.file.fd, buf, {
          offset: seg.readOffset,
          length: chunkSize
        });

        if (readLen <= 0) {
          this.safeCloseSegment(seg);
          this.currentSegment = undefined;
          continue;
        }

        const writeBuf = readLen === chunkSize ? buf : buf.slice(0, readLen);
        await this.renderer.write(writeBuf);

        seg.readOffset += readLen;
        this.bytesPlayed += readLen;

        if (seg.readOffset >= seg.dataEnd) {
          this.safeCloseSegment(seg);
          this.currentSegment = undefined;
        }
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `runWriteLoop 异常: code=${err.code} msg=${err.message}`);
      throw new Error(`AudioRenderer 写入失败: ${err.message}`);
    } finally {
      this.writingTaskRunning = false;
    }
  }

  private safeCloseSegment(seg: WavSegment): void {
    try {
      fileIo.closeSync(seg.file);
    } catch (_) {
    }
    try {
      fileIo.unlinkSync(seg.path);
    } catch (_) {
    }
  }

  private async delay(ms: number): Promise<void> {
    await new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  private async forceStopForTakeover(): Promise<void> {
    this.playing = false;
    try {
      if (this.renderer) {
        await this.renderer.stop();
      }
    } catch (_) {
    }
    if (FfmpegAudioRendererSink.activeSink === this) {
      FfmpegAudioRendererSink.activeSink = undefined;
    }
  }

  private parseWavHeader(file: fileIo.File, fileSize: number): WavFormatInfo {
    if (fileSize < 44) {
      throw new Error('WAV 文件过小，无法解析头');
    }

    const scanLen = fileSize < 8192 ? fileSize : 8192;
    const head = new ArrayBuffer(scanLen);
    const readLen = fileIo.readSync(file.fd, head, { offset: 0, length: scanLen });
    if (readLen < 44) {
      throw new Error('WAV 头读取失败');
    }

    const view = new DataView(head);
    const riff = this.readAscii(view, 0, 4);
    const wave = this.readAscii(view, 8, 4);

    if (riff !== 'RIFF' || wave !== 'WAVE') {
      throw new Error('不是标准 WAV RIFF 文件');
    }

    let cursor = 12;
    let fmtFound = false;
    let dataFound = false;
    let sampleRate = 48000;
    let channels = 2;
    let bitsPerSample = 16;
    let dataOffset = 44;
    let dataSize = 0;

    while (cursor + 8 <= readLen) {
      const chunkId = this.readAscii(view, cursor, 4);
      const chunkSize = view.getUint32(cursor + 4, true);
      const chunkDataStart = cursor + 8;

      if (chunkId === 'fmt ' && chunkDataStart + 16 <= readLen) {
        const audioFormat = view.getUint16(chunkDataStart, true);
        if (audioFormat !== 1 && audioFormat !== 0xfffe) {
          throw new Error(`暂不支持该 WAV 编码格式: ${audioFormat}`);
        }
        channels = view.getUint16(chunkDataStart + 2, true);
        sampleRate = view.getUint32(chunkDataStart + 4, true);
        bitsPerSample = view.getUint16(chunkDataStart + 14, true);
        fmtFound = true;
      } else if (chunkId === 'data') {
        dataOffset = chunkDataStart;
        dataSize = chunkSize;
        dataFound = true;
        break;
      }

      const alignedSize = chunkSize % 2 === 0 ? chunkSize : chunkSize + 1;
      cursor = chunkDataStart + alignedSize;

      if (cursor >= readLen) {
        break;
      }
    }

    if (!fmtFound) {
      throw new Error('WAV 缺少 fmt chunk');
    }
    if (!dataFound) {
      throw new Error('WAV 缺少 data chunk');
    }

    const maxDataSize = fileSize - dataOffset;
    if (dataSize > maxDataSize) {
      dataSize = maxDataSize;
    }

    return {
      sampleRate,
      channels,
      bitsPerSample,
      dataOffset,
      dataSize
    };
  }

  private readAscii(view: DataView, offset: number, len: number): string {
    let result = '';
    for (let i = 0; i < len; i++) {
      result += String.fromCharCode(view.getUint8(offset + i));
    }
    return result;
  }

  private calcDurationMs(dataSize: number, sampleRate: number, channels: number, bitsPerSample: number): number {
    const bytesPerFrame = channels * (bitsPerSample / 8);
    const byteRate = sampleRate * bytesPerFrame;
    if (byteRate <= 0) {
      return 0;
    }
    return Math.floor((dataSize / byteRate) * 1000);
  }

  private mapSamplingRate(sampleRate: number): audio.AudioSamplingRate {
    if (sampleRate === 44100) {
      return audio.AudioSamplingRate.SAMPLE_RATE_44100;
    }
    if (sampleRate === 96000) {
      return audio.AudioSamplingRate.SAMPLE_RATE_96000;
    }
    return audio.AudioSamplingRate.SAMPLE_RATE_48000;
  }

  private mapChannels(channels: number): audio.AudioChannel {
    if (channels <= 1) {
      return audio.AudioChannel.CHANNEL_1;
    }
    if (channels === 2) {
      return audio.AudioChannel.CHANNEL_2;
    }
    // 对 5.1/7.1 等多声道做最佳努力透传；若设备/系统不支持会在 createAudioRenderer 抛错。
    return (channels as number) as audio.AudioChannel;
  }

  private mapSampleFormat(bitsPerSample: number): audio.AudioSampleFormat {
    if (bitsPerSample === 32) {
      return audio.AudioSampleFormat.SAMPLE_FORMAT_S32LE;
    }
    return audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE;
  }
}
