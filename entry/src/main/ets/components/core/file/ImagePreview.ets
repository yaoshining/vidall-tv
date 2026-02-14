@CustomDialog
export struct ImagePreviewDialog {
  controller: CustomDialogController
  // 支持本地file://开头和http/https协议的网络图片
  @Require imageSrc: string
  title?: string = ''

  build() {
    Column() {
      // 图片容器
      Stack() {
        Image(this.imageSrc)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .onError((error) => {
            console.error('图片加载失败:', error.message)
          })

        // 标题栏
        if (this.title) {
          RelativeContainer() {
            Row() {
              Text(this.title)
                .fontSize($r('app.float.font_subtitle_1'))
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .textShadow({
                  radius: 3,
                  offsetX: 3,
                  offsetY: 3,
                  color: Color.Black
                })
            }
            .alignRules({
              top: { anchor: '__container__', align: VerticalAlign.Top },
              left: { anchor: '__container__', align: HorizontalAlign.Start }
            })
            .width('100%')
            .padding({ left: 20, right: 10, top: 10, bottom: 10 })
            .backgroundColor(Color.Transparent)
          }
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#33000000')
  }
}