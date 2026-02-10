import { StateStore } from "@hadss/state_store";
import { TabBarModel } from "./TabBarModel";

export const TAB_BAR_STORE_ID = "tabBarStore";

export const TabBarStore =
  StateStore.createStore<TabBarModel>(TAB_BAR_STORE_ID, new TabBarModel(), null, [])