/// 移动原生布局（窄屏 <768）：红色渐变头部 + 统计卡 + 折叠规则面板 +
/// 大按钮 + 结果卡片，底部导航切换 选股/设置。样机见 docs/design/mobile-native.html。
library;

import 'package:flutter/material.dart';

import '../app_logic.dart';
import '../core/rules.dart';
import 'colors.dart';
import 'onboarding.dart' show LaunchUrlFn;
import 'stock_detail_page.dart';
import 'screening_page.dart' show ruleGroups, ScreenFn;
import 'settings_page.dart';

class MobileHome extends StatefulWidget {
  const MobileHome({
    super.key,
    required this.dbPath,
    required this.syncing,
    required this.syncMsg,
    required this.accent,
    required this.onAccentChanged,
    required this.onSyncPressed,
    required this.configPath,
    required this.initialToken,
    this.screenFn,
    this.launchUrl,
  });

  final String dbPath;
  final ScreenFn? screenFn;
  final bool syncing;
  final String? syncMsg;
  final AccentColor accent;
  final ValueChanged<AccentColor> onAccentChanged;
  final VoidCallback onSyncPressed;
  final String configPath;
  final String initialToken;
  final LaunchUrlFn? launchUrl;

  @override
  State<MobileHome> createState() => _MobileHomeState();
}

class _MobileHomeState extends State<MobileHome> {
  int _tab = 0;

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
          ),
          SafeArea(
            child: SettingsPage(
              initialToken: widget.initialToken,
              configPath: widget.configPath,
              dbPath: widget.dbPath,
              syncing: widget.syncing,
              syncMsg: widget.syncMsg,
              onSyncPressed: widget.onSyncPressed,
              accent: widget.accent,
              onAccentChanged: widget.onAccentChanged,
              launchUrl: widget.launchUrl,
            ),
          ),
        ],
      ),
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
    this.screenFn,
  });

  final String dbPath;
  final ScreenFn? screenFn;
  final bool syncing;
  final String? syncMsg;

  @override
  State<MobileScreening> createState() => _MobileScreeningState();
}

class _MobileScreeningState extends State<MobileScreening> {
  final _selected = <String>{};
  bool _expanded = true;
  bool _loading = false;
  String? _error;
  ({int total, List<ScreenRow> picked, String? dataDate})? _result;

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
      _result = await (widget.screenFn ?? runScreening)(widget.dbPath, rules);
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
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
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(18, top + 14, 18, 22),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFD7263D), Color(0xFFA01C33)],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(26)),
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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
    final d = _result?.dataDate;
    if (d != null && d.length >= 8) {
      return '已同步 ${d.substring(4, 6)}-${d.substring(6)}';
    }
    return '未同步';
  }

  Widget _stats() {
    final r = _result;
    final msg = widget.syncMsg;
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
              for (final e in ruleGroups.entries)
                for (final id in e.value)
                  _ruleRow(ruleById(id), e.key, accent),
          ],
        ),
      );

  Widget _ruleRow(Rule rule, String category, Color accent) {
    final on = _selected.contains(rule.id);
    return InkWell(
      onTap: () => _toggle(rule.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFF2F3F7)))),
        child: Row(
          children: [
            Expanded(child: Text(rule.name, style: const TextStyle(fontSize: 14))),
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
                  if (row.matchedRules.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final r in row.matchedRules)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: AccentScope.of(context).withValues(alpha: 0.09),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(r,
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: AccentScope.of(context))),
                          ),
                      ],
                    ),
                  ],
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
      ),
      );
}
