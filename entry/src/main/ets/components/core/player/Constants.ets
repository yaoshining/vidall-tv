import { emitter } from "@kit.BasicServicesKit";

export enum AVPlayerState {
  /**
   * Idle state of avPlayer.
   */
  IDLE = 'idle',

  /**
   * Initialized state of avPlayer.
   */
  INITIALIZED = 'initialized',

  /**
   * Prepared state of avPlayer.
   */
  PREPARED = 'prepared',

  /**
   * Playing state of avPlayer.
   */
  PLAYING = 'playing',

  /**
   * Pause state of avPlayer.
   */
  PAUSED = 'paused',

  /**
   * Completed state of avPlayer.
   */
  COMPLETED = 'completed',

  /**
   * Stopped state of avPlayer.
   */
  STOPPED = 'stopped',

  /**
   * Release state of avPlayer.
   */
  RELEASED = 'released',

  /**
   * Error state of avPlayer.
   */
  ERROR = 'error',
  UNDEFINED = 'undefined'
}

export enum VideoDataType {
  URL = 1,
  FILE_URI = 2
}

export class PlayerEvents {
  static readonly IDLE: emitter.InnerEvent = {
    eventId: 1,
    priority: emitter.EventPriority.HIGH
  };
  static readonly INITIALIZED: emitter.InnerEvent = {
    eventId: 2,
    priority: emitter.EventPriority.HIGH
  };
  static readonly PREPARED: emitter.InnerEvent = {
    eventId: 3,
    priority: emitter.EventPriority.HIGH
  };
  static readonly PLAYING: emitter.InnerEvent = {
    eventId: 4,
    priority: emitter.EventPriority.HIGH
  };
  static readonly COMPLETED: emitter.InnerEvent = {
    eventId: 5,
    priority: emitter.EventPriority.HIGH
  };
  static readonly PAUSED: emitter.InnerEvent = {
    eventId: 6,
    priority: emitter.EventPriority.HIGH
  };
  static readonly STOPPED: emitter.InnerEvent = {
    eventId: 7,
    priority: emitter.EventPriority.HIGH
  };
  static readonly innerEventFalse: emitter.InnerEvent = {
    eventId: 11,
    priority: emitter.EventPriority.HIGH
  };
  static readonly innerEventTrue: emitter.InnerEvent = {
    eventId: 12,
    priority: emitter.EventPriority.HIGH
  };
  static readonly innerEventWH: emitter.InnerEvent = {
    eventId: 13,
    priority: emitter.EventPriority.HIGH
  };
}
