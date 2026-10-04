import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  @IBAction func openSettings(_ sender: Any) {
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else { return }
    FlutterMethodChannel(name: "time_manager/desktop_commands", binaryMessenger: controller.engine.binaryMessenger)
      .invokeMethod("openSettings", arguments: nil)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
