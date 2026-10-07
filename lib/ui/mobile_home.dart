/// 移动原生布局（窄屏 <768）：红色渐变头部 + 统计卡 + 折叠规则面板 +
/// 大按钮 + 结果卡片，底部导航切换 选股/设置。样机见 docs/design/mobile-native.html。
library;

import 'package:flutter/material.dart';

import '../app_logic.dart';
import '../core/backtest.dart';
import '../core/rules.dart';
import '../core/score.dart';
import 'colors.dart';
import 'onboarding.dart' show LaunchUrlFn;
import 'stock_detail_page.dart';
import 'screening_page.dart' show LoadingDialog, ruleGroups, ScreenFn;
import 'backtest_page.dart';
import 'settings_page.dart';

class MobileHome extends StatefulWidget {
  const MobileHome({
    super.key,
    required this.dbPath,
    required this.syncing,
    required this.syncMsg,
    required this.syncedDate,
    required this.accent,
    required this.onAccentChanged,
    required this.onSyncPressed,
    this.onBackfillPressed,
    required this.configPath,
    required this.initialToken,
    this.screenFn,
    this.launchUrl,
    this.backtestReport,
    this.coverage,
    this.backtestRunFn,
    this.onReport,
  });

  final String dbPath;
  final ScreenFn? screenFn;
  final bool syncing;
  final String? syncMsg;

  /// 同步完成后库内最新交易日（`YYYYMMDD`）；没跑过选股时徽标用它。
  final String? syncedDate;
  final AccentColor accent;
  final ValueChanged<AccentColor> onAccentChanged;
  final VoidCallback onSyncPressed;

  /// 回补历史入口（参数为年数与是否完整重拉）；编排在外壳，
  /// null 时设置页入口自动禁用。
  final void Function(int years, {bool force})? onBackfillPressed;
  final String configPath;
  final String initialToken;
  final LaunchUrlFn? launchUrl;

  /// 可注入的回测入口（测试注入假实现，避免真跑 30~50 秒）；null 时用真实现。
  final Future<BacktestReport> Function(String dbPath, {String? reportPath})?
      backtestRunFn;

  /// 重算成功后把新报告交回外壳，外壳换缓存重建，选股页统计行随之刷新。
  final ValueChanged<BacktestReport>? onReport;

  /// 回测报告缓存（外壳读一次）；非 null 时规则面板在名字下显示 10 日胜率/PF/信号数。
  final BacktestReport? backtestReport;

  /// 本地历史行情覆盖情况（供设置页与回补弹窗诊断）。
  final HistoryCoverage? coverage;

  @override
  State<MobileHome> createState() => _MobileHomeState();
}

class _MobileHomeState extends State<MobileHome> {
  int _tab = 0;

  /// _tab 同时是 IndexedStack 与 NavigationBar 的下标：0 选股、1 回测、2 设置。

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          MobileScreening(
            dbPath: widget.dbPath,
            screenFn: widget.screenFn,
            syncing: widget.syncing,
            syncMsg: widget.syncMsg,
            syncedDate: widget.syncedDate,
            backtestReport: widget.backtestReport,
          ),
          BacktestPage(
            dbPath: widget.dbPath,
            initialReport: widget.backtestReport,
            runFn: widget.backtestRunFn ?? runBacktest,
            onBack: () => setState(() => _tab = 0),
            onReport: widget.onReport,
          ),
          SafeArea(
            child: SettingsPage(
              initialToken: widget.initialToken,
              configPath: widget.configPath,
              dbPath: widget.dbPath,
              coverage: widget.coverage,
              syncing: widget.syncing,
              syncMsg: widget.syncMsg,
              onSyncPressed: widget.onSyncPressed,
              onBackfillPressed: widget.onBackfillPressed,
              accent: widget.accent,
              onAccentChanged: widget.onAccentChanged,
              launchUrl: widget.launchUrl,
            ),
          ),
        ],
      ),
      // 注意：destinations 的顺序必须与上面 IndexedStack 的 children 一致
      // （选股 / 回测 / 设置），否则点标签会打开错的页面。
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        indicatorColor: widget.accent.color.withValues(alpha: 0.14),
        destinations: [
          NavigationDestination(
            icon: Icon(Icons.manage_search_outlined, color: AppColors.dim),
            selectedIcon: Icon(Icons.manage_search, color: widget.accent.color),
            label: '选股',
          ),
          NavigationDestination(
            icon: Icon(Icons.query_stats_outlined, color: AppColors.dim),
            selectedIcon: Icon(Icons.query_stats, color: widget.accent.color),
            label: '回测',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined, color: AppColors.dim),
            selectedIcon: Icon(Icons.settings, color: widget.accent.color),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

class MobileScreening extends StatefulWidget {
  const MobileScreening({
    super.key,
    required this.dbPath,
    required this.syncing,
    required this.syncMsg,
    required this.syncedDate,
    this.screenFn,
    this.backtestReport,
  });

  final String dbPath;
  final ScreenFn? screenFn;
  final bool syncing;
  final String? syncMsg;

  /// 同步完成后库内最新交易日（`YYYYMMDD`）；没跑过选股时徽标用它。
  final String? syncedDate;

  /// 回测报告缓存；非 null 时规则面板显示各规则的 10 日胜率/PF/信号数。
  final BacktestReport? backtestReport;

  @override
  State<MobileScreening> createState() => _MobileScreeningState();
}

class _MobileScreeningState extends State<MobileScreening>
    with WidgetsBindingObserver {
  final _selected = <String>{};
  bool _expanded = true;
  bool _loading = false;
  String? _error;

  /// 常驻选股服务：池子跨次复用（数据/报告变了自动重载），空闲后自动回收。
  /// 测试注入 screenFn 假实现时不经过它。
  final _screeningSvc = ScreeningService();

  ScreenResult? _result;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didHaveMemoryPressure() {
    // 系统缺内存：立即归还常驻 isolate 的池子，下次选股重新加载（慢一次）。
    _screeningSvc.releasePool();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _screeningSvc.dispose();
    super.dispose();
  }

  void _toggle(String id) {
    setState(() {
      _selected.contains(id) ? _selected.remove(id) : _selected.add(id);
    });
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const LoadingDialog(title: '正在选股', subtitle: '全部满足所选规则的股票才会入选'),
    );
    try {
      final rules = [for (final id in _selected) ruleById(id)];
      _result = widget.screenFn != null
          ? await widget.screenFn!(widget.dbPath, rules)
          : await _screeningSvc.screen(widget.dbPath, rules);
    } catch (e) {
      _error = e.toString();
    } finally {
      navigator.pop();
      // 选股完成后收起规则面板：结果列表会被 20 行的面板整个挡住。
      if (mounted) {
        setState(() {
          _loading = false;
          if (_error == null) _expanded = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _header()),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        SliverToBoxAdapter(child: _stats()),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        SliverToBoxAdapter(child: _rulesPanel(accent)),
        // 规则面板与按钮之间留呼吸间距
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: SizedBox(
              height: 50,
              child: FilledButton(
                onPressed: _selected.isEmpty || _loading ? null : _run,
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 6),
                ),
                child: const Text('开始选股'),
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(child: _resultHeader()),
        if (_result != null && _result!.picked.isNotEmpty)
          SliverList.builder(
            itemCount: _result!.picked.length,
            itemBuilder: (_, i) => _card(_result!.picked[i]),
          )
        else
          SliverToBoxAdapter(child: _hint()),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _header() {
    final top = MediaQuery.of(context).padding.top;
    final accent = AccentScope.of(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(18, top + 14, 18, 22),
      // 渐变随主题色：深端为主色压暗 28%
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent, Color.lerp(accent, Colors.black, 0.28)!],
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(26)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('A股选股',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white)),
              ),
              // 上下 padding 差 1dp：安卓中文字体（MiSans/Noto）行盒下部留白偏大，
              // 胶囊内墨迹整体偏上（真机像素实测约 0.6dp，2026-10-06），反向补偿。
              Container(
                padding: const EdgeInsets.only(left: 10, right: 10, top: 4.5, bottom: 3.5),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(10)),
                child: Text(
                  widget.syncing ? '同步中…' : _syncChipText(),
                  style: const TextStyle(fontSize: 10, color: Colors.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _result != null && _selected.isNotEmpty
                ? '组合：${_selected.map((id) => ruleById(id).name).join(' ∧ ')}'
                : '按规则筛选 · 数据截至今日收盘',
            style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.85)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  String _syncChipText() {
    // 优先显示本次选股结果的数据日；没跑过选股时回退到同步完成的库内最新交易日。
    final d = _result?.dataDate ?? widget.syncedDate;
    if (d != null && d.length >= 8) {
      return '已同步 ${d.substring(4, 6)}-${d.substring(6)}';
    }
    return '未同步';
  }

  Widget _stats() {
    final r = _result;
    final msg = widget.syncMsg;
    // 护栏挡掉的"本会入选"的假信号数。只在有数时显示——静默过滤会让用户
    // 以为"规则没信号"，而这正是此前被两年前的化石票骗过的原因。
    final blocked = (r?.blockedStale ?? 0) +
        (r?.blockedCorporateAction ?? 0) +
        (r?.blockedSuspension ?? 0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _statCard('${r?.total ?? '—'}', '全市场'),
              const SizedBox(width: 10),
              _statCard('${r?.picked.length ?? 0}', '入选', color: AccentScope.of(context)),
              const SizedBox(width: 10),
              _statCard(_result == null ? '—' : '${_selected.length}', '已选规则'),
            ],
          ),
          if (blocked > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Text(
                '数据护栏挡掉 $blocked 只假信号（停牌/退市 ${r!.blockedStale} + '
                '除权日 ${r.blockedCorporateAction} + 停牌复牌 ${r.blockedSuspension}）',
                style: const TextStyle(fontSize: 11, color: AppColors.dim),
              ),
            ),
          if (r?.timings != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Text(
                '耗时 ${_secs(r!.timings!.totalMs)}（加载 ${_secs(r.timings!.loadMs)}'
                ' · 筛选 ${_secs(r.timings!.screenMs)} · 汇总 ${_secs(r.timings!.assembleMs)}'
                '${r.timings!.poolReused ? ' · 池子复用' : ''}）',
                style: const TextStyle(fontSize: 11, color: AppColors.dim),
              ),
            ),
          if (msg != null && msg.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Text(msg,
                  style: TextStyle(
                      fontSize: 11,
                      color: msg.contains('失败') ? Colors.red : AppColors.dim)),
            ),
        ],
      ),
    );
  }

  String _secs(int ms) => ms < 1000 ? '${ms}ms' : '${(ms / 1000).toStringAsFixed(1)}s';

  Widget _statCard(String value, String label, {Color? color}) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 16, offset: const Offset(0, 5))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: color ?? AppColors.text)),
              const SizedBox(height: 2),
              Text(label, style: const TextStyle(fontSize: 10, color: AppColors.dim)),
            ],
          ),
        ),
      );

  Widget _rulesPanel(Color accent) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 12, offset: const Offset(0, 4))],
        ),
        child: Column(
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    const Text('选股规则', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    Text('已选 ${_selected.length}',
                        style: TextStyle(fontSize: 11, color: accent, fontWeight: FontWeight.w700)),
                    Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 20, color: AppColors.dim),
                  ],
                ),
              ),
            ),
            if (_expanded)
              // 规则多到 11 条后面板会顶到 500px+，把「开始选股」挤出首屏；
              // 限高并内部滚动，保证主按钮始终在首屏内可见可点。
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      // 分组按「组内最高超额」降序；组内按超额降序（无报告时保持
                      // 声明顺序）。主力不钉首位，由 _ruleRow 在名字旁挂「主力」徽标
                      for (final e in ruleGroupsSortedByExcess(
                          ruleGroups, widget.backtestReport))
                        for (final id in ruleIdsSortedByExcess(
                            e.value, widget.backtestReport))
                          _ruleRow(ruleById(id), e.key, accent),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );

  /// 规则名下的回测统计行：`2026年 +0.07% · 超额 +0.48pp · 基准 -0.41%`。
  /// 无报告或该年样本不足时不占高度。
  ///
  /// 显示超额而不是胜率：熊市里胜率低于基准常常只是"赢小钱、输小钱"，
  /// 期望仍为正（实测 2026 年 rsi_oversold 胜率低于基准但超额 +0.48pp）。
  Widget _statLine(Rule rule) {
    final report = widget.backtestReport;
    if (report == null) return const SizedBox.shrink();
    final line = ruleStatLine(report, rule.id, 10);
    if (line == null) return const SizedBox.shrink();
    final upDown = upDownColorsOf(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Tooltip(
        message: RuleStatLine.helpText,
        margin: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          line.label,
          style: TextStyle(
            fontSize: 10,
            color: line.excessPp >= 0 ? upDown.up : upDown.down,
          ),
        ),
      ),
    );
  }

  Widget _ruleRow(Rule rule, String category, Color accent) {
    final on = _selected.contains(rule.id);
    return InkWell(
      onTap: () => _toggle(rule.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFF2F3F7)))),
        child: Row(
          children: [
            Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 主力规则徽标：身份标识，不影响排序（排序只听超额的）。
                // 名字必须 Flexible：长规则名（RSI超卖·放量(宽松)）+徽标在
                // 390px 屏的面板行宽内放不下，硬排会 overflow。
                Row(children: [
                  Flexible(
                      child: Text(rule.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14))),
                  if (rule.id == kMainRuleId) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFFE5E8EF)),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('主力',
                          style: TextStyle(fontSize: 9, color: AppColors.dim)),
                    ),
                  ],
                ]),
                _statLine(rule),
              ],
            ),
          ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(border: Border.all(color: const Color(0xFFE5E8EF)), borderRadius: BorderRadius.circular(4)),
              child: Text(category,
                  style: const TextStyle(fontSize: 9, color: Color(0xFFB5BCC9))),
            ),
            const SizedBox(width: 10),
            Switch(
              value: on,
              activeThumbColor: Colors.white,
              thumbColor: const WidgetStatePropertyAll(Colors.white),
              trackColor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.selected) ? accent : AppColors.switchOff,
              ),
              trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (_) => _toggle(rule.id),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultHeader() {
    final r = _result;
    if (r == null || r.picked.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
      child: Text('入选 ${r.picked.length} 只 · 点击查看详情',
          style: const TextStyle(fontSize: 12, color: AppColors.dim)),
    );
  }

  Widget _hint() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
        child: Text('选股失败：$_error', style: const TextStyle(color: Colors.red, fontSize: 13)),
      );
    }
    final r = _result;
    if (r == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 18, vertical: 20),
        child: Text('勾选规则后点「开始选股」', style: TextStyle(fontSize: 13, color: AppColors.dim)),
      );
    }
    if (r.total == 0) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 18, vertical: 20),
        child: Text('本地库暂无数据，等自动同步完成即可', style: TextStyle(fontSize: 13, color: AppColors.dim)),
      );
    }
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 18, vertical: 20),
      child: Text('没有股票满足所选规则', style: TextStyle(fontSize: 13, color: AppColors.dim)),
    );
  }

  void _openDetail(ScreenRow row) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StockDetailPage(dbPath: widget.dbPath, symbol: row.symbol, name: row.name),
    ));
  }

  /// 卡片底部三格指标的样式：标签在上、数值在下。
  /// 数值必须带词（「50%·低」「13.23 (-2.6%)」），裸数字用户读不懂。
  Widget _cardStat(String label, String value, Color color) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 9, color: AppColors.dim)),
            const SizedBox(height: 1),
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: color,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ],
        ),
      );

  String _signedPct(double v) =>
      '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}%';

  Color _tierColor(StockScore sc) {
    if (sc.lowConfidence) return AppColors.dim;
    if (sc.tier == '高') return AppColors.red;
    if (sc.tier == '中') return AppColors.text;
    return AppColors.down;
  }

  Widget _card(ScreenRow row) => GestureDetector(
        onTap: () => _openDetail(row),
        child: Container(
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 3))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(row.name ?? '—', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      // 信号日放在代码旁边：说明该票为什么入选、数据新不新
                      // （停牌几周的票会早于数据截止日）。
                      Text(
                        row.signalDate.isEmpty
                            ? row.symbol
                            : '${row.symbol} · 信号 ${row.signalDate.substring(5)}',
                        style: const TextStyle(fontSize: 11, color: AppColors.dim),
                      ),
                      // 近 20 日涨跌：主规则选出来的都是超卖票，光看当日涨跌
                      // 会让人误以为在追强势股。
                      Text(
                        '近20日 ${row.ret20 >= 0 ? '+' : '-'}${row.ret20.abs().toStringAsFixed(1)}%',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: row.ret20 >= 0 ? AppColors.red : AppColors.down,
                            fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(row.close.toStringAsFixed(2),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
                    Text(
                      '${row.changePct >= 0 ? '+' : '-'}${row.changePct.abs().toStringAsFixed(2)}%',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: row.changePct >= 0 ? AppColors.red : AppColors.down,
                          fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ],
                ),
              ],
            ),
            // 三格带标签指标，替代旧的裸数字行「50·低 13.23/12.77 盈亏比-0.43」。
            // 盈亏比不再单独展示：目标/止损的百分比已经表达了同样的信息。
            // 任一数据缺失就整行不渲染——半行「目标 —」比没有更难看。
            if (row.score?.score != null && row.forecast?.target != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    _cardStat(
                      '10日胜率',
                      '${row.score!.score.toStringAsFixed(0)}%·${row.score!.tier}',
                      _tierColor(row.score!),
                    ),
                    _cardStat(
                      '目标价',
                      '${row.forecast!.target!.toStringAsFixed(2)} (${_signedPct(row.forecast!.targetPct!)})',
                      (row.forecast!.targetPct ?? 0) >= 0 ? AppColors.red : AppColors.down,
                    ),
                    _cardStat(
                      '止损价',
                      row.forecast!.stop == null
                          ? '—'
                          : '${row.forecast!.stop!.toStringAsFixed(2)} (${_signedPct(row.forecast!.stopPct!)})',
                      (row.forecast!.stopPct ?? 0) >= 0 ? AppColors.red : AppColors.down,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      );
}
