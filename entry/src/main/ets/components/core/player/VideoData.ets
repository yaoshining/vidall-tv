import { VideoDataType } from "./Constants";

export interface VideoData {
  type: VideoDataType;
  videoSrc: string;
  httpHeader?: Record<string, string>;
  name?: ResourceStr;
  description?: ResourceStr;
  head?: Resource;
  caption?: string;
  index?: number;
  seekTime?:number;
  isMuted?:boolean;
}