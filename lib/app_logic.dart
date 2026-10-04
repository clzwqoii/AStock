/// App/CLI 共用的重活入口：把 SQLite 读取与计算放进后台 isolate，避免卡 UI。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as h;
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/core/screener.dart';
import 'package:stock/data/bar_repository.dart';
import 'package:stock/data/sync_service.dart';
import 'package:stock/data/tushare_client.dart';

/// 当前应用版本（发布新包时同步修改，与 pubspec.version 保持一致）。
const kAppVersion = '1.0.1';

/// 更新清单候选源（并发竞速，第一个响应的胜出）。
/// 国内网络优先命中 Gitee；jsDelivr 镜像可加速 GitHub raw。建仓库后替换为你的地址。
const kUpdateCheckUrls = <String>[
  'https://gitee.com/clzwqoii/astock/raw/main/update.json', // 国内优先
  'https://raw.githubusercontent.com/clzwqoii/AStock/main/update.json',
  'https://cdn.jsdelivr.net/gh/clzwqoii/AStock@main/update.json', // GitHub CDN 镜像
];

/// 更新清单请求超时。
const kUpdateTimeout = Duration(seconds: 15);

class UpdateInfo {
  const UpdateInfo({required this.latestVersion, required this.downloadUrl});

  final String latestVersion;
  final String downloadUrl;
}

class _Attempt {
  _Attempt(this.info, this.error);

  /// 解析成功（[info] 为 null 表示已是最新）。
  final UpdateInfo? info;
  final Object? error;

  bool get ok => error == null;

  /// 承载本次尝试的 future（竞速结束后用它把自己从待办列表移除）。
  Future<_Attempt>? self;
}

/// 检查更新：并发请求所有候选源，第一个成功的决定结果（境内 Gitee / 境外 GitHub 自动分流）；
/// 某源失败自动换下一个，全部失败才抛错。
Future<UpdateInfo?> checkForUpdate({
  String? currentVersion,
  h.Client? client,
  List<String>? urls,
}) async {
  final cur = currentVersion ?? kAppVersion;
  final c = client ?? h.Client();
  Future<_Attempt> attempt(String url) async {
    try {
      final res = await c.get(Uri.parse(url)).timeout(kUpdateTimeout);
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final latest = data['version'] as String;
      return _Attempt(_isNewer(latest, cur)
          ? UpdateInfo(latestVersion: latest, downloadUrl: (data['url'] ?? '') as String)
          : null, null);
    } catch (e) {
      return _Attempt(null, e);
    }
  }

  final pending = <Future<_Attempt>>[];
  for (final url in (urls ?? kUpdateCheckUrls)) {
    late final Future<_Attempt> f;
    f = attempt(url).then((a) {
      a.self = f;
      return a;
    });
    pending.add(f);
  }
  Object? lastError;
  while (pending.isNotEmpty) {
    final r = await Future.any(pending);
    pending.remove(r.self);
    if (r.ok) return r.info;
    lastError = r.error;
  }
  throw lastError ?? StateError('没有可用的更新源');
}

bool _isNewer(String latest, String current) {
  List<int> parts(String v) =>
      v.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final a = parts(latest);
  final b = parts(current);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// 一行选股结果的展示数据（工作台表格直接消费）。
/// [name] 为 null 表示本地名单未拉到，UI 需降级显示。
class ScreenRow {
  const ScreenRow({
    required this.symbol,
    required this.name,
    required this.close,
    required this.change,
    required this.changePct,
    required this.volumeRatio,
    required this.amountWan,
    required this.ma20,
    this.matchedRules = const [],
  });

  final String symbol;
  final String? name;
  final double close;
  final double change;
  final double changePct;
  final double volumeRatio;
  final double amountWan;
  final double ma20;

  /// 命中的规则名（可多条；组合选股时按勾选顺序展示）。CLI/旧调用方可能为空。
  final List<String> matchedRules;
}

/// 结果表可排序列（与工作台表头一一对应；点表头切换升降序）。
enum SortField { close, changePct, volumeRatio, amount, ma20 }

/// 按 [field] 排序（默认降序）；同值保持入参顺序（稳定排序，表头重复点击不抖动）。
/// 返回新列表，不改 [rows]。
List<ScreenRow> sortRows(List<ScreenRow> rows, SortField field, {bool ascending = false}) {
  double value(ScreenRow r) => switch (field) {
        SortField.close => r.close,
        SortField.changePct => r.changePct,
        SortField.volumeRatio => r.volumeRatio,
        SortField.amount => r.amountWan,
        SortField.ma20 => r.ma20,
      };
  final decorated = [for (var i = 0; i < rows.length; i++) (v: rows[i], i: i)];
  decorated.sort((a, b) {
    final c = value(a.v).compareTo(value(b.v));
    if (c != 0) return ascending ? c : -c;
    return a.i.compareTo(b.i);
  });
  return [for (final d in decorated) d.v];
}

/// CSV 单元格转义：含逗号/引号/换行时按 RFC4180 加双引号并转义内部引号。
String _csvCell(Object? v) {
  final s = v == null ? '' : '$v';
  return s.contains(RegExp(r'[",\n\r]')) ? '"${s.replaceAll('"', '""')}"' : s;
}

/// 选股结果 → CSV 文本（UTF-8 文本，导出时由 [exportRowsCsv] 加 BOM 以便 Excel 识别中文）。
/// 第一行是说明行（含数据日期与规则组合），第二行起是表头与数据，列序与工作台表头一致。
String rowsToCsv(List<ScreenRow> rows, {String? dataDate, String? combo}) {
  final buf = StringBuffer()
    ..writeln('# A股选股结果（不复权·手）'
        '${dataDate == null ? '' : '  数据截至 $dataDate'}'
        '${combo == null || combo.isEmpty ? '' : '  规则：$combo'}')
    ..writeln('代码,名称,收盘,涨跌,涨跌幅%,量比,成交额(万),MA20,命中规则,数据截至,规则组合');
  for (final r in rows) {
    buf.writeln([
      _csvCell(r.symbol),
      _csvCell(r.name ?? ''),
      r.close.toStringAsFixed(2),
      '${r.change >= 0 ? '+' : '-'}${r.change.abs().toStringAsFixed(2)}',
      '${r.changePct >= 0 ? '+' : '-'}${r.changePct.abs().toStringAsFixed(2)}',
      r.volumeRatio.toStringAsFixed(2),
      r.amountWan.toStringAsFixed(2),
      r.ma20.toStringAsFixed(2),
      _csvCell(r.matchedRules.join(' + ')),
      _csvCell(dataDate ?? ''),
      _csvCell(combo ?? ''),
    ].join(','));
  }
  return buf.toString();
}

/// 写文件回调（测试注入假实现；默认用 dart:io 写库同目录）。
typedef WriteCsvFn = Future<void> Function(String path, List<int> bytes);

/// 导出 CSV 到 [dirPath]（传数据库所在目录：桌面 ~/.stock、移动端沙盒应用目录）。
/// 文件名带日期时间戳，重复导出不覆盖。返回落盘路径（UI 弹提示用）。
Future<String> exportRowsCsv(
  List<ScreenRow> rows, {
  required String dirPath,
  String? dataDate,
  String? combo,
  WriteCsvFn? write,
}) async {
  final stamp = _stamp();
  final file = File('$dirPath/选股结果-$stamp.csv');
  await (write ?? (p, bytes) async {
        await File(p).parent.create(recursive: true);
        await File(p).writeAsBytes(bytes);
      })(file.path, [
    0xEF, 0xBB, 0xBF, // BOM：没有它 Excel 打开中文 CSV 会乱码
    ...utf8.encode(rowsToCsv(rows, dataDate: dataDate, combo: combo)),
  ]);
  return file.path;
}

/// `YYYYMMDD-HHMMSS` 本地时间戳（写到文件名里避免覆盖上次导出）。
String _stamp() {
  final n = DateTime.now();
  String p2(int v) => v.toString().padLeft(2, '0');
  return '${n.year}${p2(n.month)}${p2(n.day)}-${p2(n.hour)}${p2(n.minute)}${p2(n.second)}';
}

/// 选股：后台 isolate 里打开库 → 全量加载 → 规则筛选 → 组装展示行 → 关库。
/// 返回股票总数、入选行、数据截止交易日。
Future<({int total, List<ScreenRow> picked, String? dataDate})> runScreening(
  String dbPath,
  List<Rule> rules,
) =>
    Isolate.run(() {
      final repo = BarRepository(dbPath);
      try {
        final stocks = repo.loadAllStocks();
        final names = repo.stockNames();
        final picked = <ScreenRow>[];
        for (final hit in screenWithHits(stocks, rules)) {
          final s = hit.stock;
          final snap = IndicatorSnapshot.fromStock(s);
          final prevClose = s.bars[s.bars.length - 2].close;
          picked.add(ScreenRow(
            symbol: s.symbol,
            name: names[s.symbol],
            close: snap.close,
            change: snap.close - prevClose,
            changePct: snap.pctChange,
            volumeRatio: snap.volumeRatio,
            amountWan: s.last.amount / 10,
            ma20: snap.ma20,
            matchedRules: [for (final id in hit.matchedRuleIds) ruleById(id).name],
          ));
        }
        return (total: stocks.length, picked: picked, dataDate: repo.maxTradeDate());
      } finally {
        repo.close();
      }
    });

/// 个股详情：单只股票的完整日线 + 末日指标快照。
/// [name] 为 null 表示本地名单未拉到，UI 降级显示代码。
class StockDetail {
  const StockDetail({
    required this.symbol,
    required this.name,
    required this.bars,
    required this.snapshot,
  });

  final String symbol;
  final String? name;
  final List<Bar> bars;
  final IndicatorSnapshot snapshot;
}

/// 加载单只股票详情（数据量小，主 isolate 直接算）。
/// 本地无该股或历史不足 [IndicatorSnapshot.minBars] 根时返回 null。
Future<StockDetail?> loadStockDetail(String dbPath, String symbol) async {
  final repo = BarRepository(dbPath);
  try {
    final bars = repo.barsFor(symbol);
    if (bars.length < IndicatorSnapshot.minBars) return null;
    final stock = StockData(symbol: symbol, bars: bars);
    return StockDetail(
      symbol: symbol,
      name: repo.stockNames()[symbol],
      bars: bars,
      snapshot: IndicatorSnapshot.fromStock(stock),
    );
  } finally {
    repo.close();
  }
}

/// 增量同步：网络等待型任务，直接在当前 isolate 跑（onProgress 才能实时回调 UI）；
/// 库操作按交易日分批，单批几千行不会卡界面。
/// [clientFactory] 供测试注入假客户端；生产用默认值。
Future<SyncResult> runSync({
  required String dbPath,
  required String token,
  DateTime Function()? now,
  TushareClient Function(String token)? clientFactory,
  void Function(String msg)? onProgress,
}) async {
  final repo = BarRepository(dbPath);
  try {
    final client = clientFactory?.call(token) ?? TushareClient(token: token);
    return await SyncService(client, repo, now: now).sync(onProgress: onProgress);
  } finally {
    repo.close();
  }
}
