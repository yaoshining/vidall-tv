export interface DialogHandle {
  open(): void;
  close(): void;
}

export class ImagePreviewSessionController {
  private activeDialog?: DialogHandle;

  openDialog(dialog: DialogHandle): void {
    this.closeActiveDialog();
    this.activeDialog = dialog;
    dialog.open();
  }

  closeActiveDialog(): boolean {
    if (this.activeDialog === undefined) {
      return false;
    }
    const dialog = this.activeDialog;
    this.activeDialog = undefined;
    dialog.close();
    return true;
  }

  handleBack(): boolean {
    return this.closeActiveDialog();
  }
}
