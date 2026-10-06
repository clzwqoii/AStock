/// 应用外壳：启动自动增量同步（数据齐全=零请求空跑）+ 主题色切换 + 工作台主窗口。
/// 设置不再用页签：侧栏左下角按钮或 macOS 菜单栏「设置… ⌘,」弹出设置弹框。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io' show Platform;

import '../app_logic.dart';
import '../core/backtest.dart';
import '../config.dart';
import '../net_diag.dart';
import 'backtest_page.dart';
import 'colors.dart';
import 'mobile_home.dart';
import 'onboarding.dart';
import 'screening_page.dart';
import 'settings_page.dart';

class StockApp extends StatefulWidget {
  const StockApp({
    super.key,
    required this.config,
    this.runSyncFn = runSync,
    this.runBacktestFn = runBacktest,
    this.persistAccent,
    this.screenFn,
    this.persistToken,
    this.launchUrl,
    this.showOnboarding = true,
  });

  final AppConfig config;

  /// 供测试注入假同步；生产用默认实现。
  final RunSyncFn runSyncFn;

  /// 重算回测报告；测试可注入假实现，避免真跑 30~50 秒。
  final Future<BacktestReport> Function(String dbPath, {String? reportPath})
      runBacktestFn;

  /// 供测试注入假选股；生产用默认实现。
  final ScreenFn? screenFn;

  /// 主题色持久化；测试注入，生产写 ~/.stock/.env。
  final Future<void> Function(String accentName)? persistAccent;

  /// 引导页保存 token；测试注入，生产写配置文件。
  final Future<void> Function(String token)? persistToken;

  /// 打开注册链接（测试注入）；默认用 url_launcher。
  final LaunchUrlFn? launchUrl;

  /// 是否在无 token 时弹出首次启动引导（测试可关）。
  final bool showOnboarding;

  @override
  State<StockApp> createState() => _StockAppState();
}

class _StockAppState extends State<StockApp> {
  /// 桌面端：false = 选股工作台，true = 回测对比页。
  bool _showBacktest = false;

  late AppConfig _config = widget.config;
  bool _syncing = false;
  String? _syncMsg;
  late AccentColor _accent = AccentColor.fromName(widget.config.themeAccent);

  /// 设置页保存配置的目标文件：移动端由 path_provider 解析（沙盒内），桌面为 ~/.stock/.env。
  late final String _configPath = widget.config.configPath.isNotEmpty
      ? widget.config.configPath
      : '${Platform.environment['HOME'] ?? '.'}/.stock/.env';
  final _navigatorKey = GlobalKey<NavigatorState>();

  /// 回测报告缓存：启动时读一次，选股页规则列表与回测页共用；
  /// 回测完成后 [onReport] 回来刷新，两处胜率同步更新。
  BacktestReport? _report;

  /// 是否正在重算回测报告（同步到新数据后自动触发）。
  bool _refreshingReport = false;

  @override
  void initState() {
    super.initState();
    // 回测报告是纯读的小 JSON（约 12KB），启动时顺手读掉；读失败不影响选股。
    _report = loadBacktestReport(_config.dbPath);
    // 原生菜单（macOS）回调：Swift 端点菜单项 → 这里打开对应弹框。
    const MethodChannel('platform_menu').setMethodCallHandler((call) async {
      switch (call.method) {
        case 'openSettings':
          _openSettings(_navigatorKey.currentContext!);
        case 'checkUpdate':
          _checkUpdate(_navigatorKey.currentContext!);
      }
    });
    _startSync();
    if (widget.showOnboarding && widget.config.tushareToken.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openOnboarding());
    }
  }

  /// 首次启动引导：保存 token 后写配置并立即开始同步。
  Future<void> _openOnboarding() async {
    await showDialog<void>(
      context: _navigatorKey.currentContext!,
      barrierDismissible: false,
      builder: (_) => OnboardingDialog(
        launchUrl: widget.launchUrl,
        onSubmit: (token) async {
          if (widget.persistToken != null) {
            await widget.persistToken!(token);
          } else {
            await AppConfig.updateFile(_configPath, {'TUSHARE_TOKEN': token});
          }
          if (!mounted) return;
          setState(() => _config =
              _config.copyWith(tushareToken: token, configPath: _configPath));
          _startSync();
        },
      ),
    );
  }

  /// 增量同步：只拉本地缺的交易日，库里数据齐全时接口调用为 0。
  Future<void> _startSync() async {
    if (_syncing) return;
    if (_config.tushareToken.isEmpty) {
      setState(() => _syncMsg = '未配置 token：请打开设置输入并保存');
      return;
    }
    setState(() {
      _syncing = true;
      _syncMsg = null;
    });
    try {
      final r = await widget.runSyncFn(
        dbPath: _config.dbPath,
        token: _config.tushareToken,
        onProgress: (m) {
          if (mounted) setState(() => _syncMsg = '同步中：$m');
        },
      );
      if (!mounted) return;
      setState(() =>
          _syncMsg = '同步完成：新增 ${r.dates} 个交易日、${r.rows} 行（数据齐全时为 0）');
      // 有新增数据就重算回测报告，否则选股页规则列表上的胜率还是上周的。
      if (r.rows > 0) _refreshReport();
    } catch (e) {
      if (!mounted) return;
      setState(() => _syncMsg = '同步失败：${describeSyncError(e)}');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// 重算回测报告（约 30~50 秒，走后台 isolate）并刷新两处胜率展示。
  /// 失败只提示，不影响选股——报表是附加信息，不是选股的前置条件。
  Future<void> _refreshReport() async {
    setState(() => _refreshingReport = true);
    try {
      final r = await widget.runBacktestFn(_config.dbPath);
      if (!mounted) return;
      setState(() => _report = r);
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _syncMsg = '回测报告刷新失败：$e');
    } finally {
      if (mounted) setState(() => _refreshingReport = false);
    }
  }

  Future<void> _setAccent(AccentColor accent) async {
    setState(() => _accent = accent);
    if (widget.persistAccent != null) {
      await widget.persistAccent!(accent.name);
    } else {
      await AppConfig.updateFile(_configPath, {'THEME_ACCENT': accent.name});
    }
  }

  void _openSettings(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: SizedBox(
          width: 560,
          height: 640,
          child: SettingsPage(
            initialToken: _config.tushareToken,
            configPath: _configPath,
            dbPath: _config.dbPath,
            syncing: _syncing,
            syncMsg: _syncMsg,
            onSyncPressed: _startSync,
            accent: _accent,
            onAccentChanged: _setAccent,
            launchUrl: widget.launchUrl,
          ),
        ),
      ),
    );
  }

  /// 检查更新：弹框流程在 settings_page（设置页与 macOS 菜单共用）。
  Future<void> _checkUpdate(BuildContext context) =>
      showCheckUpdateDialog(context, launchUrl: widget.launchUrl);

  @override
  Widget build(BuildContext context) {
    final accent = _accent.color;
    final scheme = ColorScheme.fromSeed(seedColor: AppColors.seed);
    return AccentScope(
      color: accent,
      child: MaterialApp(
        navigatorKey: _navigatorKey,
        title: 'A股选股',
        theme: ThemeData(
          colorScheme: scheme,
          scaffoldBackgroundColor: AppColors.bg,
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            shape: Border(bottom: BorderSide(color: AppColors.border)),
          ),
          tabBarTheme: TabBarThemeData(
            labelColor: accent,
            unselectedLabelColor: AppColors.dim,
            indicatorColor: accent,
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
            ),
          ),
        ),
        home: Builder(
          builder: (ctx) {
            // 窄屏（手机）走移动原生布局，宽屏（桌面）走工作台。
            final wide = MediaQuery.of(ctx).size.width >= 768;
            if (!wide) {
              return MobileHome(
                dbPath: _config.dbPath,
                screenFn: widget.screenFn,
                syncing: _syncing,
                syncMsg: _refreshingReport ? '正在重算回测报告…' : _syncMsg,
                accent: _accent,
                onAccentChanged: _setAccent,
                onSyncPressed: _startSync,
                configPath: _configPath,
                initialToken: _config.tushareToken,
                launchUrl: widget.launchUrl,
                backtestReport: _report,
                backtestRunFn: widget.runBacktestFn,
                onReport: (r) => setState(() => _report = r),
              );
            }
            return Scaffold(
              body: IndexedStack(
                index: _showBacktest ? 1 : 0,
                children: [
                  ScreeningPage(
                    dbPath: _config.dbPath,
                    syncing: _syncing,
                    syncStatus: _syncMsg,
                    onOpenSettings: () => _openSettings(ctx),
                    onOpenBacktest: () => setState(() => _showBacktest = true),
                    backtestReport: _report,
                  ),
                  BacktestPage(
                    dbPath: _config.dbPath,
                    onBack: () => setState(() => _showBacktest = false),
                    initialReport: _report,
                    onReport: (r) => setState(() => _report = r),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
