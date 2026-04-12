import { StateStore, Store, Reducer } from "@hadss/state_store";
import { SidebarModel } from "./SidebarModel";

export const SIDEBAR_STORE_ID = 'sidebarStore';

const noopReducer: Reducer<SidebarModel> = (_s: SidebarModel): (() => Promise<void>) | null => null;

export const SidebarStore: Store<SidebarModel> =
  StateStore.createStore(SIDEBAR_STORE_ID, new SidebarModel(), noopReducer, []);