/// 日线列式快照缓存：同步完成后把全库 K 线落成二进制列存，回测 worker
/// 从快照重建 Bar，替代逐行 SQL 映射（5.39M 行实测：SQL load 2.2–4.5s →
/// 快照并行重建 wall 0.48s）。
///
/// 布局（小端）：`[u32 头 JSON 字节数][头 JSON(utf-8)][每股块…]`；
/// 每股块 = `i32 根数 + 根数×52 字节`，每行 = `i32 ymd + 6×f64`
/// （open/high/low/close/vol/amount）。头 JSON：
/// `{"v":1,"maxRowid":N,"rowCount":N,"syms":[…],"lens":[…]}`。
///
/// 有效性由水位自校验保证（调用方比对 maxRowid + barCountUpTo 与头里的
/// rowCount），快照与落盘时的 daily_bars 逐位相同；校验失败自动回退 SQL
/// 路径，正确性不依赖快照本身。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/models.dart';
import 'tushare_client.dart' show DailyRow;

const int _recBytes = 4 + 6 * 8; // i32 ymd + 6×f64
const int _kSnapshotVersion = 1;

/// 快照路径：与数据库同目录，`<数据库主名>-bars-snap.bin`（同 [reportPathFor] 的 stem 逻辑）。
String barsSnapshotPathFor(String dbPath) {
  final name = dbPath.split(Platform.pathSeparator).last;
  final dot = name.lastIndexOf('.');
  final stem = dot <= 0 ? name : name.substring(0, dot);
  final dir = dbPath.substring(0, dbPath.length - name.length);
  return '$dir$stem-bars-snap.bin';
}

/// 已加载的快照：原始字节 + 头信息 + 每股块偏移（顺序扫描建表，零额外分配）。
class BarsSnapshot {
  BarsSnapshot({
    required this.maxRowid,
    required this.rowCount,
    required this.bytes,
    required this.symbols,
    required this.lens,
    required this.offsets,
  });

  /// 写快照时库的 MAX(rowid)（水位自校验用）。
  final int maxRowid;

  /// 写快照时 daily_bars 总行数（与 barCountUpTo(maxRowid) 比对）。
  final int rowCount;
  final Uint8List bytes;
  final List<String> symbols;
  final List<int> lens;
  final List<int> offsets;
}

/// 一根 K 线的列存编码（小端）：i32 ymd + open/high/low/close/vol/amount。
void _putRec(ByteData bd, int o, int ymd, double open, double high, double low,
    double close, double vol, double amount) {
  bd.setInt32(o, ymd, Endian.little);
  bd.setFloat64(o + 4, open, Endian.little);
  bd.setFloat64(o + 12, high, Endian.little);
  bd.setFloat64(o + 20, low, Endian.little);
  bd.setFloat64(o + 28, close, Endian.little);
  bd.setFloat64(o + 36, vol, Endian.little);
  bd.setFloat64(o + 44, amount, Endian.little);
}

/// 原子写（tmp+rename，Windows 先删再换，同 saveBacktestHistory）。
void _atomicWriteSync(String path, Uint8List out) {
  final tmp = File('$path.$pid.tmp');
  tmp.writeAsBytesSync(out, flush: true);
  try {
    tmp.renameSync(path);
  } on FileSystemException {
    if (Platform.isWindows && File(path).existsSync()) {
      File(path).deleteSync();
      tmp.renameSync(path);
    } else {
      rethrow;
    }
  }
}

/// 写快照（原子写）。[stocks] 的 symbol 顺序即块顺序，读取端按同序重建。
void writeBarsSnapshot(
  String path,
  List<StockData> stocks, {
  required int maxRowid,
  required int rowCount,
}) {
  final syms = <String>[];
  final lens = <int>[];
  var dataBytes = 0;
  for (final s in stocks) {
    syms.add(s.symbol);
    lens.add(s.bars.length);
    dataBytes += 4 + s.bars.length * _recBytes;
  }
  final head = jsonEncode({
    'v': _kSnapshotVersion,
    'maxRowid': maxRowid,
    'rowCount': rowCount,
    'syms': syms,
    'lens': lens,
  });
  final headBytes = utf8.encode(head);

  final out = Uint8List(4 + headBytes.length + dataBytes);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, headBytes.length, Endian.little);
  out.setRange(4, 4 + headBytes.length, headBytes);

  var o = 4 + headBytes.length;
  for (final s in stocks) {
    bd.setInt32(o, s.bars.length, Endian.little);
    o += 4;
    for (final b in s.bars) {
      _putRec(bd, o, b.date.year * 10000 + b.date.month * 100 + b.date.day,
          b.open, b.high, b.low, b.close, b.volume, b.amount);
      o += _recBytes;
    }
  }
  _atomicWriteSync(path, out);
}

/// 增量 append：把新行（[rows]，ts_code/trade_date 升序，rowid ∈
/// (old.maxRowid, maxRowid]）写上 [old] 并原子替换。成功返回 true。
///
/// 任一存量股的新行日期 ≤ 其旧末根时返回 false 且**不动原文件**——append 会
/// 破坏时间升序（回补更早历史），调用方须退回 [writeBarsSnapshot] 全量重建。
/// 旧块字节按原样拷贝（含根数前缀），仅新行做列存编码，重排只发生在
/// 新股插入字典序中间时。
bool appendBarsSnapshot(
  String path,
  BarsSnapshot old,
  List<DailyRow> rows, {
  required int maxRowid,
}) {
  final newByCode = <String, List<DailyRow>>{};
  for (final r in rows) {
    newByCode.putIfAbsent(r.tsCode, () => []).add(r);
  }
  // 排序护栏：存量股的新行必须严格晚于旧末根（相等也不行——那是 REPLACE 的样子）
  for (final e in newByCode.entries) {
    final idx = old.symbols.indexOf(e.key);
    if (idx < 0) continue;
    final n = old.lens[idx];
    final lastYmd = ByteData.sublistView(
            old.bytes, old.offsets[idx] + 4 + (n - 1) * _recBytes)
        .getInt32(0, Endian.little);
    if (int.parse(e.value.first.tradeDate) <= lastYmd) return false;
  }

  final syms = <String>{...old.symbols, ...newByCode.keys}.toList()..sort();
  final lens = <int>[];
  var dataBytes = 0;
  for (final sym in syms) {
    final oldIdx = old.symbols.indexOf(sym);
    final oldN = oldIdx < 0 ? 0 : old.lens[oldIdx];
    final newN = newByCode[sym]?.length ?? 0;
    lens.add(oldN + newN);
    dataBytes += 4 + (oldN + newN) * _recBytes;
  }
  final head = jsonEncode({
    'v': _kSnapshotVersion,
    'maxRowid': maxRowid,
    'rowCount': old.rowCount + rows.length,
    'syms': syms,
    'lens': lens,
  });
  final headBytes = utf8.encode(head);

  final out = Uint8List(4 + headBytes.length + dataBytes);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, headBytes.length, Endian.little);
  out.setRange(4, 4 + headBytes.length, headBytes);

  var o = 4 + headBytes.length;
  for (var s = 0; s < syms.length; s++) {
    final oldIdx = old.symbols.indexOf(syms[s]);
    final newRows = newByCode[syms[s]];
    final n = lens[s];
    bd.setInt32(o, n, Endian.little);
    o += 4;
    if (oldIdx >= 0) {
      // 旧块自带 4 字节根数前缀（值是旧根数），跳过只拷数据，前缀由上面统一写新值
      final oldData = old.lens[oldIdx] * _recBytes;
      out.setRange(o, o + oldData, old.bytes, old.offsets[oldIdx] + 4);
      o += oldData;
    }
    if (newRows != null) {
      for (final r in newRows) {
        _putRec(bd, o, int.parse(r.tradeDate), r.open, r.high, r.low, r.close,
            r.vol, r.amount);
        o += _recBytes;
      }
    }
  }
  _atomicWriteSync(path, out);
  return true;
}

/// 读快照。文件缺失 / 截断 / 版本不符 / 任何解析异常 → null（调用方回退 SQL 路径）。
BarsSnapshot? loadBarsSnapshot(String path) {
  try {
    final f = File(path);
    if (!f.existsSync()) return null;
    final bytes = f.readAsBytesSync();
    if (bytes.length < 4) return null;
    final bd = ByteData.sublistView(bytes);
    final headLen = bd.getUint32(0, Endian.little);
    if (headLen <= 0 || 4 + headLen > bytes.length) return null;
    final head =
        jsonDecode(utf8.decode(bytes.sublist(4, 4 + headLen))) as Map<String, dynamic>;
    if (head['v'] != _kSnapshotVersion) return null;
    final syms = (head['syms'] as List).cast<String>();
    final lens = (head['lens'] as List).cast<int>();
    if (syms.length != lens.length) return null;
    final offsets = <int>[];
    var o = 4 + headLen;
    for (final n in lens) {
      offsets.add(o);
      o += 4 + n * _recBytes;
    }
    if (o > bytes.length) return null; // 截断
    return BarsSnapshot(
      maxRowid: head['maxRowid'] as int,
      rowCount: head['rowCount'] as int,
      bytes: bytes,
      symbols: syms,
      lens: lens,
      offsets: offsets,
    );
  } catch (_) {
    return null;
  }
}

/// 快照头（不含块数据）：水位自校验 + 块定位所需的最小信息。
/// 几百 KB 级，回测 worker 只读它就能判有效性并定位自己那一段。
class SnapshotHeader {
  SnapshotHeader({
    required this.maxRowid,
    required this.rowCount,
    required this.symbols,
    required this.lens,
    required this.dataStart,
  });

  final int maxRowid;
  final int rowCount;
  final List<String> symbols;
  final List<int> lens;

  /// 第一个块（含其 4 字节根数前缀）的文件偏移。
  final int dataStart;
}

/// 只读快照头，不碰块区。缺失 / 截断 / 版本不符 / 任何解析异常 → null。
SnapshotHeader? readSnapshotHeader(String path) {
  try {
    final f = File(path);
    if (!f.existsSync()) return null;
    final raf = f.openSync();
    try {
      final lenBytes = _readFully(raf, 4);
      if (lenBytes == null) return null;
      final headLen = ByteData.sublistView(lenBytes).getUint32(0, Endian.little);
      if (headLen <= 0 || headLen > 64 * 1024 * 1024) return null;
      final headBytes = _readFully(raf, headLen);
      if (headBytes == null) return null;
      final head =
          jsonDecode(utf8.decode(headBytes)) as Map<String, dynamic>;
      if (head['v'] != _kSnapshotVersion) return null;
      final syms = (head['syms'] as List).cast<String>();
      final lens = (head['lens'] as List).cast<int>();
      if (syms.length != lens.length) return null;
      return SnapshotHeader(
        maxRowid: head['maxRowid'] as int,
        rowCount: head['rowCount'] as int,
        symbols: syms,
        lens: lens,
        dataStart: 4 + headLen,
      );
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return null;
  }
}

/// 读满 [n] 字节；文件不足则返回 null（[RandomAccessFile.readSync] 允许短读）。
Uint8List? _readFully(RandomAccessFile raf, int n) {
  final buf = Uint8List(n);
  var off = 0;
  while (off < n) {
    final got = raf.readIntoSync(buf, off, n);
    if (got <= 0) return null;
    off += got;
  }
  return buf;
}

/// 从快照文件重建 `[fromCode, toCode)` 半开区间的股票，**只读头 + 需要的块**：
/// 回测 8 分片各读整份快照会在手机内存上叠加成尖峰（8 × 数百 MB），
/// 这里每分片只碰自己那一段。任一需要的块读不满 → null（调用方回退 SQL）。
/// 头不完整或版本不符同样返回 null。
List<StockData>? stocksFromSnapshotFile(
  String path,
  String fromCode, {
  String? toCode,
}) {
  final h = readSnapshotHeader(path);
  if (h == null) return null;
  try {
    final raf = File(path).openSync();
    try {
      final dateCache = <int, DateTime>{};
      final out = <StockData>[];
      var o = h.dataStart;
      for (var s = 0; s < h.symbols.length; s++) {
        final n = h.lens[s];
        final blockBytes = 4 + n * _recBytes;
        final sym = h.symbols[s];
        final wanted =
            sym.compareTo(fromCode) >= 0 && (toCode == null || sym.compareTo(toCode) < 0);
        if (wanted) {
          raf.setPositionSync(o);
          final blk = _readFully(raf, blockBytes);
          if (blk == null) return null;
          out.add(_rebuildStock(sym, blk, dateCache));
        }
        o += blockBytes;
      }
      return out;
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return null;
  }
}

/// 用一块「4 字节根数前缀 + 根数×52 字节」的字节重建一只股票。
StockData _rebuildStock(String symbol, Uint8List blk, Map<int, DateTime> dateCache) {
  final bd = ByteData.sublistView(blk);
  return StockData(
      symbol: symbol,
      bars: _readBars(bd, 4, bd.getInt32(0, Endian.little), dateCache));
}

final _zeroBar = Bar(date: DateTime(1970), open: 0, high: 0, low: 0, close: 0, volume: 0);

/// 从 [bd] 的 [start] 偏移起读 [n] 根（每根 52 字节，小端）建成 bars。
/// 唯一的列存解码点——[stocksFromSnapshot]（整份已在内存）与
/// [stocksFromSnapshotFile]（按需读块）共用，避免两套解码漂移。
List<Bar> _readBars(ByteData bd, int start, int n, Map<int, DateTime> dateCache) {
  var o = start;
  final bars = List<Bar>.filled(n, _zeroBar, growable: false);
  for (var i = 0; i < n; i++) {
    final ymd = bd.getInt32(o, Endian.little);
    final d = dateCache.putIfAbsent(
        ymd, () => DateTime(ymd ~/ 10000, (ymd ~/ 100) % 100, ymd % 100));
    bars[i] = Bar(
      date: d,
      open: bd.getFloat64(o + 4, Endian.little),
      high: bd.getFloat64(o + 12, Endian.little),
      low: bd.getFloat64(o + 20, Endian.little),
      close: bd.getFloat64(o + 28, Endian.little),
      volume: bd.getFloat64(o + 36, Endian.little),
      amount: bd.getFloat64(o + 44, Endian.little),
    );
    o += _recBytes;
  }
  return bars;
}

/// 从快照重建 `[fromCode, toCode)` 半开区间的股票（与 SQL loadStocksRange
/// 的切片语义一致，toCode 为 null 即到末尾）。ymd→DateTime 建缓存复用实例：
/// `DateTime(y,m,d)` 构造含时区计算（12.7µs/行），无缓存时并行重建反而比串行慢。
List<StockData> stocksFromSnapshot(
  BarsSnapshot snap,
  String fromCode, {
  String? toCode,
}) {
  final dateCache = <int, DateTime>{};
  final out = <StockData>[];
  for (var s = 0; s < snap.symbols.length; s++) {
    final sym = snap.symbols[s];
    if (sym.compareTo(fromCode) < 0) continue;
    if (toCode != null && sym.compareTo(toCode) >= 0) continue;
    final n = snap.lens[s];
    out.add(StockData(
      symbol: sym,
      bars: _readBars(ByteData.sublistView(snap.bytes), snap.offsets[s] + 4, n,
          dateCache),
    ));
  }
  return out;
}
