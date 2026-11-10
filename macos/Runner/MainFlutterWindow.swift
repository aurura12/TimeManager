import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 菜单栏常驻时启动不显示主窗口；alpha 归零保证即使 nib 的
    // visibleAtLaunch 被系统忽略，也不会闪出一个完整窗口。
    self.alphaValue = 0
    super.awakeFromNib()
  }

  // 无边框的面板窗口默认不能成为 key，会收不到鼠标与滚动事件。
  override var canBecomeKey: Bool {
    return MenuBarController.shared.isPanelMode || super.canBecomeKey
  }

  override var canBecomeMain: Bool {
    return !MenuBarController.shared.isPanelMode && super.canBecomeMain
  }
}
