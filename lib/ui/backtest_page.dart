/// 回测对比页：一张表看全部内置规则在持有 5/10/20 日下的胜率、平均收益与盈亏比，
/// 顶部一行是无条件基准（随便买一只的胜率）——没有基准，胜率高不高无从谈起。
///
/// 数据来自 `runBacktest` 落盘的 JSON（首次约 30 秒，之后秒开），
/// 所以页面本身只做"读缓存 / 触发重算 / 排序展示"三件事。
library;

import 'package:flutter/material.dart';
import 'package:stock/app_logic.dart';
import 'package:stock/core/backtest.dart';
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

class BacktestPage extends StatefulWidget {
  const BacktestPage({
    super.key,
    required this.dbPath,
    this.reportPath,
    this.runFn = runBacktest,
    this.onBack,
    this.initialReport,
    this.onReport,
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

  @override
  void initState() {
    super.initState();
    _store = ReportStore(widget.reportPath ?? reportPathFor(widget.dbPath));
    // 外壳已读过缓存就复用（避免两页各读一次 IO）；否则自己读。
    _report = widget.initialReport ?? _store.load();
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.runFn(widget.dbPath, reportPath: widget.reportPath);
      if (!mounted) return;
      setState(() => _report = r);
      widget.onReport?.call(r); // 通知外壳，选股页规则列表的胜率随之更新
    } on Exception catch (e) {
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
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('回测对比'),
        leading: widget.onBack == null
            ? null
            : IconButton(icon: const Icon(Icons.arrow_back), onPressed: widget.onBack),
        actions: [
          FilterChip(
            label: const Text('只看稳健规则', style: TextStyle(fontSize: 12)),
            selected: _robustOnly,
            onSelected: (v) => setState(() => _robustOnly = v),
            selectedColor: accent.withValues(alpha: 0.18),
            checkmarkColor: accent,
          ),
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
      ),
      body: _report == null ? _empty() : _table(_report!, accent),
    );
  }

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

    final shown = _robustOnly
        ? [for (final rule in builtInRules)
            if (isRuleYearlyRobust(r, rule.id)) rule]
        : builtInRules;
    final rows = <_Row>[
      for (final rule in shown)
        _Row(
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
          isBaseline: false,
        ),
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
        isBaseline: true,
      ),
    ];

    // 排序：每列一个 _SortKey，值就从行数据里取；默认按中间持有期的胜率降序。
    final midH = hs[hs.length >= 2 ? 1 : hs.length - 1];
    final sortKey =
        _sort ?? _SortKey('win$midH', (row) => row.win[midH] ?? 0);
    rows.sort((a, b) {
      final c = sortKey.num == null
          ? a.name.compareTo(b.name)
          : sortKey.num!(a).compareTo(sortKey.num!(b));
      return _desc ? -c : c;
    });

    // 固定列宽 + 横向滚动：11 列在手机上放不下，溢出不如滑动。
    const nameW = 132.0;
    const cellW = 62.0;
    // 分年胜率：每年一列
    final years = r.yearly.keys.toList()..sort();
    // +20 是行内左右各 10 的水平内边距，不加会让 Row 溢出。
    final tableW =
        nameW + cellW * (hs.length * 3 + 1 + years.length) + 20;

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        _meta(r),
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
                  _headerRow(hs, pfH, years, nameW, cellW, sortKey),
                  const Divider(height: 1),
                  for (final row in rows) _dataRow(row, hs, years, accent, nameW, cellW),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _legend(),
      ],
    );
  }

  Widget _meta(BacktestReport r) => Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _chip('股票 ${r.stockCount} 只', AppColors.dim),
          _chip('基准样本 ${r.baseline[r.horizons.first]?.count ?? 0}', AppColors.dim),
          _chip('生成于 ${_fmtTime(r.generatedAt)}', AppColors.dim),
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
          double cellW, _SortKey sortKey) =>
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
            for (final y in years)
              _headCell('$y年',
                  _SortKey('year$y', (row) => row.yearlyWin[y] ?? -1), cellW, sortKey),
          ],
        ),
      );

  Widget _headCell(String label, _SortKey key, double w, _SortKey active) =>
      SizedBox(
        width: w,
        child: InkWell(
          onTap: () => _sortBy(key),
          child: Column(
            crossAxisAlignment: key.num == null
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.end,
            children: [
              Text(label,
                  textAlign: key.num == null ? TextAlign.left : TextAlign.right,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
              if (active.id == key.id)
                Icon(_desc ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                    size: 14, color: AppColors.dim),
            ],
          ),
        ),
      );

  Widget _dataRow(_Row row, List<int> hs, List<int> years, Color accent,
          double nameW, double cellW) =>
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
}
