/// 个股详情页：日K蜡烛图 + 末日指标数值。桌面与移动共用，卡片点击进入。
library;

import 'package:flutter/material.dart';

import '../app_logic.dart';
import 'candle_chart.dart';
import 'colors.dart';

class StockDetailPage extends StatefulWidget {
  const StockDetailPage({
    super.key,
    required this.dbPath,
    required this.symbol,
    this.name,
    this.loadFn = loadStockDetail,
  });

  final String dbPath;
  final String symbol;
  final String? name;

  /// 详情加载；测试注入假实现（widget 测试在 FakeAsync 区，真实 IO 完成事件等不到）。
  final Future<StockDetail?> Function(String dbPath, String symbol) loadFn;

  @override
  State<StockDetailPage> createState() => _StockDetailPageState();
}

class _StockDetailPageState extends State<StockDetailPage> {
  StockDetail? _detail;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await widget.loadFn(widget.dbPath, widget.symbol);
    if (mounted) setState(() => _detail = d);
  }

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.name ?? widget.symbol,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            Text(widget.symbol, style: const TextStyle(fontSize: 11, color: AppColors.dim)),
          ],
        ),
      ),
      body: _detail == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Column(
                children: [
                  _infoStrip(accent),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: CandleChart(bars: _detail!.bars),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 14),
                    // 5 条均线图例在窄屏一行放不下，Wrap 自动换行
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 14,
                      runSpacing: 4,
                      children: [
                        for (var i = 0; i < maPeriods.length; i++)
                          _legend('MA${maPeriods[i]}', maColors[i]),
                        const Text('· 不复权 · 手', style: TextStyle(fontSize: 10, color: AppColors.dim)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _infoStrip(Color accent) {
    final d = _detail!;
    final snap = d.snapshot;
    final pct = snap.pctChange;
    final pctStyle = TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: pct >= 0 ? AppColors.red : AppColors.down);
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('收盘', style: TextStyle(fontSize: 10, color: AppColors.dim)),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(snap.close.toStringAsFixed(2),
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                    const SizedBox(width: 8),
                    Text(
                        '${pct >= 0 ? '+' : '-'}${pct.abs().toStringAsFixed(2)}%',
                        style: pctStyle),
                  ],
                ),
              ],
            ),
            const SizedBox(width: 14),
            _kv('RSI14', snap.rsi14.toStringAsFixed(1)),
            const SizedBox(width: 14),
            _kv('量比', snap.volumeRatio.toStringAsFixed(2)),
            const SizedBox(width: 14),
            _kv('MA20', snap.ma20.toStringAsFixed(2)),
          ],
        ),
      ),
    );
  }

  Widget _kv(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(label, style: const TextStyle(fontSize: 10, color: AppColors.dim)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700, fontFeatures: [])),
        ],
      );

  Widget _legend(String label, Color color) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 10, color: AppColors.dim)),
        ],
      );
}
