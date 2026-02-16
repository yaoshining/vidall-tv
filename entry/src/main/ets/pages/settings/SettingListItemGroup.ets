import { ListGroupHeaderBuilder } from "./builders/ListGroupHeaderBuilder"

@ComponentV2
export struct SettingListItemGroup {
  @Param title: string = ''
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