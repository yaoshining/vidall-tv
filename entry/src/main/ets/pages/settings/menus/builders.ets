@Builder
export function ListGroupHeaderBuilder(title: string) {
  Text(title)
    .fontSize($r('app.float.font_caption'))
    .margin({ bottom: 8 })
}