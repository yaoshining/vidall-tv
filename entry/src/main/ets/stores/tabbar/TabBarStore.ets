import { StateStore, Store, Reducer } from "@hadss/state_store";
import { TabBarModel } from "./TabBarModel";

export const TAB_BAR_STORE_ID = "tabBarStore";

const noopReducer: Reducer<TabBarModel> = (_state: TabBarModel) => null;

export const TabBarStore: Store<TabBarModel> =
  StateStore.createStore<TabBarModel>(TAB_BAR_STORE_ID, new TabBarModel(), noopReducer, [])