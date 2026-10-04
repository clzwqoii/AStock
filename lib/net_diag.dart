/// 把底层网络/接口异常翻译成用户能照着做的人话，并提供自检入口。
/// 安卓真机最常见的是 DNS 解析失败（开着代理/VPN、或网络本身不通），原文是
/// `SocketException: Failed host lookup ... errno = 7`，必须转成可操作提示。
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as h;

import 'data/tushare_client.dart';

/// tushare 主机（自检对象）。
const kTushareHost = 'api.tushare.pro';

/// 同步失败的展示文案：优先给可操作建议，拿不准才带原文。
/// 绝不回显 token 等敏感值（调用方只应传异常本身）。
String describeSyncError(Object e) {
  final text = '$e';
  final lower = text.toLowerCase();
  final networked = e is SocketException ||
      e is HandshakeException ||
      e is TimeoutException ||
      lower.contains('failed host lookup') ||
      lower.contains('no address associated with hostname');

  if (e is TushareException) {
    switch (e.code) {
      case 40203:
        return 'tushare 限频：正在自动等待重试，稍后就好';
      case 20001:
      case 20002:
        return 'tushare 拒绝了请求（可能是 token 无效或已过期）：请到「设置」重新填写并保存';
      case 408:
        return 'tushare 响应超时：网络偏慢，请稍后重试';
    }
    return 'tushare 返回错误（code ${e.code}）：${e.message}';
  }

  if (e is HandshakeException || lower.contains('handshake') || lower.contains('certificate')) {
    return 'HTTPS 握手失败：多半是代理/VPN 干扰，请关闭代理或切换网络后重试';
  }

  if (e is TimeoutException || lower.contains('timed out') || lower.contains('timeout')) {
    return '连接超时：网络过慢或不稳定，请切换 Wi-Fi/蜂窝数据后重试';
  }

  if (networked) {
    // 网络不通时同步会自动降级新浪逐股补数（全市场约 10 分钟），提示里说清楚，避免误以为卡死
    return 'tushare 连不上（${e is TushareException ? e.message : '网络不可达'}），'
        '已自动降级为新浪逐股补数：慢一些但数据照常入库，请保持 App 在前台';
  }

  return '同步失败：$text';
}

/// 网络自检：DNS 解析 + HTTPS 连通性，返回一段可直接给人看的中文结论。
/// [lookup]/[probe] 可注入，测试不碰真实网络。
Future<String> diagnoseNetwork({
  String host = kTushareHost,
  Future<List<InternetAddress>> Function(String host)? lookup,
  Future<void> Function(String host)? probe,
  h.Client? client,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final resolve = lookup ?? (host) => InternetAddress.lookup(host);
  final ping = probe ?? (host) => _probeHttps(host, client ?? h.Client(), timeout);

  final sw = Stopwatch()..start();
  try {
    final addrs = await resolve(host);
    sw.stop();
    if (addrs.isEmpty) return 'DNS 返回空结果：$host 没有可用地址，请检查代理/VPN 与网络';
    final ips = addrs.map((a) => a.address).join(', ');
    try {
      await ping(host);
      return 'DNS 正常：$host → $ips（${sw.elapsedMilliseconds}ms）；'
          'HTTPS 正常：可以连上 tushare 服务器，若仍同步失败请检查 token 额度';
    } on SocketException catch (e) {
      return 'DNS 正常：$host → $ips，但连不上服务器（${e.osError?.message ?? e.message}）。'
          '这是网络连通性问题，请切换 Wi-Fi/蜂窝数据或关闭代理/VPN';
    } on TimeoutException {
      return 'DNS 正常：$host → $ips，但 HTTPS 超过 ${timeout.inSeconds} 秒无响应。'
          '网络过慢或被代理拦截，请关闭代理/VPN 后重试';
    }
  } on SocketException {
    sw.stop();
    return 'DNS 解析失败：无法解析 $host。请检查当前网络；'
        '若开着代理/VPN（含规则模式/ fake-ip 模式）请先关闭再试';
  } on TimeoutException {
    return 'DNS 查询超时：当前网络无法解析 $host，请切换网络后重试';
  }
}

Future<void> _probeHttps(String host, h.Client client, Duration timeout) async {
  final res = await client
      .head(Uri.https(host, '/'))
      .timeout(timeout);
  // 301/302/403/404 都算「能连上」：tushare 根路径本就不返回业务内容
  if (res.statusCode >= 500) {
    throw const SocketException('服务器返回 5xx');
  }
}
