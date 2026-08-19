import { StateStore, Store, Reducer } from "@hadss/state_store";
import { VideoServerModel } from "./VideoServerModel";

export const VIDEO_SERVER_STORE_ID = "videoServerStore"

const noopReducer: Reducer<VideoServerModel> = (_state: VideoServerModel) => null;

export const VideoServerStore: Store<VideoServerModel> =
  StateStore.createStore<VideoServerModel>(VIDEO_SERVER_STORE_ID, new VideoServerModel(), noopReducer, [])
