/// 东方财富公开行情接口（无需 token）。
/// 承担三件事：全市场代码+名称名单、单只名称、日K日线
/// （日线是备源链第一顺位，见 [dailyBars]）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as h;

import 'tushare_client.dart';

class EastmoneyClient {
  EastmoneyClient({
    h.Client? http,
    this.pageSize = 100,
    this.apiBase = 'https://push2.eastmoney.com',
    this.timeout = const Duration(seconds: 15),
  }) : _http = http ?? h.Client();

  final h.Client _http;
  final int pageSize;
  final String apiBase;

  /// 单请求超时：网络异常时快速失败并降级。
  final Duration timeout;

  /// 全部 A 股（沪深主板/创业板/科创板/北交所）名单。
  Future<List<({String tsCode, String name})>> stockList() async {
    const fields = 'f12,f13,f14';
    final out = <({String tsCode, String name})>[];
    var pn = 1;
    var total = 1 << 30;
    while (out.length < total) {
      final uri = Uri.parse('$apiBase/api/qt/clist/get').replace(queryParameters: {
        'pn': '$pn',
        'pz': '$pageSize',
        'po': '1',
        'np': '1',
        'fltt': '2',
        'invt': '2',
        'fid': 'f12',
        'fs': _clistFs,
        'fields': fields,
      });
      final res = await _http.get(uri, headers: _ua).timeout(timeout);
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final data = body['data'] as Map<String, dynamic>?;
      if (data == null) break;
      total = (data['total'] as num?)?.toInt() ?? 0;
      final diff = (data['diff'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      if (diff.isEmpty) break;
      for (final d in diff) {
        final code = d['f12'] as String;
        out.add((tsCode: '$code${_marketSuffix(code)}', name: d['f14'] as String));
      }
      pn++;
    }
    return out;
  }

  /// 单只股票名称（走 push2his K线接口，响应自带 name）。
  /// clist 域名在部分网络被拦时，名称回填可用此方法逐股获取。北交所不支持。
  Future<String?> stockName(String tsCode) async {
    if (tsCode.endsWith('.BJ')) {
      throw ArgumentError('东财日K暂不支持北交所: $tsCode');
    }
    final parts = tsCode.split('.');
    final secid = '${parts[1] == 'SH' ? '1' : '0'}.${parts[0]}';
    final uri = Uri.parse(
        '$_hisBase/api/qt/stock/kline/get').replace(queryParameters: {
      'secid': secid,
      'klt': '101',
      'fqt': '1',
      'lmt': '1',
      'end': '20500101',
      'fields1': 'f1,f2,f3,f4,f5,f6',
      'fields2': 'f51,f52,f53,f54,f55,f56',
    });
    final res = await _http.get(uri, headers: _ua).timeout(timeout);
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final data = body['data'] as Map<String, dynamic>?;
    return data?['name'] as String?;
  }

  /// 单只股票日K（不复权·手·元→千元），一次请求拿 [beg]（`YYYYMMDD`，含）起
  /// 全部历史——备源补数按区间下界传 [beg]，增量场景避免整段白拉。
  /// fqt=0 是不复权口径（茅台 2026-05-20 收盘 1315.00，与 tushare 不复权
  /// 逐位一致，2026-10-06 实测；混入前/后复权会在除权日留断层，禁改）。
  /// 字段顺序是 开,收,高,低（不是高低收开）。北交所 secid 走 0，支持。
  Future<List<DailyRow>> dailyBars(String tsCode, {String beg = '0'}) async {
    final parts = tsCode.split('.');
    final uri =
        Uri.parse('$_hisBase/api/qt/stock/kline/get').replace(queryParameters: {
      'secid': '${parts[1] == 'SH' ? '1' : '0'}.${parts[0]}',
      'klt': '101',
      'fqt': '0',
      'beg': beg,
      'end': '20500101',
      'fields1': 'f1,f2,f3,f4,f5,f6',
      'fields2': 'f51,f52,f53,f54,f55,f56,f57',
    });
    final res = await _http.get(uri, headers: _ua).timeout(timeout);
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final klines =
        ((body['data'] as Map<String, dynamic>?)?['klines'] as List?)
                ?.cast<String>() ??
            const <String>[];
    final out = <DailyRow>[];
    for (final k in klines) {
      final f = k.split(',');
      out.add(DailyRow(
        tsCode: tsCode,
        tradeDate: f[0].replaceAll('-', ''),
        open: double.parse(f[1]),
        close: double.parse(f[2]),
        high: double.parse(f[3]),
        low: double.parse(f[4]),
        vol: double.parse(f[5]),
        amount: double.parse(f[6]) / 1000, // 元 → 千元，与主源同口径
      ));
    }
    return out;
  }

  /// 6 位代码前缀定市场：6→SH，0/3→SZ，4/8/9→BJ。
  static String _marketSuffix(String code) {
    final c = code[0];
    if (c == '6') return '.SH';
    if (c == '0' || c == '3') return '.SZ';
    return '.BJ';
  }

  /// 当日全市场快照（clist 实时行情接口，收盘后即最终值），单位手/千元。
  ///
  /// f124=最新行情 Unix 秒：只保留换算到北京时间为 [tradeDate] 的行——
  /// 停牌/退市票的 f124 停留在上一个交易日，天然被排除，无需停牌名单；
  /// 这也让"这笔今天确实有行情"自证，是 tushare 当日日线不可用时的兜底
  /// （见 SyncService 的 todaySettled）。
  ///
  /// data 缺失或解析失败一律抛异常：调用方据此判定"无凭据"，绝不静默当空。
  Future<List<DailyRow>> snapshotBars({required String tradeDate}) async {
    const fields = 'f12,f17,f15,f16,f2,f5,f6,f124';
    final out = <DailyRow>[];
    var pn = 1;
    var fetched = 0;
    var total = 1 << 30;
    // 分页用「已抓取行数」收敛而不是 out.length：被过滤掉的行（停牌/非当日）
    // 不能让翻页提前结束。
    while (fetched < total) {
      final uri = Uri.parse('$apiBase/api/qt/clist/get').replace(queryParameters: {
        'pn': '$pn',
        'pz': '$pageSize',
        'po': '1',
        'np': '1',
        'fltt': '2',
        'invt': '2',
        'fid': 'f12',
        'fs': _clistFs,
        'fields': fields,
      });
      // 单页 5 秒：约 56 页，网差时最坏 5 分钟内收尾；用默认 15 秒最坏会
      // 拖到 14 分钟，拖垮整轮同步。
      final res = await _http
          .get(uri, headers: _ua)
          .timeout(const Duration(seconds: 5));
      final data =
          (jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>)['data']
              as Map<String, dynamic>?;
      if (data == null) {
        throw const FormatException('东财 clist 快照响应缺少 data');
      }
      total = (data['total'] as num?)?.toInt() ?? 0;
      final diff =
          (data['diff'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      if (diff.isEmpty) break;
      fetched += diff.length;
      for (final d in diff) {
        final row = _snapshotRow(d, tradeDate);
        if (row != null) out.add(row);
      }
      pn++;
    }
    return out;
  }

  /// 单行快照解析：停牌/退市（'-'）、缺字段、非当日报价一律返回 null。
  DailyRow? _snapshotRow(Map<String, dynamic> d, String tradeDate) {
    final code = d['f12'];
    final open = _num(d['f17']);
    final high = _num(d['f15']);
    final low = _num(d['f16']);
    final close = _num(d['f2']);
    final vol = _num(d['f5']);
    final amount = _num(d['f6']);
    final f124 = _num(d['f124']);
    if (code is! String ||
        open == null ||
        high == null ||
        low == null ||
        close == null ||
        vol == null ||
        amount == null ||
        f124 == null) {
      return null;
    }
    // 行情时间固定按北京时间（UTC+8）换算：设备在他国时区时用本地时区
    // 换算会整体错一天，全市场行都会被滤掉。
    final t = DateTime.fromMillisecondsSinceEpoch(f124.toInt() * 1000,
            isUtc: true)
        .add(const Duration(hours: 8));
    final date = '${t.year.toString().padLeft(4, '0')}'
        '${t.month.toString().padLeft(2, '0')}'
        '${t.day.toString().padLeft(2, '0')}';
    if (date != tradeDate) return null;
    return DailyRow(
      tsCode: '$code${_marketSuffix(code)}',
      tradeDate: date,
      open: open.toDouble(),
      high: high.toDouble(),
      low: low.toDouble(),
      close: close.toDouble(),
      vol: vol.toDouble(),
      amount: amount.toDouble() / 1000, // 元 → 千元，与主源同口径
    );
  }

  /// fltt=2 下数值字段大多是数字，个别部署给字符串，两者都收。
  static num? _num(Object? v) {
    if (v is num) return v;
    if (v is String) return num.tryParse(v);
    return null;
  }

  /// clist 的全市场筛选串：沪深主板/创业板/科创板/北交所。
  static const _clistFs =
      'm:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23,m:0+t:81+s:2048';

  static const _ua = {'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36'};
  static const _hisBase = 'https://push2his.eastmoney.com';
}
