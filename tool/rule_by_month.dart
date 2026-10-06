/// 规则 × 月份交叉：这条规则是阿尔法，还是只在顺风月份出现的顺风车？
///
/// ## 要回答的问题
///
/// `rsi_oversold_volume` 的超额从 +41.9pp 衰减到 +9.6pp。有两种解释：
///
/// - **策略退化**：同一环境下规则变差了 → 该修或该停
/// - **顺风车**：规则在 2024 的顺风月里表现好，2026 逆风月里本来就不该好
///   → 超额衰减只是牛市结束，规则本身没坏
///
/// 判别方法：把月份按**当月基准胜率**分成下行 / 中性 / 上行三档，
/// 看规则在每一档的超额与信号密度。如果它在下行月既无超额又几乎不出信号，
/// 那就是顺风车；如果下行月仍有超额，说明有独立性。
///
/// 顺带看**信号密度**（信号数 / 可评估日）：密度塌掉说明规则本身在躲逆风，
/// 那"超额还在"也只是因为样本集中在好日子。
///
/// 用法: dart run tool/rule_by_month.dart [ruleId ...]
library;

// ignore_for_file: avoid_print

import 'dart:io';
import 'package:stock/config.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';

const _horizon = 10;
final _maxHorizon = kDefaultHorizons.reduce((a, b) => a > b ? a : b);

/// 默认分析的规则：主角 + 宽松版 + 两个对照。
const _defaultRules = [
  'rsi_oversold_volume',
  'rsi_oversold_volume_loose',
  'rsi_oversold',
  'pivot_breakout',
];

/// 按基准胜率分档的边界。
const _downCut = 0.45;
const _upCut = 0.55;

Future<void> main(List<String> args) async {
  final ids = args.isEmpty ? _defaultRules : args;
  final known = {for (final r in builtInRules) r.id};
  for (final id in ids) {
    if (!known.contains(id)) {
      print('未知规则 id: $id（可选：${known.join(", ")}）');
      exit(1);
    }
  }
  final repo = BarRepository(AppConfig.load().dbPath);
  final stocks = repo.loadAllStocks();
  repo.close();

  // 单趟扫描：每天算一次快照，20 条规则共用，与 backtestAll 同构
  final rules = [for (final id in ids) ruleById(id)];
  final base = <String, _Cell>{};
  final cells = <String, Map<String, _Cell>>{for (final r in rules) r.id: {}};

  for (final stock in stocks) {
    final bars = stock.bars;
    if (bars.length < IndicatorSnapshot.minBars + _maxHorizon) continue;
    final series = IndicatorSeries.from(bars);
    final last = bars.length - 1 - _maxHorizon;
    for (var t = IndicatorSnapshot.minBars; t <= last; t++) {
      final snap = series.at(t);
      final r = (bars[t + _horizon].close / bars[t].close - 1) * 100;
      final mk = _monthKey(bars[t].date);
      (base[mk] ??= _Cell()).add(r);
      for (final rule in rules) {
        if (rule.test(snap)) (cells[rule.id]![mk] ??= _Cell()).add(r);
      }
    }
  }

  final months = base.keys.toList()..sort();
  _printHeadline(months, base);

  for (final rule in rules) {
    _printRule(rule, months, base, cells[rule.id]!);
  }
  exit(0);
}

String _monthKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

void _printHeadline(List<String> months, Map<String, _Cell> base) {
  print('══ 按月基准胜率（全市场，不做选股）══');
  print('  ${'月份'.padRight(9)}${'样本'.padLeft(9)}${'胜率'.padLeft(8)}'
      '${'平均%'.padLeft(9)}${'档位'.padLeft(6)}');
  for (final m in months) {
    final b = base[m]!;
    final band = b.winRate < _downCut
        ? '下行'
        : b.winRate > _upCut
            ? '上行'
            : '中性';
    final truncated = b.count < 50000 ? ' ←截断' : '';
    print('  ${m.padRight(9)}${b.count.toString().padLeft(9)}'
        '${(b.winRate * 100).toStringAsFixed(1).padLeft(7)}%'
        '${b.avg.toStringAsFixed(2).padLeft(8)}%  $band$truncated');
  }
}

void _printRule(
    Rule rule, List<String> months, Map<String, _Cell> base, Map<String, _Cell> cell) {
  print('');
  print('══ ${rule.name}（${rule.id}）══');
  print('  ${'月份'.padRight(9)}${'基准'.padLeft(7)}${'信号'.padLeft(7)}'
      '${'胜率'.padLeft(8)}${'超额'.padLeft(8)}${'密度'.padLeft(7)}'
      '${'基准平均%'.padLeft(10)}${'规则平均%'.padRight(0)}');

  var downN = 0, downW = 0, downSig = 0;
  var midN = 0, midW = 0, midSig = 0;
  var upN = 0, upW = 0, upSig = 0;

  for (final m in months) {
    final b = base[m]!;
    final c = cell[m] ?? _Cell();
    final truncated = b.count < 50000;
    final excess = c.count == 0 ? null : c.winRate - b.winRate;
    final density = c.count / b.count * 100;
    // 先把各列算成字符串，避免在 print 里嵌套引号（容易写错且难读）
    final wr = c.count == 0 ? '—' : '${(c.winRate * 100).toStringAsFixed(1)}%';
    final ex = excess == null ? '—' : '${(excess * 100).toStringAsFixed(1)}pp';
    final rAvg = c.count == 0 ? '' : '${c.avg.toStringAsFixed(2).padLeft(9)}%';
    print('  ${m.padRight(9)}'
        '${(b.winRate * 100).toStringAsFixed(1).padLeft(6)}%'
        '${c.count.toString().padLeft(7)}'
        '${wr.padLeft(8)}'
        '${ex.padLeft(8)}'
        '${density.toStringAsFixed(2).padLeft(6)}%'
        '${b.avg.toStringAsFixed(2).padLeft(9)}%'
        '$rAvg'
        '${truncated ? '  ←截断' : ''}');
    if (truncated) continue;
    final band = b.winRate < _downCut
        ? 0
        : b.winRate > _upCut
            ? 2
            : 1;
    if (band == 0) {
      downN += c.count;
      downW += c.wins;
      downSig += 1;
    } else if (band == 1) {
      midN += c.count;
      midW += c.wins;
      midSig += 1;
    } else {
      upN += c.count;
      upW += c.wins;
      upSig += 1;
    }
  }

  print('  ── 按当月市场档位汇总（剔除截断月）──');
  for (final (label, n, w, sig) in [
    ('下行月(基准<45%)', downN, downW, downSig),
    ('中性月(45~55%)', midN, midW, midSig),
    ('上行月(基准>55%)', upN, upW, upSig),
  ]) {
    if (sig == 0) {
      print('    $label  无样本');
      continue;
    }
    // 该档所有月份的合并基准
    var bn = 0, bw = 0;
    for (final m in months) {
      final b = base[m]!;
      if (b.count < 50000) continue;
      final band = b.winRate < _downCut
          ? 0
          : b.winRate > _upCut
              ? 2
              : 1;
      final want = label.startsWith('下行')
          ? 0
          : label.startsWith('中性')
              ? 1
              : 2;
      if (band == want) {
        bn += b.count;
        bw += b.wins;
      }
    }
    final bwR = bn == 0 ? 0.0 : bw / bn;
    final wr = n == 0 ? '—' : '${(w / n * 100).toStringAsFixed(1)}%';
    final ex = n == 0 ? '—' : '${((w / n - bwR) * 100).toStringAsFixed(1)}pp';
    print('    $label  $sig个月  信号 $n  胜率 $wr  '
        '基准 ${(bwR * 100).toStringAsFixed(1)}%  超额 $ex');
  }
}

class _Cell {
  int count = 0;
  int wins = 0;
  double sum = 0;

  void add(double v) {
    count++;
    sum += v;
    if (v > 0) wins++;
  }

  double get winRate => count == 0 ? 0 : wins / count;
  double get avg => count == 0 ? 0 : sum / count;
}
