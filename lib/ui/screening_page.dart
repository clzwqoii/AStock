/// 选股页 · 方案C 高密度工作台：左侧规则开关分组 + 右侧工具栏/密集表格/状态栏。
/// 布局参照 docs/design/c-compact-workbench.html。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_logic.dart';
import '../core/backtest.dart';
import '../core/rules.dart';
import 'colors.dart';
import 'stock_detail_page.dart';

typedef ScreenFn =
    Future<
            ({int total, List<ScreenRow> picked, String? dataDate, int blockedStale,
                int blockedCorporateAction, int blockedSuspension})>
        Function(String dbPath, List<Rule> rules);

/// 长任务加载模态（居中卡片）：大号强调色转圈 + 标题 + 可选副标题，
/// 带遮罩挡住重复点击。选股/网络自检/检查更新共用。
class LoadingDialog extends StatelessWidget {
  const LoadingDialog({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Container(
        width: 216,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
                width: 38,
                height: 38,
                child: CircularProgressIndicator(strokeWidth: 3, color: accent)),
            const SizedBox(height: 16),
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11, color: AppColors.dim)),
            ],
          ],
        ),
      ),
    );
  }
}

/// CSV 导出（默认写数据库同目录；测试注入假实现，避免真实 IO）。
typedef ExportCsvFn = Future<String> Function(List<ScreenRow> rows,
    {String? dataDate, String? combo});

/// 规则分组（展示用，引擎不感知）。「有效突破」包含两种突破模式 + 两条宽松 MA60 规则。
const ruleGroups = <String, List<String>>{
  '趋势': [
    'close_above_ma20',
    'ma5_golden_ma10',
    'macd_golden_cross',
    'kdj_golden_cross',
  ],
  '超买超卖': ['rsi_oversold', 'rsi_overbought'],
  // 组内顺序即默认展示顺序。宽松版 RSI超卖·放量 放最前：按 tool/rule_by_month.dart
  // 的分档结果，它是当前主力（三种市况下都有足够样本量的正超额），
  // 且这个组按胜率排本就是侧栏第一组，于是它就是列表第一个开关。
  '量能 / 动量': [
    'rsi_oversold_volume_loose',
    'rsi_oversold_volume',
    'volume_surge',
    'pct_change_up',
  ],
  '年线过滤': ['ma250_up', 'near_ma250'],
  '有效突破': [
    'ma60_breakout_bull',
    'ma60_breakout_confirmed',
    'ma60_breakout_pullback',
    'ma60_breakout_now',
    'close_above_ma60',
    'ma60_breakout',
  ],
  '中枢突破': ['pivot_breakout', 'pivot_breakout_pullback'],
};

class ScreeningPage extends StatefulWidget {
  const ScreeningPage({
    super.key,
    required this.dbPath,
    this.screenFn = runScreening,
    this.syncing = false,
    this.syncStatus,
    this.onOpenSettings,
    this.onOpenBacktest,
    this.exportCsv,
    this.backtestReport,
  });

  final String dbPath;
  final ScreenFn screenFn;

  /// 来自外壳的自动同步状态。
  final bool syncing;
  final String? syncStatus;

  /// 侧栏「设置」按钮回调（外壳弹出设置弹框）。
  final VoidCallback? onOpenSettings;

  /// 侧栏「回测对比」按钮回调（外壳切到回测页）；null 时按钮隐藏。
  final VoidCallback? onOpenBacktest;

  /// CSV 导出；null 时写数据库同目录（桌面 ~/.stock、移动端沙盒）。
  final ExportCsvFn? exportCsv;

  /// 回测报告缓存（外壳读一次、两页共用）。非 null 时规则列表在名字下方
  /// 显示该规则的 10 日胜率 / 盈亏比 / 信号数；回测完成后由外壳刷新。
  final BacktestReport? backtestReport;

  @override
  State<ScreeningPage> createState() => _ScreeningPageState();
}

class _ScreeningPageState extends State<ScreeningPage> {
  final _selected = <String>{};
  bool _loading = false;
  String? _error;
  ({int total, List<ScreenRow> picked, String? dataDate, int blockedStale,
      int blockedCorporateAction, int blockedSuspension})? _result;

  /// 当前排序列与方向；null = 引擎返回顺序。
  SortField? _sortField;
  bool _sortAsc = false;

  /// 当前展示顺序的入选行（排序只影响展示与导出，不改引擎结果）。
  /// 缓存排序结果：ListView 的 itemBuilder 每渲染一行都取一次，
  /// 现场排序会在命中数大时每行全量重排（滚动掉帧）。
  List<ScreenRow> _sortedRows = const [];

  /// [_result] / [_sortField] / [_sortAsc] 变化后重算展示顺序。
  void _reSort() {
    final r = _result;
    if (r == null) {
      _sortedRows = const [];
    } else if (_sortField == null) {
      _sortedRows = r.picked;
    } else {
      _sortedRows = sortRows(r.picked, _sortField!, ascending: _sortAsc);
    }
  }

  /// 表头点击：同列切换升降序，换列默认降序。
  void _sortBy(SortField field) {
    setState(() {
      if (_sortField == field) {
        _sortAsc = !_sortAsc;
      } else {
        _sortField = field;
        _sortAsc = false;
      }
      _reSort();
    });
  }

  Future<void> _export() async {
    final r = _result;
    if (r == null || r.picked.isEmpty) return;
    final rows = _sortedRows;
    final combo = _selected.isEmpty ? '全部' : _selected.map((id) => ruleById(id).name).join(' ∧ ');
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await (widget.exportCsv ??
          (rows, {dataDate, combo}) => exportRowsCsv(
                rows,
                dirPath: File(widget.dbPath).parent.path,
                dataDate: dataDate,
                combo: combo,
              ))(rows, dataDate: r.dataDate, combo: combo);
      messenger.showSnackBar(SnackBar(content: Text('已导出 $path')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
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
      _result = await widget.screenFn(widget.dbPath, rules);
      _reSort();
    } catch (e) {
      _error = e.toString();
    } finally {
      navigator.pop();
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 768;
      final sidebar = _sidebar();
      final main = Expanded(child: _main(wide));
      return ColoredBox(
        color: AppColors.bg,
        // stretch：侧栏必须拉伸到窗口全高，否则规则区被压缩、底部设置块会盖住溢出的规则行
        child: wide
            ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [sidebar, main])
            : Column(children: [_ruleChipBar(), main]),
      );
    });
  }

  // ── 侧栏 ──────────────────────────────────────────────────────────

  Widget _sidebar() => Container(
        width: 236,
        color: Colors.white,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 18, 18, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('A股选股台',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.text)),
                  SizedBox(height: 2),
                  Text('Stock Screener v$kAppVersion', style: TextStyle(fontSize: 11, color: AppColors.dim)),
                ],
              ),
            ),
            Container(height: 1, color: const Color(0xFFE8EAEF)),
            Expanded(
              // ponytail: 规则总数固定且不大，直接全量构建（组件测试与低高度屏都不会懒加载丢项）；
              // 规则多到一屏放不下时再改回 ListView。
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 分组按「组内最高 10 日胜率」降序，组内再按胜率降序
                    for (final e in ruleGroupsSortedByWinRate(
                        ruleGroups, widget.backtestReport)) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
                        child: Text(e.key.toUpperCase(),
                            style: const TextStyle(
                                fontSize: 10, letterSpacing: 2, color: AppColors.dim, fontWeight: FontWeight.w700)),
                      ),
                      // 组内按 10 日胜率降序（无报告时保持声明顺序）
                      for (final id in ruleIdsSortedByWinRate(e.value, widget.backtestReport,
                              pinFirst: kMainRuleId))
                        _switchRow(ruleById(id)),
                    ],
                  ],
                ),
              ),
            ),
            Container(
              height: 1,
              color: const Color(0xFFE8EAEF),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.onOpenBacktest != null) ...[
                    OutlinedButton.icon(
                      onPressed: widget.onOpenBacktest,
                      icon: const Icon(Icons.query_stats_outlined, size: 16),
                      label: const Text('回测对比', style: TextStyle(fontSize: 13)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.text,
                        side: const BorderSide(color: AppColors.border),
                        minimumSize: const Size(double.infinity, 34),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  OutlinedButton.icon(
                    onPressed: widget.onOpenSettings,
                    icon: const Icon(Icons.settings_outlined, size: 16),
                    label: const Text('设置', style: TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.text,
                      side: const BorderSide(color: AppColors.border),
                      minimumSize: const Size(double.infinity, 34),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text('数据源：tushare pro\n本地库 SQLite',
                      style: TextStyle(fontSize: 11, color: AppColors.dim, height: 1.6)),
                ],
              ),
            ),
          ],
        ),
      );

  /// 规则名下的回测统计行：`2026年 +0.07% · 超额 +0.48pp · 基准 -0.41%`。
  /// 没有回测报告、该年样本不足或当年基准缺失时返回空（不占高度）。
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
      padding: const EdgeInsets.only(top: 1),
      child: Text(
        line.label,
        style: TextStyle(
          fontSize: 9,
          color: line.excessPp >= 0 ? upDown.up : upDown.down,
        ),
      ),
    );
  }

  Widget _switchRow(Rule rule) => InkWell(
        onTap: () => _toggle(rule.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(rule.name,
                        style: TextStyle(
                            fontSize: 13,
                            color: AppColors.text,
                            fontWeight: _selected.contains(rule.id)
                                ? FontWeight.w600
                                : FontWeight.w400)),
                    _statLine(rule),
                  ],
                ),
              ),
              Transform.scale(
                scale: 0.82,
                child: Switch(
                  value: _selected.contains(rule.id),
                  activeThumbColor: Colors.white,
                  thumbColor: const WidgetStatePropertyAll(Colors.white),
                  trackColor: WidgetStateProperty.resolveWith(
                    (s) => s.contains(WidgetState.selected)
                        ? AccentScope.of(context)
                        : AppColors.switchOff,
                  ),
                  trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (_) => _toggle(rule.id),
                ),
              ),
            ],
          ),
        ),
      );

  /// 窄屏（手机）：规则以横向滚动胶囊条替代侧栏。
  Widget _ruleChipBar() => Container(
        color: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final e in ruleGroups.entries)
                for (final id in e.value)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _chip(ruleById(id)),
                  ),
            ],
          ),
        ),
      );

  Widget _chip(Rule rule) {
    final on = _selected.contains(rule.id);
    final accent = AccentScope.of(context);
    return GestureDetector(
      onTap: () => _toggle(rule.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: on ? accent.withValues(alpha: 0.09) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: on ? accent : AppColors.border),
        ),
        child: Text(rule.name,
            style: TextStyle(
                fontSize: 12, color: on ? accent : AppColors.text, fontWeight: on ? FontWeight.w600 : FontWeight.w400)),
      ),
    );
  }

  // ── 主区 ──────────────────────────────────────────────────────────

  Widget _main(bool wide) => Column(
        children: [
          _toolbar(wide),
          if (_loading)
            LinearProgressIndicator(minHeight: 2, color: AccentScope.of(context)),
          // 表格列多，窄窗口横向滚动而不是溢出
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => _resultArea(wide, box.maxWidth),
            ),
          ),
          _statusBar(),
        ],
      );

  Widget _toolbar(bool wide) => Container(
        height: 54,
        color: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('选股结果',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.text)),
                  Text(_comboText(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: AppColors.dim)),
                ],
              ),
            ),
            _syncPill(),
            const SizedBox(width: 14),
            if (!wide)
              IconButton(
                tooltip: '设置',
                onPressed: widget.onOpenSettings,
                icon: const Icon(Icons.settings_outlined, size: 20),
                color: AppColors.text,
              ),
            if (_result?.picked.isNotEmpty ?? false)
              IconButton(
                tooltip: '导出 CSV',
                onPressed: _export,
                icon: const Icon(Icons.file_download_outlined, size: 19),
                color: AppColors.dim,
              ),
            FilledButton(
              onPressed: _selected.isEmpty || _loading ? null : _run,
              style: FilledButton.styleFrom(
                backgroundColor: AccentScope.of(context),
                minimumSize: const Size(96, 34),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 2),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
              ),
              child: const Text('开始选股'),
            ),
          ],
        ),
      );

  String _comboText() {
    final r = _result;
    if (r != null && _selected.isNotEmpty) {
      return '组合：${_selected.map((id) => ruleById(id).name).join(' ∧ ')}';
    }
    return '勾选左侧规则（可多选 = 组合，全部满足才入选）';
  }

  Widget _syncPill() {
    final date = _result?.dataDate;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: const Color(0xFFF2F4F7), borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
                color: widget.syncing ? Colors.orange : const Color(0xFF0A8F62),
                shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            widget.syncing
                ? '同步中'
                : date != null
                    ? '已同步 $date'
                    : (widget.syncStatus ?? '').contains('同步完成')
                        ? '已同步'
                        : '未同步',
            style: const TextStyle(fontSize: 12, color: Color(0xFF5B6572)),
          ),
        ],
      ),
    );
  }

  Widget _resultArea(bool wide, double availableW) {
    if (_error != null) {
      return _centerHint('选股失败：$_error', color: Colors.red);
    }
    final r = _result;
    if (r == null) {
      return _centerHint('勾选规则后点「开始选股」');
    }
    if (r.total == 0) {
      return _centerHint('本地库暂无数据，请等自动同步完成或在「设置」页手动同步');
    }
    if (r.picked.isEmpty) {
      return _centerHint('没有股票满足所选规则');
    }
    // 内容最小宽度：列全展开不挤压，超出部分靠横向滚动（桌面窗口拖窄也不会溢出）
    final tableW = math.max(availableW, wide ? 900.0 : 560.0);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: tableW,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, // 名称列定宽后表头不再自然满宽，强制撑满
          children: [
            _headerRow(wide),
            Expanded(
              child: ListView.builder(
                // 行高固定（_row 外层 Container），声明后省略逐行测量
                itemExtent: 34,
                itemCount: _sortedRows.length,
                itemBuilder: (_, i) => _row(_sortedRows[i], i, wide),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _centerHint(String text, {Color? color}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text, style: TextStyle(fontSize: 13, color: color ?? AppColors.dim)),
        ),
      );

  Widget _headerCell(String text, double? width, {bool left = false}) {
    final padded = Padding(
      padding: EdgeInsets.only(left: left ? 20 : 0, right: left ? 0 : 14),
      child: Text(text,
          textAlign: left ? TextAlign.left : TextAlign.right,
          style: const TextStyle(
              fontSize: 10, letterSpacing: 0.5, color: AppColors.dim, fontWeight: FontWeight.w700)),
    );
    return width == null ? Expanded(child: padded) : SizedBox(width: width, child: padded);
  }

  Widget _headerRow(bool wide) => Container(
        height: 32,
        color: AppColors.headerBg,
        child: Row(
          children: wide
              ? [
                  _headerCell('代码', 104, left: true),
                  _headerCell('名称', 96, left: true), // 定宽（约6个汉字，更长省略）：弹性会把宽窗口的空白全吃进名称列
                  // 买卖决策要看的四个字段紧跟名称，不用横向滚动去找
                  _sortableHeader('评分', 52, SortField.score),
                  _sortableHeader('目标', 60, null),
                  _sortableHeader('止损', 60, null),
                  _sortableHeader('盈亏比', 50, SortField.riskReward),
                  _sortableHeader('收盘', 64, SortField.close),
                  _sortableHeader('涨跌', 64, null),
                  _sortableHeader('涨跌幅', 78, SortField.changePct),
                  // 超卖/放量类规则选出来的必然是"已经跌了很多"的票。
                  // 只看当日涨跌幅会让人以为在追强势股，这一列把"抄了多深的底"
                  // 摆在明处。不可排序：它是叙述性信息，不是排序维度。
                  _headerCell('20日%', 64),
                  _sortableHeader('量比', 56, SortField.volumeRatio),
                  _sortableHeader('成交额(万)', 84, SortField.amount), // 定宽：右对齐数字列被拉宽会留大片空白
                  _sortableHeader('MA20', 64, SortField.ma20),
                ]
              : [
                  _headerCell('代码', 104, left: true),
                  _headerCell('名称', null, left: true), // 弹性列吃剩余宽度
                  _sortableHeader('收盘', 64, SortField.close),
                  _sortableHeader('涨跌幅', 78, SortField.changePct),
                ],
        ),
      );

  /// 可排序表头：点一下降序，再点升序；当前列名加粗并显示箭头。
  /// width 传 null 时用 Expanded 吃剩余宽度（成交额列）。
  Widget _sortableHeader(String text, double? width, SortField? field) {
    final active = field != null && _sortField == field;
    final style = TextStyle(
        fontSize: 10,
        letterSpacing: 0.5,
        fontWeight: active ? FontWeight.w900 : FontWeight.w700,
        color: active ? AppColors.text : AppColors.dim);
    final inner = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: field == null ? null : () => _sortBy(field),
      child: Container(
        height: 32,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 14),
        width: width,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, style: style),
            if (active) ...[
              const SizedBox(width: 2),
              Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
                  size: 10, color: AccentScope.of(context)),
            ],
          ],
        ),
      ),
    );
    return width == null ? Expanded(child: inner) : inner;
  }

  void _openDetail(ScreenRow row) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StockDetailPage(dbPath: widget.dbPath, symbol: row.symbol, name: row.name),
    ));
  }

  Widget _row(ScreenRow row, int index, bool wide) {
    final bg = index.isEven ? Colors.white : AppColors.zebra;
    final changeStyle = TextStyle(
        fontSize: 12.5,
        color: row.change >= 0 ? AppColors.red : AppColors.down,
        fontFeatures: const [FontFeature.tabularFigures()]);
    final pctStyle = TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        color: row.changePct >= 0 ? AppColors.red : AppColors.down,
        fontFeatures: const [FontFeature.tabularFigures()]);
    final plain = TextStyle(
        fontSize: 12.5, color: AppColors.text, fontFeatures: const [FontFeature.tabularFigures()]);

    Widget cell(String text, double? width, TextStyle style, {bool left = false}) {
      final padded = Padding(
        padding: EdgeInsets.only(left: left ? 20 : 0, right: left ? 0 : 14),
        child: Text(text,
            textAlign: left ? TextAlign.left : TextAlign.right,
            overflow: TextOverflow.ellipsis,
            style: style),
      );
      return width == null ? Expanded(child: padded) : SizedBox(width: width, child: padded);
    }

    // 名称定宽（宽表）；窄表仍是弹性列吃剩余宽度（手机上只有 4 列）
    final nameCell = cell(row.name ?? '—', wide ? 96 : null,
        const TextStyle(fontSize: 12, color: AppColors.dim), left: true);

    return GestureDetector(
      onTap: () => _openDetail(row),
      child: Container(
      height: 34,
      color: bg,
      child: Row(
        children: wide
            ? [
                cell(row.symbol, 104, plain.copyWith(fontWeight: FontWeight.w600), left: true),
                nameCell,
                cell(_scoreCell(row), 52, _scoreStyle(row)),
                cell(row.forecast?.target?.toStringAsFixed(2) ?? '', 60,
                    plain.copyWith(color: AppColors.red)),
                cell(row.forecast?.stop?.toStringAsFixed(2) ?? '', 60,
                    plain.copyWith(color: AppColors.down)),
                cell(row.forecast?.riskReward?.toStringAsFixed(2) ?? '', 50, plain),
                cell(_f2(row.close), 64, plain.copyWith(fontWeight: FontWeight.w600)),
                cell(_signed(row.change), 64, changeStyle),
                cell(_signed(row.changePct, suffix: '%'), 78, pctStyle),
                cell(_signed(row.ret20, suffix: '%'), 64,
                    TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: row.ret20 >= 0 ? AppColors.red : AppColors.down,
                        fontFeatures: const [FontFeature.tabularFigures()])),
                cell(_f2(row.volumeRatio), 56, plain),
                cell(row.amountWan.toStringAsFixed(0), 84, plain),
                cell(_f2(row.ma20), 64, plain),
              ]
            : [
                cell(row.symbol, 104, plain.copyWith(fontWeight: FontWeight.w600), left: true),
                nameCell,
                cell(_f2(row.close), 64, plain.copyWith(fontWeight: FontWeight.w600)),
                cell(_signed(row.changePct, suffix: '%'), 78, pctStyle),
              ],
      ),
      ),
    );
  }

  String _f2(double v) => v.toStringAsFixed(2);

  /// 评分单元格文案。用户选的是 A/B/C 分档，所以数字后面跟档位字。
  ///
  /// 无评分时返回**空串**而不是 '—'：表格里 '—' 是"名称缺失"的占位符，
  /// 新列再返一回会让按文本查找的自动化测试与依赖语义的代码都分不清
  /// 到底是哪个字段缺了。空单元格本身就是"无数据"的标准表示。
  String _scoreCell(ScreenRow row) {
    final sc = row.score;
    if (sc == null) return '';
    return '${sc.score.toStringAsFixed(0)}·${sc.tier}';
  }

  /// 按档位上色，让"高/中/低"在扫视时就能分辨。
  TextStyle _scoreStyle(ScreenRow row) {
    final sc = row.score;
    final base = TextStyle(
        fontSize: 12.5, fontFeatures: const [FontFeature.tabularFigures()]);
    if (sc == null) return base.copyWith(color: AppColors.dim);
    if (sc.lowConfidence) return base.copyWith(color: AppColors.dim);
    final color = sc.tier == '高'
        ? AppColors.red
        : sc.tier == '中'
            ? AppColors.text
            : AppColors.down;
    return base.copyWith(color: color, fontWeight: FontWeight.w700);
  }

  String _signed(double v, {String suffix = ''}) =>
      '${v >= 0 ? '+' : '-'}${v.abs().toStringAsFixed(2)}$suffix';

  Widget _statusBar() {
    final r = _result;
    return Container(
      height: 30,
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          _sbItem('全市场', r == null ? '—' : '${r.total}'),
          const SizedBox(width: 20),
          _sbItem('入选', r == null ? '—' : '${r.picked.length}',
              color: AccentScope.of(context)),
          const SizedBox(width: 20),
          _sbItem('已选规则', '${_selected.length}'),
          const SizedBox(width: 20),
          if (r != null &&
              r.blockedStale + r.blockedCorporateAction + r.blockedSuspension > 0)
            _sbItem(
              '过滤假信号',
              '${r.blockedStale + r.blockedCorporateAction + r.blockedSuspension}',
              color: AppColors.down,
            ),
          const Spacer(),
          Flexible(
            child: Text(
              widget.syncStatus ?? (r?.dataDate != null ? '数据截至 ${r!.dataDate}' : '尚未同步'),
              style: const TextStyle(fontSize: 11, color: AppColors.dim),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sbItem(String label, String value, {Color? color}) => Text.rich(
        TextSpan(
          text: '$label ',
          style: const TextStyle(fontSize: 11, color: AppColors.dim),
          children: [
            TextSpan(
                text: value,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color ?? AppColors.text)),
          ],
        ),
      );
}
