/// 回测对比页：一张表看全部内置规则在持有 5/10/20 日下的胜率、平均收益与盈亏比，
/// 顶部一行是无条件基准（随便买一只的胜率）——没有基准，胜率高不高无从谈起。
///
/// 数据来自 `runBacktest` 落盘的 JSON（首次约 30 秒，之后秒开），
/// 所以页面本身只做"读缓存 / 触发重算 / 排序展示"三件事。
library;

import 'package:flutter/material.dart';
import 'package:stock/app_logic.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/market_state.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/report_store.dart';
import 'package:stock/ui/colors.dart';

/// 排序键：每个可点表头一个。[id] 用于判定「同一列再点一次反向」；
/// [num] 取该列数值（名字列无 num，按名字比）。
/// 不用枚举：持有期与年份都是数据驱动的动态列，枚举表达不了「按 2025 年排」。
/// 排序键：一个列 id + 从行里取该列数值的函数；num 为 null 表示按规则名字典序。
class _SortKey {
  const _SortKey(this.id, this.num);

  final String id;
  final double Function(_Row)? num;
}

/// PF 之后的固定列表头说明：表头、数据单元格、列数（tableW）三处都从同一份
/// 列表派生。早先这三处是三份并行的 `if (recentMode)`，各加一列必然对不上宽度。
class _Col {
  const _Col(this.label, this.key, this.cell, {this.tip});

  final String label;
  final _SortKey key;
  final Widget Function(_Row row) cell;
  final String? tip;
}

class BacktestPage extends StatefulWidget {
  const BacktestPage({
    super.key,
    required this.dbPath,
    this.reportPath,
    this.runFn = runBacktest,
    this.onBack,
    this.initialReport,
    this.onReport,
    this.historyPath,
  });

  final String dbPath;

  /// 报告 JSON 路径；null 时取数据库同目录。
  final String? reportPath;

  /// 可注入的回测入口（测试注入假实现）。
  final Future<BacktestReport> Function(String dbPath, {String? reportPath}) runFn;

  /// 返回回调（桌面端从工作台进来时要能回去）；null 时 AppBar 不显示返回键。
  final VoidCallback? onBack;

  /// 外壳传入的初始报告缓存（与选股页共用同一份）；内部重算后经 [onReport] 回传。
  final BacktestReport? initialReport;

  /// 报告更新回调：重算成功后通知外壳，让选股页的规则列表同步刷新胜率。
  final ValueChanged<BacktestReport>? onReport;

  /// 台账 JSON 路径；null 时取报告同目录的 backtest-history.json。
  final String? historyPath;

  @override
  State<BacktestPage> createState() => _BacktestPageState();
}

class _BacktestPageState extends State<BacktestPage> {
  late final ReportStore _store;
  BacktestReport? _report;
  bool _loading = false;
  String? _error;

  /// 当前排序列；null = 默认按中间持有期的胜率降序（在 [_table] 里兜底）。
  _SortKey? _sort;
  bool _desc = true;

  /// 只看「跨年稳健」的规则（每年胜率都跑赢该年基准）。
  bool _robustOnly = false;

  /// 「最近半年」窗口口径：表格数据切换到报告的 recent 切片，
  /// 并追加按天重抽的日均超额列。与全期口径并存，默认全期。
  bool _recentMode = false;

  /// 月度台账：连红计数的数据源。缺失/损坏为 null。
  BacktestHistory? _history;

  @override
  void initState() {
    super.initState();
    _store = ReportStore(widget.reportPath ?? reportPathFor(widget.dbPath));
    // 外壳已读过缓存就复用（避免两页各读一次 IO）；否则自己读。
    _report = widget.initialReport ?? _store.load();
    _history = _loadHistory();
  }

  /// 外壳（IndexedStack 常驻）重建时把新报告传进来。没有这个方法，同步后
  /// 自动回测落盘的新报告永远进不了页面——initState 只在首次挂载跑一次，
  /// 而 IndexedStack 不卸载页面，setState 才是唯一的更新通道。
  @override
  void didUpdateWidget(BacktestPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = widget.initialReport;
    // identical 三重守卫：
    // ① oldWidget.initialReport === incoming → 外壳重建但报告没换，不动；
    // ② _report === incoming → 页面自己 _run 完成后经 onReport → 外壳 setState
    //   回流的正是刚 set 的同一实例，不动（否则会重读台账、刷掉连红列）；
    // ③ incoming == null → 外壳还没读到报告，不覆盖页面已有的缓存。
    if (!identical(oldWidget.initialReport, incoming) &&
        !identical(_report, incoming) &&
        incoming != null) {
      setState(() {
        _report = incoming;
        _history = _loadHistory(); // 台账跟着重读（连红列）
      });
    }
  }

  /// 台账路径：注入优先，否则取报告同目录的 `backtest-history.json`。
  String get _historyFile => widget.historyPath ?? historyPathFor(_store.path);

  /// 读台账（连红计数用）。损坏/缺失都降级为 null，连红列显示 —。
  BacktestHistory? _loadHistory() => loadBacktestHistory(_historyFile);

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.runFn(widget.dbPath, reportPath: widget.reportPath);
      if (!mounted) return;
      // 台账要跟着一起重读：runBacktest 落盘报告的同时也 upsert 了台账，
      // 只更新 _report 会让连红列停在旧期数（首启无台账时更是整列 —）。
      setState(() {
        _report = r;
        _history = _loadHistory();
      });
      widget.onReport?.call(r); // 通知外壳，选股页规则列表的胜率随之更新
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _sortBy(_SortKey s) => setState(() {
        if (_sort?.id == s.id) {
          _desc = !_desc;
        } else {
          _sort = s;
          _desc = true;
        }
      });

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    // 窄屏（手机宽）下筛选 chips 与返回键/标题/回测按钮挤一行放不下，
    // NavigationToolbar 会静默把标题压到 0 宽、chip 贴上返回键（真机截图实拍）。
    // 窄屏把 chips 下移到 AppBar 下方独立一行；桌面（≥600dp）保持原布局，
    // 不动 800×600 首屏契约（表头可见性测试锁着）。
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final chips = _filterChips(accent);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('回测对比'),
        leading: widget.onBack == null
            ? null
            : IconButton(icon: const Icon(Icons.arrow_back), onPressed: widget.onBack),
        actions: [
          if (!narrow) ...chips,
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _loading ? null : _run,
              icon: _loading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow, size: 18),
              label: Text(_report == null ? '开始回测' : '重新回测'),
            ),
          ),
        ],
        bottom: narrow && chips.isNotEmpty
            ? PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Row(children: chips),
                ),
              )
            : null,
      ),
      body: _report == null ? _empty() : _table(_report!, accent),
    );
  }

  /// 两个口径筛选 chip。窄屏渲染在 AppBar 下方独立一行，桌面渲染在 actions。
  List<Widget> _filterChips(Color accent) => [
        // 稳健判定依赖分年数据,窗口口径下无意义,隐藏避免误读。
        if (!_recentMode)
          FilterChip(
            label: const Text('只看稳健规则', style: TextStyle(fontSize: 12)),
            selected: _robustOnly,
            onSelected: (v) => setState(() => _robustOnly = v),
            selectedColor: accent.withValues(alpha: 0.18),
            checkmarkColor: accent,
          ),
        if (_report != null && _report!.recent.isNotEmpty)
          FilterChip(
            label: const Text('最近半年', style: TextStyle(fontSize: 12)),
            selected: _recentMode,
            onSelected: (v) => setState(() => _recentMode = v),
            selectedColor: accent.withValues(alpha: 0.18),
            checkmarkColor: accent,
          ),
      ];

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.query_stats_outlined, size: 56, color: AppColors.dim),
              const SizedBox(height: 16),
              const Text('还没有回测报告',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text(
                '点右上角「开始回测」：对本地全部股票逐日滚动评估每条规则，\n'
                '统计信号日之后 5/10/20 日的胜率与收益，并与无条件基准对比。\n'
                '首次约 30 秒（5623 只 × 424 根），结果会缓存，之后秒开。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppColors.dim, height: 1.6),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(fontSize: 12, color: Colors.red)),
              ],
            ],
          ),
        ),
      );

  Widget _table(BacktestReport r, Color accent) {
    final hs = r.horizons; // 升序；列完全由它推导，不硬编码 5/10/20
    final pfH = hs.length >= 2 ? hs[1] : hs.last; // 盈亏比取中间持有期（默认 10 日）
    final recentMode = _recentMode && r.recent.isNotEmpty;
    final baseSlice = recentMode ? r.recentBaseline[pfH] : null;

    // 可信 = 跨年稳健 **且** 信号不集中。早先这里只用 isRuleYearlyRobust，
    // 于是按年胜率每年都赢、但 70% 信号集中在单月的规则也能进"稳健"名单。
    // 加了这个 AND 之后，严格版 RSI超卖·放量 在只开这一档时会被筛掉。
    // 窗口口径没有分年数据，稳健筛选不适用，恒显全部规则。
    final shown = recentMode
        ? builtInRules
        : _robustOnly
            ? [for (final rule in builtInRules)
                if (isRuleTrustworthy(r, rule.id)) rule]
            : builtInRules;

    _Row ruleRow(Rule rule) {
      if (recentMode) {
        final slice = r.recent[rule.id]?[pfH];
        var days = 0;
        double? ex, lo, hi;
        if (slice != null &&
            baseSlice != null &&
            slice.dayMeanReturn.isNotEmpty) {
          final ci = recentExcessCI(
            ruleDayMean: slice.dayMeanReturn,
            baseDayMean: baseSlice.dayMeanReturn,
            seed: 7,
          );
          ex = ci.excess;
          lo = ci.ciLow;
          hi = ci.ciHigh;
          days = slice.dayMeanReturn.length;
        }
        return _Row(
          name: rule.name,
          desc: rule.desc,
          count: {for (final h in hs) h: r.recent[rule.id]?[h]?.count ?? 0},
          win: {for (final h in hs) h: r.recent[rule.id]?[h]?.winRate ?? 0},
          avg: {for (final h in hs) h: r.recent[rule.id]?[h]?.avgReturn ?? 0},
          pf: r.recent[rule.id]?[pfH]?.stats.profitFactor ?? 0,
          isMain: rule.id == kMainRuleId,
          isBaseline: false,
          excessPp: ex,
          excessLo: lo,
          excessHi: hi,
          excessDays: days,
          consecutiveReds: _history?.consecutiveReds(rule.id),
        );
      }
      // 全期红绿口径（与半年 CI 互不替代）：分年均收都赢该年基准 → 红，
      // 分年都输 → 绿，其余（含"一个可判年份都没有"的旧报告）→ 黑。
      // 判定在 core（yearlyVerdict）：缺 yearly 的旧报告在这里返回 unknown，
      // 不上色——否则空循环恒真会把超额为正的规则整列染红。
      final verdict = yearlyVerdict(r, rule.id, horizon: pfH);
      return _Row(
        name: rule.name,
        desc: rule.desc,
        count: {for (final h in hs) h: r.result(rule.id, h)?.count ?? 0},
        yearlyWin: {
          for (final y in r.yearly.keys)
            y: (r.yearly[y]?[rule.id]?[pfH]?.count ?? 0) == 0
                ? -1 // 该年没数据（如 MA250 需要 250 根，早年算不出来）
                : r.yearly[y]![rule.id]![pfH]!.winRate
        },
        win: {for (final h in hs) h: r.result(rule.id, h)?.winRate ?? 0},
        avg: {for (final h in hs) h: r.result(rule.id, h)?.avgReturn ?? 0},
        pf: r.result(rule.id, pfH)?.profitFactor ?? 0,
        profile: r.profileOf(rule.id, pfH),
        isMain: rule.id == kMainRuleId,
        isBaseline: false,
        fullExcess: r.baseline[pfH] == null || r.result(rule.id, pfH) == null
            ? null
            : r.result(rule.id, pfH)!.avgReturn - r.baseline[pfH]!.avgReturn,
        fullRobust: verdict == YearlyVerdict.robust,
        fullLoser: verdict == YearlyVerdict.loser,
      );
    }

    final rows = <_Row>[
      for (final rule in shown) ruleRow(rule),
      if (recentMode)
        _Row(
          name: '（无条件基准）',
          count: {for (final h in hs) h: r.recentBaseline[h]?.count ?? 0},
          win: {for (final h in hs) h: r.recentBaseline[h]?.winRate ?? 0},
          avg: {for (final h in hs) h: r.recentBaseline[h]?.avgReturn ?? 0},
          pf: 0,
          profile: RuleProfile.empty,
          isMain: false,
          isBaseline: true,
        )
      else
        _Row(
          name: '（无条件基准）',
          count: {for (final h in hs) h: r.baseline[h]?.count ?? 0},
          yearlyWin: {
            for (final y in r.yearlyBaseline.keys)
              y: (r.yearlyBaseline[y]?[pfH]?.count ?? 0) == 0
                  ? -1
                  : r.yearlyBaseline[y]![pfH]!.winRate
          },
          win: {for (final h in hs) h: r.baseline[h]?.winRate ?? 0},
          avg: {for (final h in hs) h: r.baseline[h]?.avgReturn ?? 0},
          pf: 0,
          profile: RuleProfile.empty,
          isMain: false,
          isBaseline: true,
        ),
    ];

    // 排序：用户点过列头就听用户的；否则默认按中间持有期胜率降序。
    final midH = hs[hs.length >= 2 ? 1 : hs.length - 1];
    final sortKey =
        _sort ?? _SortKey('win$midH', (row) => row.win[midH] ?? 0);
    rows.sort((a, b) {
      // 主力规则恒在首位（基准行除外）。不这么做的话，按胜率排会把
      // 严格版（全样本 86.4%）排到宽松版（79.9%）前面，与选股侧栏的
      // kMainRuleId 直接矛盾——两个页面给出相反的"第一"会让主力决定失效。
      if (_sort == null && a.isBaseline != b.isBaseline) {
        // b 是基准 → a 该在它前面 → 返回负；a 是基准 → a 该垫底 → 返回正。
        // 这两处符号写反过一次，基准行直接跑到表格第一行。
        return b.isBaseline ? -1 : 1;
      }
      if (_sort == null && a.isMain != b.isMain) return a.isMain ? -1 : 1;
      final c = sortKey.num == null
          ? a.name.compareTo(b.name)
          : sortKey.num!(a).compareTo(sortKey.num!(b));
      return _desc ? -c : c;
    });

    // 固定列宽 + 横向滚动：11 列在手机上放不下，溢出不如滑动。
    const nameW = 132.0;
    const cellW = 62.0;
    // 分年胜率：每年一列。窗口口径没有分年与集中度,换成超额列。
    final years = recentMode ? <int>[] : (r.yearly.keys.toList()..sort());
    // PF 之后的固定列。全期 2 列(超额/主力月);窗口 5 列(半年超额/独立日/
    // CI下界/CI上界/连红)。表头、单元格、tableW 都从这里派生,不再各写一份。
    final tailCols = <_Col>[
      if (recentMode) ...[
        _Col('半年超额', _SortKey('excess', (row) => row.excessPp ?? -999),
            (row) => _excessCell(row, cellW, accent),
            tip: '固定跟随中间持有期（默认 10 日）：规则日均收益 − 基准日均收益，'
                '按天重抽 200 轮取 95% 置信区间。'),
        // 这里不用 -999 哨兵：天数 > 0 ⟺ 有窗口数据，所以真值 0 的那一组
        // 恰好就是"没数据"那一组，与 CI 两列的 -999 分组逐位相同。
        _Col('独立日', _SortKey('excessDays', (row) => row.excessDays.toDouble()),
            (row) => _daysCell(row, cellW),
            tip: '窗口内有信号的交易日数（不是信号条数）。少于 '
                '$kMinSignificantDays 个不下结论：超额列显示「样本不足」，'
                'CI 两列不参与解读。'),
        _Col('CI下界', _SortKey('ciLow', (row) => row.excessLo ?? -999),
            (row) => _ciCell(row, cellW, accent, low: true),
            tip: '95% 置信区间下界，口径同「半年超额」列。> 0 即显著为正；'
                '单元格数字是点估计，颜色才是结论。'),
        _Col('CI上界', _SortKey('ciHigh', (row) => row.excessHi ?? -999),
            (row) => _ciCell(row, cellW, accent, low: false),
            tip: '95% 置信区间上界，口径同「半年超额」列。< 0 即显著为负。'),
        _Col(
            '连红',
            _SortKey('reds', (row) => (row.consecutiveReds ?? 0).toDouble()),
            (row) => _redsCell(row, cellW, accent),
            tip: '连续几期台账都红才显示。一期 = 一次回测快照，两期挨得越近'
                '窗口重叠越多、证据越弱，隔一个月以上再看才作数。'),
      ] else ...[
        // 全期口径:均收 − 同期基准(选股页统计行同口径的表格版)。
        _Col('$pfH日超额', _SortKey('fullExcess', (row) => row.fullExcess ?? -999),
            (row) => _cell(
                  row.fullExcess == null ? '—' : _signedPp0(row.fullExcess!),
                  cellW,
                  weight: row.isBaseline ? FontWeight.w800 : FontWeight.w400,
                  tone: row.isBaseline ? accent : _fullExcessTone(row, accent),
                ),
            tip: '规则均收 − 同期基准。红 = 分年每个有数据年份的均收都赢'
                '该年基准（历史有优势）；绿 = 分年都输（历史无优势）；'
                '黑色 = 其余。最近是否还灵看「最近半年」的置信区间，两口径互不替代。'),
        // 主力月占比：最大单月信号数 / 总信号数。超过
        // kRuleTopMonthShareCeiling 标警示色——那不是"更好"，是"更可疑"。
        _Col('主力月', _SortKey('share', (row) => row.profile.topMonthShare),
            (row) => _cell(_topMonthShare(row), cellW,
                weight: row.isBaseline ? FontWeight.w800 : FontWeight.w400,
                tone: _shareTone(row))),
      ],
    ];
    // +20 是行内左右各 10 的水平内边距，不加会让 Row 溢出。
    final extraCols = 1 + tailCols.length; // PF + 尾部列
    final tableW = nameW +
        cellW * (hs.length * 3 + extraCols + years.length) +
        20;

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        // 旧报告（这次版本之前生成的）没有 marketState 字段，这里整块不渲染。
        // 刻意不加"暂无，请重新回测"提示行：回测页纵向空间全给表格，多一行会把
        // 表头挤出视口（实测 800×600 下 3 个用例因此看不到表头）——报告每次同步
        // 后会自动重算，这个状态本就是过渡态。
        if (r.marketState != null) ...[
          _marketStateCard(r.marketState!),
          const SizedBox(height: 10),
        ],
        _meta(r, recentMode && !_anyRecentRed(rows)),
        const SizedBox(height: 10),
        _notes(),
        const SizedBox(height: 12),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppColors.border),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: tableW,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _headerRow(hs, pfH, years, nameW, cellW, sortKey, tailCols),
                  const Divider(height: 1),
                  for (final row in rows)
                    _dataRow(row, hs, years, accent, nameW, cellW, tailCols),
                ],
              ),
            ),
          ),
        ),
        // 半年口径说明卡放在**表格下方**：表格上方每多一行就把表头往下推一行，
        // 实测 800×600 下多两行后表格整块滑出 ListView 的构建区（表头 Text 根本
        // 不在树上，5 个用例连带变红）。字段定义要写全，就只能占表格下方这块空间。
        if (recentMode) ...[
          const SizedBox(height: 12),
          _recentNote(),
        ],
        const SizedBox(height: 16),
        _legend(),
      ],
    );
  }

  /// 市场状态卡片：牛/熊/震荡标签 + 三个等权口径关键数字。
  /// A 股色彩习惯：牛 = 红，熊 = 绿，震荡 = 中性。
  Widget _marketStateCard(MarketState ms) {
    final (Color tone, String why) = switch (ms.regime) {
      MarketRegime.bull => (
          AppColors.red,
          '等权市场在均线上方且近 20 日走强：普涨环境。'
              '趋势/动量类规则的信号密度通常上升。'
        ),
      MarketRegime.bear => (
          AppColors.down,
          '等权市场走弱：普跌或分化环境，基准收益本身为负，'
              '规则"跑赢基准"与"绝对赚钱"要分开看。'
        ),
      MarketRegime.sideways => (
          AppColors.text,
          '方向不明：结构性行情，同一条规则在不同月份的表现会差别很大。'
        ),
      MarketRegime.insufficient => (
          AppColors.dim,
          '本地历史不足以计算市场状态（需要至少 120 个交易日）。'
        ),
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('当前市况',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(ms.regime.label,
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w800, color: tone)),
              ),
              const Spacer(),
              // 手机宽度下"截至 YYYY-MM-DD · NNNN 只"放不下,截断比溢出好。
              Flexible(
                child: Text('截至 ${ms.asOfDate} · ${ms.stockCount} 只',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: AppColors.dim)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _chip('近20日 ${_signedPct(ms.ret20)}', tone),
              _chip('站上MA20 ${(ms.breadthAboveMa20 * 100).toStringAsFixed(0)}%', tone),
              _chip(
                  '新高−新低 ${_signedPp(ms.newHighLowDiff20)}', tone),
            ],
          ),
          const SizedBox(height: 8),
          Text(why,
              style: const TextStyle(fontSize: 12, height: 1.6, color: AppColors.dim)),
        ],
      ),
    );
  }

  String _signedPct(double v) =>
      '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}%';
  String _signedPp(double v) =>
      '${v >= 0 ? '+' : ''}${(v * 100).toStringAsFixed(0)}pp';

  Widget _meta(BacktestReport r, bool warnNoRed) => Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _chip('股票 ${r.stockCount} 只', AppColors.dim),
          _chip('基准样本 ${r.baseline[r.horizons.first]?.count ?? 0}', AppColors.dim),
          _chip('生成于 ${_fmtTime(r.generatedAt)}', AppColors.dim),
          if (warnNoRed) _noRedChip(),
        ],
      );

  Widget _notes() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF8E1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFFFE0A3)),
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('怎么看这张表',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
            SizedBox(height: 6),
            Text(
              '· 胜率 = 信号日后 N 日收益 > 0 的比例；「无条件基准」是同期随便买一只的'
              '胜率，规则要比它高才算有信息。\n'
              '· 平均收益 / 盈亏比同样和基准比：胜率高但平均收益低，可能是"赢很多次但赢得少"。\n'
              '· 信号数太少的行（几百以下）别当结论——一两个极端值就能把胜率拉飞。\n'
              '· 同一只股票可能重复出信号，信号之间不独立；未计交易成本与涨跌停无法成交。\n'
              '· 最右边「YYYY年」是该规则在每一年的胜率——跨年都赢才算稳，'
              '只有某一年特别 high 的很可能是那段行情的产物；显示 — 表示该年数据不够'
              '（如 MA250 需要 250 根 K 线）。\n'
              '· 「只看稳健规则」= 分年胜率在每一个有数据的年份都跑赢该年基准，'
              '比按全样本胜率排更可靠。\n'
              '· 点列头可排序，表格可左右滑动。',
              style: TextStyle(
                  fontSize: 12, height: 1.7, color: Color(0xFF6B5B23)),
            ),
          ],
        ),
      );

  Widget _legend() => const Text(
        'PF（盈亏比）= 盈利总额 / 亏损总额。>1 表示赢的比输的多；1.5 约等于'
        '"赢的时候赚 1.5 块、输的时候赔 1 块"。全盈或全亏时显示 0（该指标未定义）。\n'
        'pp = 百分点，55.1% 与 50.9% 的差是 +4.2pp。',
        style: TextStyle(fontSize: 11, height: 1.7, color: AppColors.dim),
      );

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(text, style: TextStyle(fontSize: 11, color: color)),
      );

  Widget _headerRow(List<int> hs, int pfH, List<int> years, double nameW,
          double cellW, _SortKey sortKey, List<_Col> tailCols) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(
          children: [
            _headCell('规则', const _SortKey('name', null), nameW, sortKey),
            for (var i = 0; i < hs.length; i++) ...[
              _headCell(
                  '${hs[i]}日信号',
                  _SortKey(
                      'count${hs[i]}', (row) => (row.count[hs[i]] ?? 0).toDouble()),
                  cellW,
                  sortKey),
              _headCell('${hs[i]}日胜率',
                  _SortKey('win${hs[i]}', (row) => row.win[hs[i]] ?? 0), cellW, sortKey),
              _headCell('${hs[i]}日均收',
                  _SortKey('avg${hs[i]}', (row) => row.avg[hs[i]] ?? 0), cellW, sortKey),
            ],
            _headCell('$pfH日PF', _SortKey('pf', (row) => row.pf), cellW, sortKey),
            for (final c in tailCols)
              _headCell(c.label, c.key, cellW, sortKey, tip: c.tip),
            for (final y in years)
              _headCell('$y年',
                  _SortKey('year$y', (row) => row.yearlyWin[y] ?? -1), cellW, sortKey),
          ],
        ),
      );

  /// [tip] 非空时给表头挂悬停/长按说明。用 Tooltip 而不是多写一行正文：
  /// 表格上方每多一行，表头就被往下推一行（说明卡已经吃掉首屏大半）。
  Widget _headCell(String label, _SortKey key, double w, _SortKey active,
      {String? tip}) {
    final text = Text(label,
        textAlign: key.num == null ? TextAlign.left : TextAlign.right,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700));
    return SizedBox(
      width: w,
      child: InkWell(
        onTap: () => _sortBy(key),
        child: Column(
          crossAxisAlignment: key.num == null
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
          children: [
            if (tip == null) text else Tooltip(message: tip, child: text),
            if (active.id == key.id)
              Icon(_desc ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                  size: 14, color: AppColors.dim),
          ],
        ),
      ),
    );
  }

  Widget _dataRow(_Row row, List<int> hs, List<int> years, Color accent,
          double nameW, double cellW, List<_Col> tailCols) =>
      Container(
        color: row.isBaseline ? accent.withValues(alpha: 0.06) : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(
          children: [
            _nameCell(row, accent, nameW),
            for (final h in hs) ...[
              _cell('${row.count[h] ?? 0}', cellW, tone: AppColors.dim),
              _cell(_pct(row.win[h] ?? 0), cellW,
                  weight: row.isBaseline ? FontWeight.w800 : FontWeight.w400,
                  tone: row.isBaseline ? accent : AppColors.text),
              _cell(_num(row.avg[h] ?? 0), cellW,
                  weight: row.isBaseline ? FontWeight.w800 : FontWeight.w400,
                  tone: row.isBaseline ? accent : AppColors.text),
            ],
            _cell(row.pf.toStringAsFixed(2), cellW,
                weight: row.isBaseline ? FontWeight.w800 : FontWeight.w400,
                tone: row.isBaseline ? accent : AppColors.text),
            for (final c in tailCols) c.cell(row),
            for (final y in years)
              _cell(
                // -1 表示该年没有可用数据（如 MA250 需要 250 根，早年算不出来）
                (row.yearlyWin[y] ?? -1) < 0 ? '—' : _pct(row.yearlyWin[y]!),
                cellW,
                tone: row.isBaseline ? accent : AppColors.text,
              ),
          ],
        ),
      );

  /// 半年超额/CI 两列共用的结论样式:显著为正 accent/w800、显著为负绿/w800、
  /// 不显著与样本不足灰/w400。独立日不足 [kMinSignificantDays] 或基准行不下结论。
  ///
  /// 颜色与字重只此一份:CI 下界/上界列只取它的颜色(同一结论的三个数字,
  /// 但字重不加重——"结论"的视觉主力永远是「半年超额」列)。
  ({Color tone, FontWeight weight}) _excessStyle(_Row row, Color accent) {
    if (row.isBaseline || row.excessDays < kMinSignificantDays) {
      return (tone: AppColors.dim, weight: FontWeight.w400);
    }
    if (_recentRed(row)) return (tone: accent, weight: FontWeight.w800); // 红 = 强
    return (row.excessHi ?? 0) < 0
        ? (tone: AppColors.down, weight: FontWeight.w800)
        : (tone: AppColors.dim, weight: FontWeight.w400);
  }

  /// 半年超额单元格:显著为正高亮、显著为负绿、不显著灰、样本不足/基准 —。
  Widget _excessCell(_Row row, double cellW, Color accent) {
    if (row.isBaseline || !row.hasRecentCI) {
      return _cell('—', cellW, tone: AppColors.dim);
    }
    if (row.excessDays < kMinSignificantDays) {
      return _cell('样本不足', cellW, tone: AppColors.dim);
    }
    final style = _excessStyle(row, accent);
    return _cell(_signedPp0(row.excessPp!), cellW,
        tone: style.tone, weight: style.weight);
  }

  /// 独立日单元格:窗口内有信号的**交易日数**(信号条数 ≠ 独立日数)。
  /// 日数不足也照实显示数字——"样本不足"的结论挂在超额列,这里给依据。
  Widget _daysCell(_Row row, double cellW) {
    if (row.isBaseline || !row.hasRecentCI) {
      return _cell('—', cellW, tone: AppColors.dim);
    }
    return _cell('${row.excessDays}', cellW, tone: AppColors.dim);
  }

  /// 半年 CI 下界/上界单元格:与超额列同色系(同一个判定的两端),两位小数。
  /// [hasRecentCI] 保证 lo/hi 与 excessPp 同生同灭,所以这里可以直接取。
  Widget _ciCell(_Row row, double cellW, Color accent, {required bool low}) {
    if (row.isBaseline || !row.hasRecentCI) {
      return _cell('—', cellW, tone: AppColors.dim);
    }
    return _cell(_num(low ? row.excessLo! : row.excessHi!), cellW,
        tone: _excessStyle(row, accent).tone);
  }

  String _signedPp0(double v) =>
      '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}';

  /// 全期超额列三色:红 = 分年均收都赢该年基准（历史有优势）,
  /// 绿 = 分年都输（历史无优势）,黑 = 其余。数值仍是全期点估计,
  /// "最近是否还灵"由半年超额列的 CI 负责——同色不同窗,不互相替代。
  /// 红用主题 accent,与半年超额列的"显著为正"同源（A 股红 = 强）。
  Color _fullExcessTone(_Row row, Color accent) {
    if (row.fullRobust && (row.fullExcess ?? 0) > 0) return accent;
    if (row.fullLoser && (row.fullExcess ?? 0) < 0) return AppColors.down;
    return AppColors.text;
  }

  /// 连红列:台账里连续显著为正的期数。≥2 才显示(1 期红说明不了什么),
  /// 颜色与超额列同源——这是"跨窗口可信度",不是当期表现。
  Widget _redsCell(_Row row, double cellW, Color accent) {
    final n = row.consecutiveReds ?? 0;
    if (row.isBaseline || n < 2) return _cell('—', cellW, tone: AppColors.dim);
    return _cell('$n连红', cellW, tone: accent, weight: FontWeight.w800);
  }

  /// 「最近半年显著为正（红）」的唯一判定：独立信号日 ≥ [kMinSignificantDays]
  /// 且超额 CI 下界 > 0。_excessCell 的红色分支与 _anyRecentRed 共用它，
  /// 口径只此一份（基准行由各调用方排除：单元格早退成 —，提示过滤 isBaseline）。
  bool _recentRed(_Row row) =>
      row.excessDays >= kMinSignificantDays && (row.excessLo ?? 0) > 0;

  /// 半年视图里有没有"显著为正"的规则（红）。
  bool _anyRecentRed(List<_Row> rows) =>
      rows.any((row) => !row.isBaseline && _recentRed(row));

  /// 无红提示。做成 _meta 行里的一枚琥珀色胶囊而不是独立横幅：半年视图下
  /// 表格上方每多一行就会把「半年超额」表头挤出 800×600 首屏（有测试契约）。
  /// 有红时不渲染。
  Widget _noRedChip() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF8E1),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFFFE0A3)),
        ),
        child: const Text(
          '⚠ 当前没有任何规则在最近半年显著跑赢基准',
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6B5B23)),
        ),
      );

  /// 窗口口径说明：四列各是什么字段 + 红/绿/灰/样本不足的语义。放在**表格下方**
  /// （见 [_table] 里的位置注释），所以可以写全——颜色语义不写清楚，"不显著一片"
  /// 会被误读成页面坏了，"红色"会被误读成排行榜第一，单元格里那个点估计则会
  /// 被当成"数值大就是好"。
  Widget _recentNote() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFEAF3FF),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFC3DBF7)),
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('怎么看「最近半年」',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
            SizedBox(height: 6),
            Text(
              '「最近半年」= 最近 120 个交易日的可评估日。超额 = 规则日均收益 − '
              '基准日均收益(按日配对),按天重抽 200 轮取 95% 置信区间。\n'
              '· 四列都固定跟随中间持有期(默认 10 日);表格可左右滑动,列头悬停/长按'
              '有该列的口径:\n'
              '  「半年超额」= 日均超额 pp,也就是那个点估计——数字大小不决定颜色,'
              '判定只看 CI。\n'
              '  「独立日」= 窗口内有信号的交易日数(不是信号条数),少于 '
              '$kMinSignificantDays 个不下结论。\n'
              '  「CI下界」「CI上界」= 95% 置信区间的两端,判定只看它们与 0 的位置:'
              '下界>0 红、上界<0 绿、跨 0 灰。\n'
              '· 红色 = 显著为正(下界>0):最近半年确实在赚超额。这是及格线,'
              '不是冠军奖牌;多条红色时看「连红」列——连续几期台账都红的才更可信。\n'
              '· 灰色 = 不显著:分不清是真本事还是运气,当"暂时失效"处理,别追。\n'
              '· 绿色 = 显著为负:统计上确认跑输基准,当前市况下避开。\n'
              '· 样本不足 = 独立信号日少于 $kMinSignificantDays 个,不下结论。\n'
              '· 没有红色 = 当前没有规则值得信,正确动作是降低操作频率与预期,'
              '而不是换一条规则。红色只描述过去 120 个交易日,不是对未来的承诺。\n'
              '· 选股页规则名下的红绿是「最近一个样本够的年份的超额」,口径比这里松;'
              '两处不一致时,以这里的 CI 为准。',
              style: TextStyle(
                  fontSize: 12, height: 1.7, color: Color(0xFF2A588C)),
            ),
          ],
        ),
      );

  /// 主力月占比。空统计显示 —。
  String _topMonthShare(_Row row) {
    if (row.profile.signalCount == 0) return '—';
    return '${(row.profile.topMonthShare * 100).toStringAsFixed(0)}%';
  }

  /// 超过 [kRuleTopMonthShareCeiling] 用警示色——那不是"更好"，是"更可疑"。
  Color _shareTone(_Row row) {
    if (row.profile.signalCount == 0) return AppColors.dim;
    if (row.profile.topMonthShare > kRuleTopMonthShareCeiling) {
      return AppColors.down;
    }
    return AppColors.text;
  }

  /// 规则名 + 一句话说明（说明是"规则介绍"的一半，胜率是另一半）。
  Widget _nameCell(_Row row, Color accent, double w) {
    final nameStyle = TextStyle(
      fontSize: 12,
      fontWeight: row.isBaseline ? FontWeight.w800 : FontWeight.w700,
      color: row.isBaseline ? accent : AppColors.text,
    );
    return SizedBox(
      width: w,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(row.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: nameStyle),
          if (row.desc != null && row.desc!.isNotEmpty)
            Text(
              row.desc!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: AppColors.dim),
            ),
        ],
      ),
    );
  }

  Widget _cell(
    String text,
    double w, {
    FontWeight? weight,
    Color? tone,
  }) =>
      SizedBox(
        width: w,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.right,
          style: TextStyle(
            fontSize: 12,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: tone ?? AppColors.text,
            fontWeight: weight,
          ),
        ),
      );

  String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';
  String _num(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}';

  String _fmtTime(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return iso;
    String p(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${p(t.month)}-${p(t.day)} ${p(t.hour)}:${p(t.minute)}';
  }
}

class _Row {
  _Row({
    required this.name,
    this.desc,
    required this.count,
    required this.win,
    required this.avg,
    required this.pf,
    required this.isBaseline,
    this.yearlyWin = const {},
    this.profile = RuleProfile.empty,
    this.isMain = false,
    this.excessPp,
    this.excessLo,
    this.excessHi,
    this.excessDays = 0,
    this.fullExcess,
    this.fullRobust = false,
    this.fullLoser = false,
    this.consecutiveReds,
  });

  final String name;
  final String? desc;
  final Map<int, int> count;

  /// 分年胜率：年 → 胜率（0~1）。没有分年数据时为空 Map。
  final Map<int, double> yearlyWin;
  final Map<int, double> win;
  final Map<int, double> avg;
  final double pf;
  final bool isBaseline;

  /// 信号集中度（主力月占比 / 有信号月数）。用来在表格里直接看出
  /// "这条规则的胜率是不是靠一两个月撑起来的"。
  final RuleProfile profile;

  /// 是否 [kMainRuleId] 指定的主力规则。
  final bool isMain;

  /// 窗口口径的日均超额(pp)与按天重抽 CI;null = 无数据(基准行)。
  final double? excessPp;
  final double? excessLo;
  final double? excessHi;

  /// 窗口 CI 三列(超额/独立日/CI 上下界)有没有数据。
  /// 三者由 ruleRow 一次性赋值、同生同灭，所以判定只此一份。
  bool get hasRecentCI => excessPp != null;

  /// 窗口内独立信号日数,不足 [kMinSignificantDays] 显示"样本不足"。
  final int excessDays;

  /// 全期口径:中间持有期均收 − 同期基准(pp);null = 无数据(基准行/无结果)。
  final double? fullExcess;

  /// 全期超额列红绿:分年均收都赢该年基准（红）/ 分年都输（绿）。
  /// 判定在 core（[yearlyVerdict]），与半年 CI 同源不同窗。
  /// 一个可判年份都没有时**两个都是 false**（不上色，见 [YearlyVerdict.unknown]）。
  final bool fullRobust;
  final bool fullLoser;

  /// 台账里连续显著为正的期数;null = 无台账数据。
  final int? consecutiveReds;
}
