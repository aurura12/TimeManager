import Cocoa
import FlutterMacOS
import ServiceManagement

@main
class AppDelegate: FlutterAppDelegate {
  @IBAction func openSettings(_ sender: Any) {
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else { return }
    FlutterMethodChannel(name: "time_manager/desktop_commands", binaryMessenger: controller.engine.binaryMessenger)
      .invokeMethod("openSettings", arguments: nil)
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // FlutterAppDelegate（macOS）没有实现 applicationDidFinishLaunching，
    // 调 super 会触发 doesNotRecognizeSelector 并把后续逻辑整段跳过。
    guard let window = mainFlutterWindow else { return }
    // 窗口位置恢复交给菜单栏控制器统一裁决，避免系统恢复出一个
    // 「菜单栏常驻模式下不该出现」的主窗口。
    window.isRestorable = false
    MenuBarController.shared.start(
      window: window,
      messenger: (window.contentViewController as? FlutterViewController)?.engine.binaryMessenger,
      openSettings: { [weak self] in self?.openSettings(NSApplication.shared) }
    )
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // 菜单栏常驻时关窗只隐藏，进程继续待命。
    return !MenuBarController.shared.isEnabled
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    guard MenuBarController.shared.isEnabled else { return true }
    MenuBarController.shared.showMainWindow()
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

// MARK: - 菜单栏常驻控制器

/// 菜单栏常驻的单一状态机：同一个 NSWindow 在「主窗口 / 紧凑面板」两种
/// 形态间切换，Dart 侧通过 `time_manager/menu_bar` 通道读写状态。
///
/// 全部实现放在本文件里是刻意的：工程使用老式 pbxproj（objectVersion 54），
/// 手工添加 Swift 文件引用容易把工程改坏，而纯原生实现又不需要额外依赖。
final class MenuBarController: NSObject, NSWindowDelegate {
  static let shared = MenuBarController()

  private enum Keys {
    /// 只作为「下一次启动要不要显示 Dock 图标」的镜像键；
    /// 真正的用户偏好在 Dart 侧（`app_menu_bar_mode_v1`）。
    static let enabled = "tm.menuBar.enabled"
  }

  private enum Metrics {
    static let panelSize = NSSize(width: 400, height: 720)
    static let anchorGap: CGFloat = 6
    static let screenMargin: CGFloat = 8
    static let cornerRadius: CGFloat = 16
    static let toggleGuard: TimeInterval = 0.25
    static let startupSafetyDelay: TimeInterval = 15
  }

  private struct SavedWindowState {
    let styleMask: NSWindow.StyleMask
    let frame: NSRect
    let level: NSWindow.Level
    let collectionBehavior: NSWindow.CollectionBehavior
    let titleVisibility: NSWindow.TitleVisibility
    let titlebarAppearsTransparent: Bool
    let isOpaque: Bool
    let backgroundColor: NSColor?
    let hasShadow: Bool
    let isMovable: Bool
    let isMovableByWindowBackground: Bool
    let isExcludedFromWindowsMenu: Bool
    let tabbingMode: NSWindow.TabbingMode

    init(_ window: NSWindow) {
      styleMask = window.styleMask
      frame = window.frame
      level = window.level
      collectionBehavior = window.collectionBehavior
      titleVisibility = window.titleVisibility
      titlebarAppearsTransparent = window.titlebarAppearsTransparent
      isOpaque = window.isOpaque
      backgroundColor = window.backgroundColor
      hasShadow = window.hasShadow
      isMovable = window.isMovable
      isMovableByWindowBackground = window.isMovableByWindowBackground
      isExcludedFromWindowsMenu = window.isExcludedFromWindowsMenu
      tabbingMode = window.tabbingMode
    }
  }

  private(set) var isEnabled: Bool
  private(set) var isPanelMode = false
  private(set) var isPanelVisible = false
  private(set) var isMainWindowVisible = false

  private weak var window: NSWindow?
  private var statusItem: NSStatusItem?
  private var channel: FlutterMethodChannel?
  private var savedWindowState: SavedWindowState?
  private var openSettingsHandler: (() -> Void)?
  private var suppressAutoHide = false
  private var lastPanelClosedAt = Date.distantPast
  private var didReceiveDartState = false
  private var startupSafetyTimer: Timer?
  private let launchAtLogin = LaunchAtLogin()

  private override init() {
    let stored = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool
    isEnabled = stored ?? true
    if ProcessInfo.processInfo.environment["TM_DISABLE_MENU_BAR"] == "1" {
      isEnabled = false
    }
    super.init()
  }

  // MARK: 启动

  func start(
    window: NSWindow,
    messenger: FlutterBinaryMessenger?,
    openSettings: @escaping () -> Void
  ) {
    self.window = window
    openSettingsHandler = openSettings
    window.delegate = self

    if let messenger {
      let channel = FlutterMethodChannel(name: "time_manager/menu_bar", binaryMessenger: messenger)
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handle(call, result: result)
      }
      self.channel = channel
    }

    if isEnabled {
      isMainWindowVisible = false
      createStatusItem()
      // Flutter 只有在窗口进入屏幕后才会启动 Dart isolate；完全 orderOut
      // 会让 Dart 一直不跑，直到安全网把窗口显示出来。这里用 alpha=0
      // 把窗口挂到屏幕上（不可见、不抢焦点），等 Dart configure 到达后
      // 再 orderOut。
      window.alphaValue = 0
      window.orderFront(nil)
      scheduleStartupSafetyNet()
    } else {
      isMainWindowVisible = true
      showMainWindow()
    }
  }

  /// Dart 侧初始化失败或没起来时，不能让用户只看到图标却什么都点不开。
  private func scheduleStartupSafetyNet() {
    startupSafetyTimer?.invalidate()
    startupSafetyTimer = Timer.scheduledTimer(
      withTimeInterval: Metrics.startupSafetyDelay,
      repeats: false
    ) { [weak self] _ in
      guard let self, !self.didReceiveDartState, self.isEnabled else { return }
      NSLog("[时间块] 菜单栏模式等待 Dart 初始化超时，回退为显示主窗口")
      self.isEnabled = false
      UserDefaults.standard.set(false, forKey: Keys.enabled)
      self.removeStatusItem()
      self.showMainWindow()
    }
  }

  // MARK: 状态栏

  private func createStatusItem() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      let image = NSImage(systemSymbolName: "clock", accessibilityDescription: "时间块")
      image?.isTemplate = true
      image?.size = NSSize(width: 18, height: 18)
      button.image = image
      button.toolTip = "时间块"
      button.target = self
      button.action = #selector(statusItemClicked(_:))
      // 右键由自己处理，不交给系统菜单。
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    statusItem = item
  }

  private func removeStatusItem() {
    if let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
    }
    statusItem = nil
  }

  @objc private func statusItemClicked(_ sender: Any?) {
    let event = NSApp.currentEvent
    let isSecondaryClick = event?.type == .rightMouseUp ||
      event?.modifierFlags.contains(.control) == true
    if isSecondaryClick {
      showStatusMenu()
      return
    }
    if isPanelVisible {
      hidePanel()
      return
    }
    // 点图标时面板已因 resignKey 收起，这一次点击只当作「关闭」。
    guard Date().timeIntervalSince(lastPanelClosedAt) > Metrics.toggleGuard else { return }
    showPanel()
  }

  private func showStatusMenu() {
    guard let statusItem else { return }
    let menu = NSMenu()
    let open = NSMenuItem(
      title: "打开主窗口",
      action: #selector(menuOpenMainWindow),
      keyEquivalent: ""
    )
    open.target = self
    menu.addItem(open)
    let settings = NSMenuItem(
      title: "设置…",
      action: #selector(menuOpenSettings),
      keyEquivalent: ""
    )
    settings.target = self
    menu.addItem(settings)
    menu.addItem(.separator())
    let quit = NSMenuItem(
      title: "退出时间块",
      action: #selector(menuQuit),
      keyEquivalent: "q"
    )
    quit.target = self
    menu.addItem(quit)

    hidePanel()
    suppressAutoHide = true
    defer { suppressAutoHide = false }
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  @objc private func menuOpenMainWindow() {
    showMainWindow()
  }

  @objc private func menuOpenSettings() {
    showMainWindow()
    openSettingsHandler?()
  }

  @objc private func menuQuit() {
    requestQuit()
  }

  private func requestQuit() {
    guard let channel else {
      NSApp.terminate(nil)
      return
    }
    channel.invokeMethod("quitRequested", arguments: nil)
    // Dart 负责落盘（切后台写盘 + 补推最多约 5 秒）；8 秒没回就强退，
    // 不能为了等网络把用户卡在退不掉的状态。
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
      NSApp.terminate(nil)
    }
  }

  // MARK: 面板形态

  func showPanel() {
    guard isEnabled, let window else { return }
    if isMainWindowVisible {
      hideMainWindow()
    }
    enterPanelModeIfNeeded()
    window.setFrame(
      NSRect(origin: panelOrigin(for: Metrics.panelSize), size: Metrics.panelSize),
      display: true
    )
    window.alphaValue = 1
    activateApp()
    window.makeKeyAndOrderFront(nil)
    isPanelVisible = true
    notifyDart()
  }

  func hidePanel() {
    guard isPanelVisible else { return }
    isPanelVisible = false
    lastPanelClosedAt = Date()
    window?.orderOut(nil)
    notifyDart()
  }

  private func enterPanelModeIfNeeded() {
    guard !isPanelMode, let window else { return }
    savedWindowState = SavedWindowState(window)
    isPanelMode = true

    window.styleMask = [.borderless]
    window.titleVisibility = .hidden
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.level = .statusBar
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    window.isMovable = false
    window.isMovableByWindowBackground = false
    window.isExcludedFromWindowsMenu = true
    window.tabbingMode = .disallowed
    window.contentView?.wantsLayer = true
    window.contentView?.layer?.cornerRadius = Metrics.cornerRadius
    window.contentView?.layer?.masksToBounds = true
    window.invalidateShadow()
  }

  private func exitPanelMode() {
    guard let window, let saved = savedWindowState else { return }
    window.orderOut(nil)
    window.styleMask = saved.styleMask
    window.setFrame(saved.frame, display: true)
    window.level = saved.level
    window.collectionBehavior = saved.collectionBehavior
    window.isOpaque = saved.isOpaque
    window.backgroundColor = saved.backgroundColor
    window.hasShadow = saved.hasShadow
    window.isMovable = saved.isMovable
    window.isMovableByWindowBackground = saved.isMovableByWindowBackground
    window.isExcludedFromWindowsMenu = saved.isExcludedFromWindowsMenu
    window.tabbingMode = saved.tabbingMode
    window.titleVisibility = saved.titleVisibility
    window.titlebarAppearsTransparent = saved.titlebarAppearsTransparent
    window.contentView?.layer?.cornerRadius = 0
    window.contentView?.layer?.masksToBounds = false
    window.invalidateShadow()
    savedWindowState = nil
    isPanelMode = false
  }

  private func panelOrigin(for size: NSSize) -> NSPoint {
    guard let button = statusItem?.button, let barWindow = button.window else {
      return NSPoint(x: 0, y: 0)
    }
    let anchor = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
    let screen = barWindow.screen ?? NSScreen.main
    let visible = screen?.visibleFrame ?? .zero
    let margin = Metrics.screenMargin
    var x = anchor.midX - size.width / 2
    var y = anchor.minY - size.height - Metrics.anchorGap
    x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)
    y = min(max(y, visible.minY + margin), visible.maxY - size.height - margin)
    return NSPoint(x: x.rounded(.down), y: y.rounded(.down))
  }

  // MARK: 主窗口

  func showMainWindow() {
    guard let window else { return }
    hidePanel()
    exitPanelMode()
    isMainWindowVisible = true
    window.alphaValue = 1
    activateApp()
    window.makeKeyAndOrderFront(nil)
    notifyDart()
  }

  func hideMainWindow() {
    guard let window else { return }
    window.orderOut(nil)
    isMainWindowVisible = false
    notifyDart()
  }

  private func activateApp() {
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  // MARK: NSWindowDelegate

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard isEnabled else { return true }
    hidePanel()
    hideMainWindow()
    return false
  }

  func windowDidResignKey(_ notification: Notification) {
    guard isPanelVisible, !suppressAutoHide else { return }
    hidePanel()
  }

  // MARK: Dart 通道

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    didReceiveDartState = true
    switch call.method {
    case "getState":
      result(stateMap())
    case "configure":
      let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? true
      configure(enabled: enabled)
      result(stateMap())
    case "showPanel":
      showPanel()
      result(stateMap())
    case "hidePanel":
      hidePanel()
      result(stateMap())
    case "showMainWindow":
      showMainWindow()
      result(stateMap())
    case "hideMainWindow":
      hideMainWindow()
      result(stateMap())
    case "openSettings":
      showMainWindow()
      openSettingsHandler?()
      result(stateMap())
    case "setLaunchAtLogin":
      let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
      do {
        try launchAtLogin.setEnabled(enabled)
        result(stateMap())
      } catch {
        result(
          FlutterError(
            code: "launch_at_login_failed",
            message: error.localizedDescription,
            details: ["status": launchAtLogin.rawStatus]
          )
        )
      }
    case "openLoginItemsSettings":
      launchAtLogin.openSystemSettings()
      result(nil)
    case "quit":
      NSApp.terminate(nil)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func configure(enabled: Bool) {
    let target = ProcessInfo.processInfo.environment["TM_DISABLE_MENU_BAR"] == "1" ? false : enabled
    isEnabled = target
    UserDefaults.standard.set(target, forKey: Keys.enabled)
    startupSafetyTimer?.invalidate()
    startupSafetyTimer = nil

    if target {
      hidePanel()
      exitPanelMode()
      createStatusItem()
      hideMainWindow()
    } else {
      removeStatusItem()
      hidePanel()
      exitPanelMode()
      showMainWindow()
    }
    notifyDart()
  }

  private func stateMap() -> [String: Any] {
    var map: [String: Any] = [
      "enabled": isEnabled,
      "panelVisible": isPanelVisible,
      "mainWindowVisible": isMainWindowVisible,
      "supported": true,
    ]
    map.merge(launchAtLogin.stateMap()) { _, new in new }
    return map
  }

  private func notifyDart() {
    channel?.invokeMethod("stateChanged", arguments: stateMap())
  }
}

// MARK: - 登录项

private struct LaunchAtLogin {
  var available: Bool {
    if #available(macOS 13.0, *) { return true }
    return false
  }

  var rawStatus: Int {
    if #available(macOS 13.0, *) { return Int(SMAppService.mainApp.status.rawValue) }
    return -1
  }

  func stateMap() -> [String: Any] {
    guard #available(macOS 13.0, *) else {
      return [
        "launchAtLoginAvailable": false,
        "launchAtLogin": false,
        "launchAtLoginNeedsApproval": false,
      ]
    }
    let status = SMAppService.mainApp.status
    return [
      "launchAtLoginAvailable": true,
      "launchAtLogin": status == .enabled,
      "launchAtLoginNeedsApproval": status == .requiresApproval,
    ]
  }

  func setEnabled(_ enabled: Bool) throws {
    guard #available(macOS 13.0, *) else {
      throw NSError(
        domain: "TimeManager.LaunchAtLogin",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "需要 macOS 13 或更高版本"]
      )
    }
    let service = SMAppService.mainApp
    if enabled {
      if service.status != .enabled {
        try service.register()
      }
    } else if service.status == .enabled || service.status == .requiresApproval {
      try service.unregister()
    }
  }

  func openSystemSettings() {
    if #available(macOS 13.0, *) {
      SMAppService.openSystemSettingsLoginItems()
    }
  }
}