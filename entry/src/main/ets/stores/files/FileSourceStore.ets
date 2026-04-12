import { StateStore, Reducer } from "@hadss/state_store";
import { FileSourceModel } from "./FileSourceModel";

export const FILE_SOURCE_STORE_ID = "fileSourceStore"

const noopReducer: Reducer<FileSourceModel> = (_s: FileSourceModel): (() => Promise<void>) | null => null;

export const FileSourceStore =
  StateStore.createStore<FileSourceModel>(FILE_SOURCE_STORE_ID, new FileSourceModel(), noopReducer, [])