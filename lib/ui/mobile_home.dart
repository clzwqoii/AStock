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

  /// 回补历史入口（参数为年数）；编排在外壳，null 时设置页入口自动禁用。
  final ValueChanged<int>? onBackfillPressed;
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

class _MobileScreeningState extends State<MobileScreening> {
  final _selected = <String>{};
  bool _expanded = true;
  bool _loading = false;
  String? _error;
  ({int total, List<ScreenRow> picked, String? dataDate, int blockedStale,
      int blockedCorporateAction})? _result;

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
      _result = await (widget.screenFn ?? runScreening)(widget.dbPath, rules);
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
    final blocked = (r?.blockedStale ?? 0) + (r?.blockedCorporateAction ?? 0);
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
                '数据护栏挡掉 $blocked 只假信号（停牌/退市 ${r!.blockedStale} 只 + '
                '除权日 ${r.blockedCorporateAction} 只）',
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
                      // 分组按「组内最高 10 日胜率」降序，组内再按胜率降序
                      for (final e in ruleGroupsSortedByWinRate(
                          ruleGroups, widget.backtestReport))
                        for (final id in ruleIdsSortedByWinRate(
                            e.value, widget.backtestReport,
                            pinFirst: kMainRuleId))
                          _ruleRow(ruleById(id), e.key, accent),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );

  /// 规则名下的回测统计行：`10日 55.6% · PF 1.46 · 795信号`。
  /// 无报告或无信号时不占高度。
  Widget _statLine(Rule rule) {
    final r = widget.backtestReport?.result(rule.id, 10);
    if (r == null || r.count == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        '10日 ${(r.winRate * 100).toStringAsFixed(1)}%'
        ' · PF ${r.profitFactor.toStringAsFixed(2)}'
        ' · ${r.count}信号',
        style: const TextStyle(fontSize: 10, color: AppColors.dim),
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
                Text(rule.name, style: const TextStyle(fontSize: 14)),
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

  /// 卡片上的预测行：`92·高  11.90/9.73  盈亏比7.01`
  /// 分两部分：评分一段、价与盈亏比一段，任一段缺失就不渲染。
  String _mobileScoreLine(ScreenRow row) {
    final sc = row.score!;
    final f = row.forecast!;
    final parts = <String>['${sc.score.toStringAsFixed(0)}·${sc.tier}'];
    final stop = f.stop?.toStringAsFixed(2);
    parts.add('${f.target!.toStringAsFixed(2)}/${stop ?? '—'}');
    if (f.riskReward != null) parts.add('盈亏比${f.riskReward!.toStringAsFixed(2)}');
    return parts.join('  ');
  }

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
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(row.name ?? '—', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(row.symbol, style: const TextStyle(fontSize: 11, color: AppColors.dim)),
                  // 信号日 + 近 20 日涨跌：主规则选出来的都是超卖票，光看当日
                  // 涨跌会让人误以为在追强势股。信号日还能看出数据新不新
                  // （停牌几周的票会短于数据截止日）。
                  Text(
                    '${row.signalDate.isEmpty ? '' : '${row.signalDate.substring(5)} · '}'
                    '20日 ${row.ret20 >= 0 ? '+' : '-'}${row.ret20.abs().toStringAsFixed(1)}%',
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
                // 评分 + 目标/止损 + 盈亏比。卡片没有表格宽裕，只放一行小字；
                // 完整信息（样本数、命中规则、数据截止日）在详情页。
                // 任一项缺失就整行不渲染——半行 "目标 — " 比没有更难看。
                if (row.score?.score != null && row.forecast?.target != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _mobileScoreLine(row),
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: _tierColor(row.score!),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      );
}
