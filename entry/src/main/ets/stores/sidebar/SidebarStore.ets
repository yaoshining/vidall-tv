import { StateStore, Store } from "@hadss/state_store";
import { SidebarModel } from "./SidebarModel";

export const SIDEBAR_STORE_ID = 'sidebarStore';

export const SidebarStore: Store<SidebarModel> =
  StateStore.createStore(SIDEBAR_STORE_ID, new SidebarModel(), null, []);