/// 选股页 · 方案C 高密度工作台：左侧规则开关分组 + 右侧工具栏/密集表格/状态栏。
/// 布局参照 docs/design/c-compact-workbench.html。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_logic.dart';
import '../core/rules.dart';
import 'colors.dart';
import 'stock_detail_page.dart';

typedef ScreenFn = Future<({int total, List<ScreenRow> picked, String? dataDate})> Function(
    String dbPath, List<Rule> rules);

/// CSV 导出（默认写数据库同目录；测试注入假实现，避免真实 IO）。
typedef ExportCsvFn = Future<String> Function(List<ScreenRow> rows,
    {String? dataDate, String? combo});

/// 规则分组（展示用，引擎不感知）。
const ruleGroups = <String, List<String>>{
  '趋势': ['close_above_ma20', 'ma5_golden_ma10', 'macd_golden_cross'],
  '超买超卖': ['rsi_oversold', 'rsi_overbought'],
  '量能 / 动量': ['volume_surge', 'pct_change_up'],
};

class ScreeningPage extends StatefulWidget {
  const ScreeningPage({
    super.key,
    required this.dbPath,
    this.screenFn = runScreening,
    this.syncing = false,
    this.syncStatus,
    this.onOpenSettings,
    this.exportCsv,
  });

  final String dbPath;
  final ScreenFn screenFn;

  /// 来自外壳的自动同步状态。
  final bool syncing;
  final String? syncStatus;

  /// 侧栏「设置」按钮回调（外壳弹出设置弹框）。
  final VoidCallback? onOpenSettings;

  /// CSV 导出；null 时写数据库同目录（桌面 ~/.stock、移动端沙盒）。
  final ExportCsvFn? exportCsv;

  @override
  State<ScreeningPage> createState() => _ScreeningPageState();
}

class _ScreeningPageState extends State<ScreeningPage> {
  final _selected = <String>{};
  bool _loading = false;
  String? _error;
  ({int total, List<ScreenRow> picked, String? dataDate})? _result;

  /// 当前排序列与方向；null = 引擎返回顺序。
  SortField? _sortField;
  bool _sortAsc = false;

  /// 当前展示顺序的入选行（排序只影响展示与导出，不改引擎结果）。
  List<ScreenRow> _rows() {
    final r = _result;
    if (r == null) return const [];
    final field = _sortField;
    if (field == null) return r.picked;
    return sortRows(r.picked, field, ascending: _sortAsc);
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
    });
  }

  Future<void> _export() async {
    final r = _result;
    if (r == null || r.picked.isEmpty) return;
    final rows = _rows();
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
    try {
      final rules = [for (final id in _selected) ruleById(id)];
      _result = await widget.screenFn(widget.dbPath, rules);
    } catch (e) {
      _error = e.toString();
    } finally {
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
              // ponytail: 规则固定 7 条直接全量构建（组件测试与低高度屏都不会懒加载丢项）；
              // 规则多到一屏放不下时再改回 ListView。
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final e in ruleGroups.entries) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
                        child: Text(e.key.toUpperCase(),
                            style: const TextStyle(
                                fontSize: 10, letterSpacing: 2, color: AppColors.dim, fontWeight: FontWeight.w700)),
                      ),
                      for (final id in e.value) _switchRow(ruleById(id)),
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

  Widget _switchRow(Rule rule) => InkWell(
        onTap: () => _toggle(rule.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
          child: Row(
            children: [
              Expanded(
                child: Text(rule.name,
                    style: TextStyle(
                        fontSize: 13,
                        color: AppColors.text,
                        fontWeight: _selected.contains(rule.id) ? FontWeight.w600 : FontWeight.w400)),
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
          // 表格列多（含命中规则），窄窗口横向滚动而不是溢出
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
    final tableW = math.max(availableW, wide ? 980.0 : 560.0);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: tableW,
        child: Column(
          children: [
            _headerRow(wide),
            Expanded(
              child: ListView.builder(
                itemCount: _rows().length,
                itemBuilder: (_, i) => _row(_rows()[i], i, wide),
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
                  _headerCell('名称', null, left: true),
                  _sortableHeader('收盘', 56, SortField.close),
                  _sortableHeader('涨跌', 56, null),
                  _sortableHeader('涨跌幅', 68, SortField.changePct),
                  _sortableHeader('量比', 48, SortField.volumeRatio),
                  _sortableHeader('成交额(万)', 90, SortField.amount),
                  _sortableHeader('MA20', 56, SortField.ma20),
                ]
              : [
                  _headerCell('代码', 104, left: true),
                  _headerCell('名称', null, left: true),
                  _sortableHeader('收盘', 56, SortField.close),
                  _sortableHeader('涨跌幅', 68, SortField.changePct),
                  _headerCell('命中规则', 132, left: true),
                ],
        ),
      );

  /// 可排序表头：点一下降序，再点升序；当前列名加粗并显示箭头。
  Widget _sortableHeader(String text, double width, SortField? field) {
    final active = field != null && _sortField == field;
    final style = TextStyle(
        fontSize: 10,
        letterSpacing: 0.5,
        fontWeight: active ? FontWeight.w900 : FontWeight.w700,
        color: active ? AppColors.text : AppColors.dim);
    return GestureDetector(
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

    Widget cell(String text, double? width, TextStyle style, {bool left = false}) => SizedBox(
          width: width,
          child: Padding(
            padding: EdgeInsets.only(left: left ? 20 : 0, right: left ? 0 : 14),
            child: Text(text,
                textAlign: left ? TextAlign.left : TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: style),
          ),
        );

    final nameCell = Expanded(
      child: Padding(
        padding: const EdgeInsets.only(right: 14),
        child: Text(row.name ?? '—',
            style: const TextStyle(fontSize: 12, color: AppColors.dim), overflow: TextOverflow.ellipsis),
      ),
    );

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
                cell(_f2(row.close), 56, plain.copyWith(fontWeight: FontWeight.w600)),
                cell(_signed(row.change), 56, changeStyle),
                cell(_signed(row.changePct, suffix: '%'), 68, pctStyle),
                cell(_f2(row.volumeRatio), 48, plain),
                cell(row.amountWan.toStringAsFixed(0), 90, plain),
                cell(_f2(row.ma20), 56, plain),
                _hitCell(row.matchedRules),
              ]
            : [
                cell(row.symbol, 104, plain.copyWith(fontWeight: FontWeight.w600), left: true),
                nameCell,
                cell(_f2(row.close), 56, plain.copyWith(fontWeight: FontWeight.w600)),
                cell(_signed(row.changePct, suffix: '%'), 68, pctStyle),
                _hitCell(row.matchedRules),
              ],
      ),
      ),
    );
  }

  String _f2(double v) => v.toStringAsFixed(2);

  String _signed(double v, {String suffix = ''}) =>
      '${v >= 0 ? '+' : '-'}${v.abs().toStringAsFixed(2)}$suffix';

  /// 命中规则单元格：多条用「＋」连接，超出宽度省略，悬停看全量。
  Widget _hitCell(List<String> rules) {
    final text = rules.join('＋'); // 空 = 引擎未回填；不显示「—」以免与名称缺失的占位符混淆
    return SizedBox(
      width: 132,
      child: Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Tooltip(
          message: rules.isEmpty ? '' : text,
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11.5,
                  color: rules.isEmpty ? AppColors.dim : AppColors.text,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ),
      ),
    );
  }

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
