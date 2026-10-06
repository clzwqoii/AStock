/// 设置页：token 配置（保存到 ~/.stock/.env，App 与命令行共用）+ 主题色 + 数据同步。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../app_logic.dart' show UpdateInfo, checkForUpdate, kAppVersion;
import '../config.dart';
import '../data/sync_service.dart';
import '../net_diag.dart';
import '../update_download.dart'
    show
        assetUrlFor,
        downloadUpdatePackage,
        installUpdatePackage,
        selfUpdateRunnerFor,
        supportsInAppSelfUpdate,
        DownloadPackageFn,
        InstallPackageFn,
        SelfUpdateRunner;
import 'colors.dart';
import 'onboarding.dart' show LaunchUrlFn, defaultLaunchUrl, kTushareRegisterUrl;
import 'screening_page.dart' show LoadingDialog;

typedef RunSyncFn = Future<SyncResult> Function({
  required String dbPath,
  required String token,
  void Function(String msg)? onProgress,
});

/// 写配置文件的端口；测试注入内存实现以避开真实 IO。
typedef WriteConfigFn = Future<void> Function(String path, String content);

/// 检查更新端口；测试注入假实现，生产用 [checkForUpdate]。
typedef CheckUpdateFn = Future<UpdateInfo?> Function();

/// 检查更新流程的全部可注入依赖，**两处入口共用同一份**。
///
/// 为什么要有这个类型：macOS 菜单栏（⌘U）与设置页按钮是两处入口，历史上
/// 参数集不同——设置页传了 `selfUpdateFn`，菜单栏没传，只靠
/// `_downloadAndInstall` 内部的兜底 `selfUpdate ?? selfUpdateRunnerFor()`
/// 才碰巧没出问题。兜底是脆弱的：默认实现一变，两处就静默分叉，且没有
/// 任何测试会失败。收敛到单一构造点后，漏传字段会在编译期暴露。
class UpdateDeps {
  const UpdateDeps({
    this.checkFn,
    this.downloadFn,
    this.installFn,
    this.selfUpdateFn,
    this.launchUrl,
  });

  /// 自更新安装器。**默认为空是有意的**——必须在构造时显式给出，
  /// 否则「漏传」与「故意不用」无法区分，入口分叉的防线就没了。
  final SelfUpdateRunner? selfUpdateFn;

  final CheckUpdateFn? checkFn;
  final DownloadPackageFn? downloadFn;
  final InstallPackageFn? installFn;
  final LaunchUrlFn? launchUrl;
}

/// 检查更新：先加载弹框，完成后替换为结果弹框（macOS 菜单与设置页共用）。
/// 有本平台直链时支持应用内下载（进度条）并自动触发安装；否则「打开下载页」兜底。
Future<void> showCheckUpdateDialog(
  BuildContext context, {
  CheckUpdateFn? checkFn,
  DownloadPackageFn? downloadFn,
  InstallPackageFn? installFn,
  SelfUpdateRunner? selfUpdateFn,
  LaunchUrlFn? launchUrl,
}) async {
  // 入口收敛点：两处入口都构造 [UpdateDeps] 再走这里，参数集不可能分叉。
  return showCheckUpdate(context,
      deps: UpdateDeps(
        checkFn: checkFn,
        downloadFn: downloadFn,
        installFn: installFn,
        selfUpdateFn: selfUpdateFn,
        launchUrl: launchUrl,
      ));
}

/// 检查更新的唯一实现。[deps] 携带全部可注入依赖。
Future<void> showCheckUpdate(BuildContext context, {required UpdateDeps deps}) async {
  final checkFn = deps.checkFn;
  final downloadFn = deps.downloadFn;
  final installFn = deps.installFn;
  final selfUpdateFn = deps.selfUpdateFn;
  final launchUrl = deps.launchUrl;
  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const LoadingDialog(title: '正在检查更新', subtitle: 'Gitee / GitHub 多源自动分流'),
  );
  UpdateInfo? info;
  Object? error;
  try {
    info = await (checkFn ?? checkForUpdate)();
  } catch (e) {
    error = e;
  }
  navigator.pop();
  if (!context.mounted) return;
  if (error != null) {
    await _resultDialog(context, '检查失败', '无法连接更新服务器：$error');
    return;
  }
  if (info == null) {
    await _resultDialog(context, '已是最新版本', '当前版本 $kAppVersion 已是最新。');
    return;
  }
  final next = info; // 非空局部：闭包里要用，闭包不继承可空局部变量的提升
  final selfUpdating = supportsInAppSelfUpdate(); // macOS：替换+重启，无需手工
  await showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('发现新版本'),
      content: Text(
          '最新版本 ${next.latestVersion}\n下载地址：\n${next.downloadUrl}',
          style: const TextStyle(fontSize: 13)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        if (assetUrlFor(next) != null)
          FilledButton(
            onPressed: () => _downloadAndInstall(
              context,
              next,
              downloadFn: downloadFn,
              installFn: installFn,
              selfUpdate: selfUpdateFn,
            ),
            child: Text(selfUpdating ? '下载并自动安装' : '下载并安装'),
          )
        else
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              (launchUrl ?? defaultLaunchUrl)(Uri.parse(next.downloadUrl));
            },
            child: const Text('打开下载页'),
          ),
      ],
    ),
  );
}

/// 单按钮结果弹框。
Future<void> _resultDialog(BuildContext context, String title, String body) {
  return showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: Text(body, style: const TextStyle(fontSize: 13)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('好')),
      ],
    ),
  );
}

/// 应用内下载（进度弹框）→ 按平台触发安装。
///
/// - **macOS**：下载 zip → 交给原生 updater.sh 替换本 app → 自动重启。
///   全程无手工操作，安装包由脚本在装成功后删除。
/// - **安卓**：下载 apk → 拉起系统安装器，最后一步由系统确认。
/// - **Windows 等**：下载后打开安装包，由用户自己点（暂不支持自替换）。
Future<void> _downloadAndInstall(
  BuildContext context,
  UpdateInfo info, {
  DownloadPackageFn? downloadFn,
  InstallPackageFn? installFn,
  SelfUpdateRunner? selfUpdate,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.of(context);
  final url = assetUrlFor(info)!;
  final fileName = Uri.parse(url).pathSegments.last;
  final runner = selfUpdate ?? selfUpdateRunnerFor();
  var received = 0;
  var lastPercent = -1;
  int? total;
  void Function()? refresh;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => StatefulBuilder(
      builder: (ctx, setD) {
        refresh = () => setD(() {});
        final t = total; // 闭包内取快照，避免可空字段提升失效
        return AlertDialog(
          title: Text('正在下载 ${info.latestVersion}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: t == null || t == 0 ? null : received / t),
              const SizedBox(height: 6),
              Text(
                t == null
                    ? '已下载 ${(received / 1048576).toStringAsFixed(1)} MB'
                    : '已下载 ${(received / 1048576).toStringAsFixed(1)} / ${(t / 1048576).toStringAsFixed(1)} MB'
                        '（${lastPercent < 0 ? 0 : lastPercent}%）',
                style: const TextStyle(fontSize: 12, color: AppColors.dim),
              ),
            ],
          ),
        );
      },
    ),
  );
  try {
    final file = await (downloadFn ?? downloadUpdatePackage)(
      url,
      fileName,
      onProgress: (r, t) {
        received = r;
        total = t;
        final percent = t == null || t == 0 ? -1 : r * 100 ~/ t;
        if (percent != lastPercent) {
          lastPercent = percent;
          refresh?.call();
        }
      },
    );
    navigator.pop(); // 关进度框

    // 自替换路径（macOS）：确认后交给原生脚本接管，App 随即退出并自动重启。
    // 安装包由 updater.sh 在替换成功后删除——用户无需手动清理。
    if (runner != null) {
      if (!context.mounted) return;
      final ok = await _confirmSelfUpdate(context, info.latestVersion);
      if (ok != true) return;
      try {
        // 这一调用不返回：原生侧启完脚本就 exit(0)。
        await runner(file.path);
      } catch (e) {
        if (!context.mounted) return;
        await _resultDialog(context, '更新失败', '$e');
      }
      return;
    }

    await (installFn ?? installUpdatePackage)(file.path);
    if (!context.mounted) return;
    if (Platform.isAndroid) {
      // 系统安装器已盖在 App 上，用 SnackBar 即可，避免盖回弹框。
      // 文案要说清两件事：①最后确认由系统提供（去不掉）；②装完系统会结束
      // 本进程，下次打开会提示「已更新到新版本」（Android 11+ 不可能自动重启）。
      messenger.showSnackBar(const SnackBar(
        content: Text('已打开系统安装器，点「安装」完成更新；'
            '安装后重新打开应用即可看到新版本'),
        duration: Duration(seconds: 5),
      ));
    } else {
      await _resultDialog(
        context,
        '下载完成',
        '安装包已在系统打开：${file.path}\n按提示完成安装。',
      );
    }
  } catch (e) {
    navigator.pop();
    if (!context.mounted) return;
    await _resultDialog(context, '下载失败', '$e');
  }
}

/// 自替换前的最后确认。返回 true = 继续安装。
///
/// 明确告知三件事：会退出 App、会自动重启、安装包会自动删除。
/// 自替换是不可撤销的动作（App 会被关掉），所以必须让用户知情。
Future<bool?> _confirmSelfUpdate(BuildContext context, String version) =>
    showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('安装 $version'),
        content: const Text(
          '即将自动替换并重启应用。\n\n'
          '· 应用会先退出几秒\n'
          '· 替换完成后自动重新打开\n'
          '· 下载的安装包在安装成功后自动删除\n\n'
          '若替换失败，会自动回滚到当前版本。',
          style: TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('安装并重启'),
          ),
        ],
      ),
    );

Future<void> _defaultWriteConfig(String path, String content) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    this.initialToken = '',
    required this.configPath,
    this.dbPath,
    this.syncing = false,
    this.syncMsg,
    this.onSyncPressed,
    this.onBackfillPressed,
    this.writeConfig = _defaultWriteConfig,
    this.accent = AccentColor.red,
    this.onAccentChanged,
    this.launchUrl,
    this.checkUpdate,
    this.downloadPackage,
    this.installPackage,
    this.selfUpdate,
  });

  final String initialToken;
  final String configPath;
  final String? dbPath;

  /// 同步编排在外壳（启动自动触发），这里只展示状态、转发点击。
  final bool syncing;
  final String? syncMsg;
  final VoidCallback? onSyncPressed;

  /// 回补历史：参数为用户选的年数（1/2/3），编排同样在外壳（[StockApp]）。
  final ValueChanged<int>? onBackfillPressed;
  final WriteConfigFn writeConfig;

  /// 主题强调色（编排在外壳：切换即重建主题并持久化）。
  final AccentColor accent;
  final ValueChanged<AccentColor>? onAccentChanged;
  final LaunchUrlFn? launchUrl;

  /// 检查更新；测试注入假实现，null 用真实 checkForUpdate。
  final CheckUpdateFn? checkUpdate;

  /// 更新包下载/安装端口；测试注入假实现，生产用 update_download 默认值。
  final DownloadPackageFn? downloadPackage;
  final InstallPackageFn? installPackage;

  /// macOS 自替换端口（下载 zip 后交给原生 updater.sh）。
  /// 不透传它，macOS 的自更新路径在测试里只能打到真的 MethodChannel。
  final SelfUpdateRunner? selfUpdate;

  @override
  Widget build(BuildContext context) {
    final token = TextEditingController(text: initialToken);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('tushare Token'),
        TextField(
          controller: token,
          obscureText: true,
          decoration: const InputDecoration(
            hintText: '在 tushare.pro 注册后获取',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const Icon(Icons.info_outline, size: 14, color: AppColors.dim),
            const SizedBox(width: 5),
            Expanded(
              child: GestureDetector(
                onTap: () => (launchUrl ?? defaultLaunchUrl)(Uri.parse(kTushareRegisterUrl)),
                child: const Text(
                  '没有 Token？点此前往 tushare.pro 注册（免费）',
                  style: TextStyle(fontSize: 12, color: Color(0xFF3B6BD6), decoration: TextDecoration.underline),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Wrap 而不是 Row：三个按钮在 320dp 窄屏会溢出，Wrap 自动换行
        Wrap(
          spacing: 12,
          children: [
            OutlinedButton(onPressed: () => _save(context, token), child: const Text('保存配置')),
            FilledButton(
              onPressed: syncing ? null : onSyncPressed,
              child: syncing
                  ? const Row(mainAxisSize: MainAxisSize.min, children: [
                      SizedBox(
                          width: 14,
                          height: 14,
                          child:
                              CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                      SizedBox(width: 8),
                      Text('同步中…'),
                    ])
                  : const Text('同步数据'),
            ),
            OutlinedButton(
              onPressed: syncing || onBackfillPressed == null
                  ? null
                  : () => _pickBackfill(context),
              child: const Text('回补历史'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (syncing) const Padding(
          padding: EdgeInsets.only(top: 8),
          child: LinearProgressIndicator(),
        ),
        if (syncMsg != null) Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(syncMsg!),
        ),
        const SizedBox(height: 24),
        const Text('主题色'),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final a in AccentColor.values) ...[
              _accentSwatch(a),
              const SizedBox(width: 14),
            ],
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('点击即生效并保存；涨红跌绿是行情惯例，不随主题变。',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ),
        if (dbPath != null) Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Text('数据库：$dbPath', style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '配置保存到 $configPath，App 与命令行（桌面）共用；打开 App 会自动增量同步，无需手动操作。',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        // 自检/更新属低频排障操作，沉底；结果弹框走根导航，不会被设置弹框遮挡
        const SizedBox(height: 20),
        Row(
          children: [
            TextButton.icon(
              onPressed: () => _diagnose(context),
              icon: const Icon(Icons.network_check, size: 16),
              label: const Text('网络自检', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: () => showCheckUpdate(
                context,
                // 与 macOS 菜单 ⌘U 入口构造同一套依赖，杜绝两处分叉
                deps: UpdateDeps(
                  checkFn: checkUpdate,
                  downloadFn: downloadPackage,
                  installFn: installPackage,
                  selfUpdateFn: selfUpdate,
                  launchUrl: launchUrl,
                ),
              ),
              icon: const Icon(Icons.system_update_alt, size: 16),
              label: const Text('检查更新', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _accentSwatch(AccentColor a) {
    final selected = a == accent;
    return GestureDetector(
      key: ValueKey('accent-${a.name}'),
      onTap: onAccentChanged == null ? null : () => onAccentChanged!(a),
      child: Tooltip(
        message: a.label,
        child: Container(
          width: 40,
          height: 40,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
                color: selected ? a.color : Colors.transparent,
                width: 2),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(color: a.color, shape: BoxShape.circle),
            child: selected
                ? const Icon(Icons.check, size: 18, color: Colors.white)
                : const SizedBox(),
          ),
        ),
      ),
    );
  }

  /// 网络自检：DNS + HTTPS 连通性，加载动效 + 结果弹框（与其他长任务一致）。
  Future<void> _diagnose(BuildContext context) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const LoadingDialog(title: '正在检测网络', subtitle: 'DNS 解析 + HTTPS 连通性'),
    );
    final result = await diagnoseNetwork();
    navigator.pop();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('网络自检'),
        content: Text(result, style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('好')),
        ],
      ),
    );
  }

  /// 回补历史选档：三档对应约 5/10/15 分钟（1.2s/日的限频间隔是主要开销）。
  /// 点档位即确认——弹窗文案已把「会拉多久、要保持前台」说清。
  void _pickBackfill(BuildContext context) {
    final callback = onBackfillPressed;
    if (callback == null) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('回补历史'),
        content: const Text(
          '首次同步若没拉全历史（回测数字明显偏少），从这里强制重拉。\n'
          '与每日增量同一数据源，重复执行安全（幂等）。\n\n'
          '近 1 年 / 2 年 / 3 年 ≈ 5 / 10 / 15 分钟，期间请保持 App 在前台、网络可用。',
          style: TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          for (final years in [1, 2, 3])
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                callback(years);
              },
              child: Text('近 $years 年'),
            ),
        ],
      ),
    );
  }

  Future<void> _save(BuildContext context, TextEditingController token) async {
    // 保留文件里已有的其他键，只更新 TUSHARE_TOKEN。
    final file = File(configPath);
    final vars = file.existsSync()
        ? AppConfig.parseDotEnv(file.readAsStringSync())
        : <String, String>{};
    vars['TUSHARE_TOKEN'] = token.text.trim();
    await writeConfig(
      configPath,
      '${[for (final e in vars.entries) '${e.key}=${e.value}'].join('\n')}\n',
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已保存到 $configPath')));
  }
}
