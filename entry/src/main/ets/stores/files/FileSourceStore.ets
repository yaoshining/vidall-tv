import { StateStore, Store, Reducer } from "@hadss/state_store";
import { FileSourceModel } from "./FileSourceModel";

export const FILE_SOURCE_STORE_ID = "fileSourceStore"

const noopReducer: Reducer<FileSourceModel> = (_state: FileSourceModel) => null;

export const FileSourceStore: Store<FileSourceModel> =
  StateStore.createStore<FileSourceModel>(FILE_SOURCE_STORE_ID, new FileSourceModel(), noopReducer, [])