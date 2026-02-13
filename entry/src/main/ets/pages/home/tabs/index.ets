import { TabItem, TabItemCode } from "../../../stores/tabbar/TabBarModel";
import { FileSourceTab } from "./FileSourceTab";
import { MediaLibraryTab } from "./MediaLibraryTab";
import { VideoServerTab } from "./VideoServerTab";

@Builder
export function TabContentBuilder(tab: TabItem) {
  if (tab.code === TabItemCode.MEDIA_LIBRARY) {
    MediaLibraryTab({ tab })
  } else if (tab.code === TabItemCode.FILE_SOURCE) {
    FileSourceTab()
  } else if (tab.code === TabItemCode.VIDEO_SERVER) {
    VideoServerTab()
  }
}