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
  });

  final String dbPath;
  final String symbol;
  final String? name;

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
    final d = await loadStockDetail(widget.dbPath, widget.symbol);
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
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < 3; i++) ...[
                          _legend('MA${i == 0 ? 5 : i == 1 ? 10 : 20}', _maColors[i]),
                          const SizedBox(width: 16),
                        ],
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

const _maColors = [Color(0xFFF59E0B), Color(0xFF3B82F6), Color(0xFF8B5CF6)];
