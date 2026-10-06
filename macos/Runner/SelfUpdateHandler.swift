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
  /// ## 实测结论（别再猜 `Bundle.main` 是什么）
  ///
  /// 在 app 进程里实测（把探针塞进 ASTock.app/Contents/MacOS 跑出来的）：
  /// ```
  /// Bundle.main.bundlePath  = /Applications/ASTock.app          ← 是 .app，不是 App.framework
  /// Bundle.main.resourceURL = .../ASTock.app/Contents/Resources  ← 脚本不在这里
  /// ```
  /// Flutter 把 asset 塞进 **App.framework**，所以脚本的真实位置是：
  /// ```
  /// ASTock.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/macos/Runner/updater.sh
  /// ```
  /// 之前按「Bundle.main 就是 App.framework」去找，候选路径全落在
  /// Contents/Resources 下，于是每个候选都不存在 → script_missing。
  private func locateScript() -> URL? {
    var candidates: [URL] = []

    func add(_ url: URL?) { if let url { candidates.append(url) } }
    func assetIn(_ base: URL, _ sub: String) {
      add(base.appendingPathComponent(sub)
        .appendingPathComponent(Self.selfUpdateAssetDir)
        .appendingPathComponent("updater.sh"))
    }

    let appURL = URL(fileURLWithPath: Bundle.main.bundlePath)
    let contents = appURL.appendingPathComponent("Contents")

    // 1) 真实布局：脚本在 App.framework 的 flutter_assets 下（Release/Debug 都一样）
    let frameworks = contents.appendingPathComponent("Frameworks")
    if let fw = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) {
      for name in fw where name.hasSuffix("App.framework") || name.hasSuffix(".framework") {
        let res = frameworks.appendingPathComponent(name)
          .appendingPathComponent("Versions/Current/Resources")
        assetIn(res, "flutter_assets")
        assetIn(res, "")
      }
    }

    // 2) Bundle.main 自身（Debug 或将来布局变化时的兜底）
    if let res = Bundle.main.resourceURL {
      assetIn(res, "flutter_assets")
      assetIn(res, "")
    }

    // 3) .app 内常见位置
    for sub in ["Contents/MacOS", "Contents/Resources",
                "Contents/Resources/flutter_assets"] {
      assetIn(appURL.appendingPathComponent(sub), "")
    }
    add(Bundle.main.url(forResource: "updater", withExtension: "sh"))

    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// 与 pubspec.yaml 的 assets 声明保持一致。
  private static let selfUpdateAssetDir = "macos/Runner"
}
