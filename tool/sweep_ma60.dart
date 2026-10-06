/// 「MA60 上穿」过滤项穷举：一遍扫描收集全部上穿事件（含逐项过滤结果与前瞻收益），
/// 之后任意过滤组合都只是对事件集做布尔过滤，256 个组合几乎零成本。
///
/// 回答的问题：裸 MA60 上穿已经能跑赢基准（见 bin/backtest.dart），
/// 那么**再加资金/量能/趋势类确认，究竟哪一项有增量、哪一项是负贡献**。
///
/// 用法: dart run tool/sweep_ma60.dart [--days 5,10,20] [--db 路径] [--top 15]
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:stock/config.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';

/// 过滤项的中文短名（表头用）。
const _labels = <Ma60Filter, String>{
  Ma60Filter.breakoutPct: '幅度≥3%',
  Ma60Filter.volumeWindow: '量比1.5~6',
  Ma60Filter.amountRatio: '额比≥1.5',
  Ma60Filter.closePos: '收盘位置', // 资金流入的 OHLCV 代理
  Ma60Filter.bullAlignment: '多头排列',
  Ma60Filter.ma60Rising: 'MA60上翘',
  Ma60Filter.digestedBelow: '突破前盘整',
  Ma60Filter.noChase: '乖离≤15%',
  Ma60Filter.ma250Up: '年线上翘',
  Ma60Filter.nearMa250: '站上年线',
};

/// 一次「MA60 上穿」事件：前瞻收益 + 各过滤项的通过情况。
class _Event {
  _Event(this.fwd, this.passed);
  final double fwd;
  final Set<Ma60Filter> passed;
}

Future<void> main(List<String> args) async {
  final days = <int>[];
  var top = 15;
  String? dbPath;

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a.startsWith('--days=')) {
      days.addAll(a.substring(7).split(',').map(int.parse));
    } else if (a == '--days' && i + 1 < args.length) {
      days.addAll(args[++i].split(',').map(int.parse));
    } else if (a.startsWith('--top=')) {
      top = int.parse(a.substring(6));
    } else if (a == '--db' && i + 1 < args.length) {
      dbPath = args[++i];
    }
  }
  final horizons = days.isEmpty ? [5, 10, 20] : days;

  final repo = BarRepository(dbPath ?? AppConfig.load().dbPath);
  final stocks = repo.loadAllStocks();
  repo.close();
  final all = Ma60Filter.values;

  for (final h in horizons) {
    final events = <_Event>[];
    final baseReturns = <double>[];
    for (final stock in stocks) {
      final bars = stock.bars;
      if (evaluableDays(bars.length, h) == 0) continue;
      final series = IndicatorSeries.from(bars);
      final lastEval = bars.length - 1 - h;
      for (var t = IndicatorSnapshot.minBars; t <= lastEval; t++) {
        baseReturns.add((bars[t + h].close / bars[t].close - 1) * 100);
        final s = series.at(t);
        if (!ma60Upcross(s)) continue;
        events.add(_Event(
          (bars[t + h].close / bars[t].close - 1) * 100,
          {for (final f in all) if (ma60FilterPasses(s, f)) f},
        ));
      }
    }
    if (events.isEmpty) {
      print('持有期 $h 日：无 MA60 上穿事件');
      continue;
    }

    final base = _Stats.of(baseReturns);
    final bare = _Stats.of([for (final e in events) e.fwd]);
    print('');
    print('══ 持有期 $h 日 · 上穿事件 ${events.length} 个 · 基准样本 ${base.count} ══');
    print('   无条件基准：胜率 ${_pct(base.winRate)} / 平均 ${_num(base.avg)}');
    print('   裸MA60上穿：胜率 ${_pct(bare.winRate)} / 平均 ${_num(bare.avg)} / '
        '盈亏比 ${bare.pf.toStringAsFixed(2)} / 超额胜率 ${_pp(bare.winRate - base.winRate)}'
        ' / 超额平均 ${_pp2(bare.avg - base.avg)}');
    print('   ↓ 下面所有「超额」都是相对**裸MA60上穿**，衡量该过滤项的净增量');

    // ── 单项过滤 ──
    print('');
    print('【单项】在裸上穿之上再加一层');
    print(_header());
    final singles = <(Ma60Filter, _Stats)>[];
    for (final f in all) {
      final st = _Stats.of([for (final e in events) if (e.passed.contains(f)) e.fwd]);
      singles.add((f, st));
      print(_row(_labels[f]!, st, bare, st.count < 30));
    }

    // ── 全组合穷举 ──
    final combos = <(String, _Stats)>[];
    for (var mask = 0; mask < (1 << all.length); mask++) {
      final fs = <Ma60Filter>{
        for (var i = 0; i < all.length; i++)
          if (mask & (1 << i) != 0) all[i]
      };
      final st = _Stats.of([for (final e in events) if (fs.every(e.passed.contains)) e.fwd]);
      combos.add((fs.map((f) => _labels[f]!).join('+'), st));
    }
    // 样本下限：低于此的组合排名没有意义（避免 top 榜被 3 个信号的过拟合占满）
    final minCount = (events.length * 0.01).round().clamp(30, 1 << 20);

    final sorts = <(String, int Function((String, _Stats), (String, _Stats)))>[
      ('平均收益', (a, b) => b.$2.avg.compareTo(a.$2.avg)),
      ('超额胜率', (a, b) => (b.$2.winRate - bare.winRate).compareTo(a.$2.winRate - bare.winRate)),
      ('超额平均', (a, b) => (b.$2.avg - bare.avg).compareTo(a.$2.avg - bare.avg)),
    ];
    for (final (title, cmp) in sorts) {
      final qualifying = combos.where((c) => c.$2.count >= minCount).toList();
      print('');
      print('【组合】按$title 排序 top $top（仅列信号数 ≥ $minCount 的；'
          '共 ${qualifying.length}/${combos.length} 个组合达标）');
      print(_header());
      qualifying.sort(cmp);
      for (final e in qualifying.take(top)) {
        print(_row(e.$1, e.$2, bare, e.$2.count < 30));
      }
      if (qualifying.isEmpty) print('   （无组合达到样本下限）');
    }
    // ── 资金/量能三项单独汇总 ──
    print('');
    print('【资金/量能/年线】用户关心的过滤项（放行率 = 该项放行的上穿事件占比）');
    for (final e in singles) {
      if (e.$1 == Ma60Filter.closePos ||
          e.$1 == Ma60Filter.amountRatio ||
          e.$1 == Ma60Filter.volumeWindow) {
        print('   ${_labels[e.$1]!.padRight(10)} '
            '放行 ${_pct(e.$2.count / events.length)} '
            '(${e.$2.count}/${events.length}) · '
            '胜率 ${_pct(e.$2.winRate)} · 平均 ${_num(e.$2.avg)} · '
            '超额胜率 ${_pp(e.$2.winRate - bare.winRate)} · '
            '超额平均 ${_pp2(e.$2.avg - bare.avg)}');
      }
    }
  }
  exit(0);
}


String _header() =>
    '   组合'.padRight(26) +
    '信号数'.padLeft(8) +
    '胜率'.padLeft(8) +
    '平均%'.padLeft(9) +
    '盈亏比'.padLeft(8) +
    '超额胜率'.padLeft(10) +
    '超额平均'.padLeft(10);

/// [bare] 是裸 MA60 上穿的统计，作为「超额」的参照点。
String _row(String name, _Stats st, _Stats bare, bool thin) =>
    '   ${thin ? '*' : ' '}${name.padRight(23)}'
        '${st.count.toString().padLeft(7)}'
        '${_pct(st.winRate).padLeft(8)}'
        '${_num(st.avg).padLeft(9)}'
        '${st.pf.toStringAsFixed(2).padLeft(8)}'
        '${_pp(st.winRate - bare.winRate).padLeft(10)}'
        '${_pp2(st.avg - bare.avg).padLeft(10)}';

class _Stats {
  const _Stats(this.count, this.winRate, this.avg, this.pf);

  factory _Stats.of(List<double> xs) {
    if (xs.isEmpty) return const _Stats(0, 0, 0, 0);
    var gain = 0.0, loss = 0.0;
    for (final x in xs) {
      if (x > 0) {
        gain += x;
      } else if (x < 0) {
        loss += -x;
      }
    }
    return _Stats(
      xs.length,
      xs.where((x) => x > 0).length / xs.length,
      xs.reduce((a, b) => a + b) / xs.length,
      (gain == 0 || loss == 0) ? 0 : gain / loss,
    );
  }

  final int count;
  final double winRate;
  final double avg;
  final double pf;
}

String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';
String _num(double v) => v.toStringAsFixed(2);
String _pp(double v) => '${v >= 0 ? '+' : ''}${(v * 100).toStringAsFixed(1)}pp';

/// 平均收益差（百分点）。
String _pp2(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}pp';
