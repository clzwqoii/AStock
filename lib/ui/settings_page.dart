/// 设置页：token 配置（保存到 ~/.stock/.env，App 与命令行共用）+ 主题色 + 数据同步。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../config.dart';
import '../data/sync_service.dart';
import '../net_diag.dart';
import 'colors.dart';
import 'onboarding.dart' show LaunchUrlFn, defaultLaunchUrl, kTushareRegisterUrl;

typedef RunSyncFn = Future<SyncResult> Function({
  required String dbPath,
  required String token,
  void Function(String msg)? onProgress,
});

/// 写配置文件的端口；测试注入内存实现以避开真实 IO。
typedef WriteConfigFn = Future<void> Function(String path, String content);

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
    this.writeConfig = _defaultWriteConfig,
    this.accent = AccentColor.red,
    this.onAccentChanged,
    this.launchUrl,
  });

  final String initialToken;
  final String configPath;
  final String? dbPath;

  /// 同步编排在外壳（启动自动触发），这里只展示状态、转发点击。
  final bool syncing;
  final String? syncMsg;
  final VoidCallback? onSyncPressed;
  final WriteConfigFn writeConfig;

  /// 主题强调色（编排在外壳：切换即重建主题并持久化）。
  final AccentColor accent;
  final ValueChanged<AccentColor>? onAccentChanged;
  final LaunchUrlFn? launchUrl;

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
        Row(
          children: [
            OutlinedButton(onPressed: () => _save(context, token), child: const Text('保存配置')),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: syncing ? null : onSyncPressed,
              child: const Text('同步数据'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _diagnose(context),
            icon: const Icon(Icons.network_check, size: 16),
            label: const Text('网络自检', style: TextStyle(fontSize: 12)),
          ),
        ),
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

  /// 网络自检：DNS + HTTPS 连通性，结论直接弹给用户（真机排障用）。
  Future<void> _diagnose(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
      content: Text('正在检测网络…'),
      duration: Duration(seconds: 10),
    ));
    final result = await diagnoseNetwork();
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(result), duration: const Duration(seconds: 12)));
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
