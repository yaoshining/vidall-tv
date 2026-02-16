@Builder
export function ListGroupHeaderBuilder(title: string) {
  if (title) {
    Text(title)
      .fontSize($r('app.float.font_caption'))
      .margin({ bottom: 8 })
  }
}