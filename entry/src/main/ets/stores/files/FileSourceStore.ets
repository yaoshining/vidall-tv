import { StateStore } from "@hadss/state_store";
import { FileSourceModel } from "./FileSourceModel";

export const FILE_SOURCE_STORE_ID = "fileSourceStore"

export const FileSourceStore =
  StateStore.createStore<FileSourceModel>(FILE_SOURCE_STORE_ID, new FileSourceModel(), null, [])