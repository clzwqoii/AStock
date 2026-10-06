import Cocoa
import FlutterMacOS

/// macOS 自更新通道：接收 Dart 侧的安装包路径，交给 updater.sh 替换本 app，
/// 然后立即退出自身，让脚本在 App 完全退出后完成替换与重启。
///
/// 为什么要「退出后再替换」：运行中的 Mach-O 被内核锁定，进程无法可靠地
/// 把自己换掉。必须在外部进程、且本进程已退出时动手——这也是 Sparkle 等
/// 成熟方案的做法。脚本逻辑见 macos/Runner/updater.sh。
class SelfUpdateHandler {
  static let channelName = "astock/self_update"

  /// updater.sh 在 flutter_assets 里的路径（pubspec.yaml 的 assets 声明）。
  private static let scriptAssetPath = "macos/Runner/updater.sh"

  private var channel: FlutterMethodChannel?

  func register(with messenger: FlutterBinaryMessenger, viewController: FlutterViewController) {
    channel = FlutterMethodChannel(name: SelfUpdateHandler.channelName,
                                   binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "install" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
            let zipPath = args["zip"] as? String else {
        result(FlutterError(code: "bad_args",
                            message: "缺少 zip 路径参数",
                            details: nil))
        return
      }
      self?.performUpdate(zipPath: zipPath, result: result)
    }
  }

  /// 启动 updater.sh 并退出。脚本后台接管替换 → 重启 → 清理。
  private func performUpdate(zipPath: String, result: @escaping FlutterResult) {
    guard FileManager.default.fileExists(atPath: zipPath) else {
      result(FlutterError(code: "zip_missing",
                          message: "安装包不存在: \(zipPath)",
                          details: nil))
      return
    }

    // 本 app 的真实路径（就是替换目标）
    let bundlePath = Bundle.main.bundlePath
    guard bundlePath.hasSuffix(".app") else {
      result(FlutterError(code: "bad_target",
                          message: "无法确定当前 app 路径: \(bundlePath)",
                          details: nil))
      return
    }

    guard let scriptURL = locateScript() else {
      result(FlutterError(code: "script_missing",
                          message: "bundle 内找不到 updater.sh",
                          details: nil))
      return
    }

    // flutter_assets 里的脚本不可直接执行（无执行位、且属主只读），拷到临时目录。
    // 用 URL 版 copyItem：String 版在 Swift 里被桥接到 NSString 路径，类型不匹配。
    let dstScript = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("astock_updater.sh")
    do {
      if FileManager.default.fileExists(atPath: dstScript.path) {
        try FileManager.default.removeItem(at: dstScript)
      }
      try FileManager.default.copyItem(at: scriptURL, to: dstScript)
      try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                            ofItemAtPath: dstScript.path)
    } catch {
      result(FlutterError(code: "copy_failed",
                          message: "复制更新脚本失败: \(error.localizedDescription)",
                          details: nil))
      return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
      dstScript.path,
      "--zip", zipPath,
      "--target", bundlePath,
    ]
    // 脱离本进程的输出，重启后日志进 Console.app 的 astock-updater
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      result(FlutterError(code: "spawn_failed",
                          message: "启动更新脚本失败: \(error.localizedDescription)",
                          details: nil))
      return
    }

    // 让脚本先活过本进程退出，再退出自己。0.3s 足够 process.run() 完成 fork。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      NSApp.terminate(nil)
      // terminate 是异步的；万一没走成，强制退出（脚本已在后台接管）
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        exit(0)
      }
    }
    result(nil)
  }

  /// 在 bundle 里找 updater.sh。
  ///
  /// 实测布局（macOS + asset 声明 `macos/Runner/updater.sh`）：
  /// `App.framework/Versions/A/Resources/flutter_assets/macos/Runner/updater.sh`。
  /// Flutter 把资源塞进 App.framework，而 macOS 上 `Bundle.main` 就是它，
  /// 所以 `Bundle.main.resourceURL` 已经指向 `.../App.framework/Versions/A/Resources`。
  /// 下面按这个顺序找，并对 Debug/Dart-only 的差异留兜底。
  private func locateScript() -> URL? {
    var candidates: [URL] = []

    func add(_ url: URL?) { if let url { candidates.append(url) } }

    // 1) flutter_assets 下的声明路径（Release/Debug 通用）
    if let res = Bundle.main.resourceURL {
      add(res.appendingPathComponent("flutter_assets")
        .appendingPathComponent(Self.selfUpdateAssetDir)
        .appendingPathComponent("updater.sh"))
      add(res.appendingPathComponent(Self.selfUpdateAssetDir)
        .appendingPathComponent("updater.sh"))
    }
    add(Bundle.main.url(forResource: "updater", withExtension: "sh"))

    // 2) 若以上都没中，退回 .app 内常见位置
    let appURL = URL(fileURLWithPath: Bundle.main.bundlePath)
    if appURL.path.hasSuffix(".framework") {
      add(appURL.deletingLastPathComponent()
        .appendingPathComponent("Resources/flutter_assets")
        .appendingPathComponent(Self.selfUpdateAssetDir)
        .appendingPathComponent("updater.sh"))
    } else {
      for sub in ["Contents/MacOS", "Contents/Resources", "Contents/Resources/flutter_assets"] {
        add(appURL.appendingPathComponent(sub)
          .appendingPathComponent(Self.selfUpdateAssetDir)
          .appendingPathComponent("updater.sh"))
      }
    }

    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// 与 pubspec.yaml 的 assets 声明保持一致。
  private static let selfUpdateAssetDir = "macos/Runner"
}
