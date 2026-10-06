import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var menuChannel: FlutterMethodChannel?
  private var selfUpdateHandler: SelfUpdateHandler?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "A股选股台"

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 原生菜单（Programmatic 构建替代 xib；PlatformMenuBar 在部分环境注册为空菜单）
    menuChannel = FlutterMethodChannel(
      name: "platform_menu",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    buildMainMenu()

    // 自更新：下载完成后由原生唤起 updater.sh 替换本 app 并重启
    selfUpdateHandler = SelfUpdateHandler()
    selfUpdateHandler?.register(with: flutterViewController.engine.binaryMessenger,
                                viewController: flutterViewController)

    super.awakeFromNib()
  }

  /// 应用菜单：关于 / 检查更新… ⌘U / 设置… ⌘, / 退出 ⌘Q；编辑菜单：剪切拷贝粘贴全选。
  private func buildMainMenu() {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    appItem.title = "A股选股台"
    let appMenu = NSMenu(title: "A股选股台")

    appMenu.addItem(NSMenuItem(
      title: "关于 A股选股台",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: ""))

    let check = NSMenuItem(
      title: "检查更新…", action: #selector(MainFlutterWindow.checkUpdate(_:)),
      keyEquivalent: "u")
    check.keyEquivalentModifierMask = [.command]
    check.target = self
    appMenu.addItem(check)

    let settings = NSMenuItem(
      title: "设置…", action: #selector(MainFlutterWindow.openSettings(_:)),
      keyEquivalent: ",")
    settings.keyEquivalentModifierMask = [.command]
    settings.target = self
    appMenu.addItem(settings)

    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(
      title: "退出 A股选股台",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"))
    appItem.submenu = appMenu
    mainMenu.addItem(appItem)

    let editItem = NSMenuItem()
    editItem.title = "编辑"
    let editMenu = NSMenu(title: "编辑")
    let cut = NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    let copy = NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    let paste = NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    let selectAll = NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    for item in [cut, copy, paste, selectAll] {
      item.keyEquivalentModifierMask = [.command]
      editMenu.addItem(item)
    }
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)

    NSApplication.shared.mainMenu = mainMenu
  }

  @objc private func openSettings(_ sender: AnyObject) {
    menuChannel?.invokeMethod("openSettings", arguments: nil)
  }

  @objc private func checkUpdate(_ sender: AnyObject) {
    menuChannel?.invokeMethod("checkUpdate", arguments: nil)
  }
}