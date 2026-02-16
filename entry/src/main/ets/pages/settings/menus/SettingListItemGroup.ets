import { ListGroupHeaderBuilder } from "./builders"

@ComponentV2
export struct SettingListItemGroup {
  @Require @Param title: string
  @BuilderParam contentBuilder: () => void

  build() {
    ListItemGroup({
      space: 10,
      header: ListGroupHeaderBuilder(this.title)
    }) {
      this.contentBuilder()
    }
  }
}