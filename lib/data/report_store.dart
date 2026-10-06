/// 回测报告的落盘缓存：JSON 放在数据库同目录，随库走（桌面 ~/.stock、移动端沙盒）。
/// 纯 IO，不放 core（core 零 IO 依赖）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:stock/core/backtest.dart';

/// 报告文件路径：与数据库同目录，`<数据库主名>-backtest-report.json`。
String reportPathFor(String dbPath) {
  final f = File(dbPath);
  final name = f.uri.pathSegments.last;
  final dot = name.lastIndexOf('.');
  final stem = dot <= 0 ? name : name.substring(0, dot);
  return '${f.parent.path}/$stem-backtest-report.json';
}

class ReportStore {
  ReportStore(this.path);

  final String path;

  /// 读缓存；没有文件、或文件损坏都返回 null（报表不该影响选股）。
  ///
  /// 「损坏」包含两种：合法 JSON 但结构不对（字段缺失/类型错，多发生在 App 升级
  /// 改了报告格式之后），以及根本不是 JSON 对象。后者抛的是 TypeError 而非 Exception，
  /// 所以显式接住——缓存读取绝不能让选股页崩掉。
  BacktestReport? load() {
    final f = File(path);
    if (!f.existsSync()) return null;
    try {
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is! Map<String, dynamic>) return null;
      return BacktestReport.fromJson(raw);
    } on Exception catch (_) {
      return null;
    } on TypeError catch (_) {
      return null; // 报告 schema 漂移，按损坏处理
    }
  }

  void save(BacktestReport report) {
    File(path).writeAsStringSync(jsonEncode(report.toJson()));
  }

  void clear() {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  }
}
