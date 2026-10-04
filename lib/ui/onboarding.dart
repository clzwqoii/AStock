/// 首次启动引导页：三步（注册 tushare → 粘贴 Token → 开始选股）。
/// token 为空时自动弹出；可「稍后再说」跳过（本次启动不再弹）。
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'colors.dart';

typedef LaunchUrlFn = Future<void> Function(Uri url);

const kTushareRegisterUrl = 'https://tushare.pro/register';

Future<void> defaultLaunchUrl(Uri url) async {
  try {
    await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    // 无浏览器/插件异常时静默跳过（链接文字已显示，用户可手动访问）。
  }
}

class OnboardingDialog extends StatefulWidget {
  const OnboardingDialog({super.key, required this.onSubmit, this.launchUrl});

  final Future<void> Function(String token) onSubmit;
  final LaunchUrlFn? launchUrl;

  @override
  State<OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<OnboardingDialog> {
  final _token = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _launch() async {
    final fn = widget.launchUrl ?? defaultLaunchUrl;
    await fn(Uri.parse(kTushareRegisterUrl));
  }

  Future<void> _submit() async {
    final token = _token.text.trim();
    if (token.isEmpty || _busy) return;
    setState(() => _busy = true);
    await widget.onSubmit(token);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('欢迎使用 A股选股台', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          SizedBox(height: 4),
          Text('三步开始你的规则选股', style: TextStyle(fontSize: 12, color: AppColors.dim)),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _step(1, '注册 tushare 账号', '免费注册并登录，即可获取数据权限', link: true),
            _step(2, '粘贴你的 Token', '登录后复制 Token，粘贴到下方输入框'),
            _step(3, '开始选股', '保存后自动增量同步全市场日线'),
            const SizedBox(height: 6),
            TextField(
              controller: _token,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'tushare Token',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('稍后再说'),
        ),
        FilledButton(onPressed: _busy ? null : _submit, child: const Text('完成并开始')),
      ],
    );
  }

  Widget _step(int n, String title, String desc, {bool link = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 24,
              height: 24,
              margin: const EdgeInsets.only(top: 2),
              decoration: const BoxDecoration(color: Color(0xFFEDF0F5), shape: BoxShape.circle),
              child: Center(
                child: Text('$n', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF5B6572))),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(desc, style: const TextStyle(fontSize: 12, color: AppColors.dim)),
                  if (link)
                    TextButton.icon(
                      onPressed: _launch,
                      icon: const Icon(Icons.open_in_new, size: 14),
                      label: const Text('打开 tushare.pro', style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 30), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
}