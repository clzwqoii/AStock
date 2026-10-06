/// 应用外壳：启动自动增量同步（数据齐全=零请求空跑）+ 主题色切换 + 工作台主窗口。
/// 设置不再用页签：侧栏左下角按钮或 macOS 菜单栏「设置… ⌘,」弹出设置弹框。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io' show Platform;

import '../app_logic.dart';
import '../core/backtest.dart';
import '../config.dart';
import '../data/sync_service.dart' show SyncResult, backfillFromDate;
import '../net_diag.dart';
import '../update_download.dart';
import '../update_notice.dart';
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
    this.runBackfillFn = runBackfillSync,
    this.runBacktestFn = runBacktest,
    this.persistAccent,
    this.screenFn,
    this.persistToken,
    this.launchUrl,
    this.showOnboarding = true,
    this.updateNoticeCheck,
  });

  final AppConfig config;

  /// 供测试注入假同步；生产用默认实现。
  final RunSyncFn runSyncFn;

  /// 回补历史同步；测试注入假实现，生产用 [runBackfillSync]。
  final RunBackfillFn runBackfillFn;

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

  /// 启动时判断「上次启动后是否装过更新」；返回 true 则弹一次提示。
  /// 测试注入假实现，生产用 [checkUpdateNotice]（读 build 号比对）。
  final Future<bool> Function()? updateNoticeCheck;

  @override
  State<StockApp> createState() => _StockAppState();
}

class _StockAppState extends State<StockApp> {
  /// 桌面端：false = 选股工作台，true = 回测对比页。
  bool _showBacktest = false;

  late AppConfig _config = widget.config;
  bool _syncing = false;
  String? _syncMsg;

  /// 同步完成后库内最新交易日（头部同步徽标用）。
  String? _syncedDate;
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
    _maybeShowUpdateNotice();
    if (widget.showOnboarding && widget.config.tushareToken.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openOnboarding());
    }
  }

  /// 冷启动时若发现 build 号变了（说明中间装过更新），提示一次。
  ///
  /// 主要为安卓而做：Android 11+ 替换安装会由系统结束旧进程，收不到任何
  /// 安装完成事件，「装完自动重启」在技术上不成立——只能等下次冷启动，
  /// 靠 build 号比对来告诉用户「更新已生效」（见 lib/update_notice.dart）。
  ///
  /// 刻意排在引导页之前：首次启动 build 号无记录，不提示。
  Future<void> _maybeShowUpdateNotice() async {
    final check = widget.updateNoticeCheck ??
        () => checkUpdateNotice(configPath: _configPath);
    bool updated;
    try {
      updated = await check();
    } catch (_) {
      return; // 检测失败绝不挡启动
    }
    if (!updated || !mounted) return;
    // 等首帧跑完再弹，否则会在 build 期间插对话框导致布局异常。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _navigatorKey.currentContext;
      if (ctx == null) return;
      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
        content: Text('已更新到新版本'),
        duration: Duration(seconds: 4),
      ));
    });
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
  Future<void> _startSync() => _runSync(
        doneLabel: '同步完成',
        failLabel: '同步',
        task: () => widget.runSyncFn(
          dbPath: _config.dbPath,
          token: _config.tushareToken,
          onProgress: (m) {
            if (mounted) setState(() => _syncMsg = '同步中：$m');
          },
        ),
      );

  /// 回补历史：绕过水位线从所选年数前强制重拉。手机首次回填没跑成时，
  /// 历史深度只能靠这条路补（增量永远只拉水位线之后的日期）。
  Future<void> _startBackfill(int years) => _runSync(
        doneLabel: '回补完成',
        failLabel: '回补',
        task: () => widget.runBackfillFn(
          dbPath: _config.dbPath,
          token: _config.tushareToken,
          fromDate: backfillFromDate(DateTime.now(), years),
          onProgress: (m) {
            if (mounted) setState(() => _syncMsg = '回补中：$m');
          },
        ),
      );

  /// 增量与回补共用的执行骨架：互斥守卫、进度透传、完成/失败消息、
  /// 有新增数据（或报告缺失）就重算回测报告。
  Future<void> _runSync({
    required String doneLabel,
    required String failLabel,
    required Future<SyncResult> Function() task,
  }) async {
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
      final r = await task();
      if (!mounted) return;
      setState(() {
        _syncMsg = '$doneLabel：新增 ${r.dates} 个交易日、${r.rows} 行（数据齐全时为 0）';
        _syncedDate = r.latestDate ?? _syncedDate;
      });
      // 有新增数据就重算回测报告，否则选股页规则列表上的胜率还是上周的；
      // 报告缺失（手机首次安装、从没跑过回测）时也要补算——规则排序、
      // 胜率统计行、评分与目标/止损价全都依赖这份报告。
      if (r.rows > 0 || _report == null) _refreshReport();
    } catch (e) {
      if (!mounted) return;
      setState(() => _syncMsg = '$failLabel失败：${describeSyncError(e)}');
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
            onBackfillPressed: _startBackfill,
            accent: _accent,
            onAccentChanged: _setAccent,
            launchUrl: widget.launchUrl,
          ),
        ),
      ),
    );
  }

  /// 检查更新（macOS 菜单 ⌘U 入口）。
  ///
  /// 与设置页按钮**共用同一套依赖**（[UpdateDeps]）——两处入口以前参数集不同，
  /// 菜单栏漏传 selfUpdateFn 只靠下游兜底才碰巧没出事。现在漏传会在编译期暴露。
  Future<void> _checkUpdate(BuildContext context) => showCheckUpdate(
        context,
        deps: UpdateDeps(
          selfUpdateFn: selfUpdateRunnerFor(),
          launchUrl: widget.launchUrl,
        ),
      );

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
                syncedDate: _syncedDate,
                accent: _accent,
                onAccentChanged: _setAccent,
                onSyncPressed: _startSync,
                onBackfillPressed: _startBackfill,
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
