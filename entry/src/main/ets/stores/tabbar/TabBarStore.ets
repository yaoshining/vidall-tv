import { StateStore, Reducer } from "@hadss/state_store";
import { TabBarModel } from "./TabBarModel";

export const TAB_BAR_STORE_ID = "tabBarStore";

const noopReducer: Reducer<TabBarModel> = (_s: TabBarModel): (() => Promise<void>) | null => null;

export const TabBarStore =
  StateStore.createStore<TabBarModel>(TAB_BAR_STORE_ID, new TabBarModel(), noopReducer, [])