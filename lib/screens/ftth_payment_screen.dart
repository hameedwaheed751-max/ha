import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// يفتح صفحة دفع Tabadul داخل التطبيق. حين تعيد البوابة التوجيه إلى صفحة
/// حالة الدفع في FTTH تُغلق الصفحة وترجع true ليتحقق التطبيق من التجديد.
/// الرجوع قبل ذلك يرجع false ويبقى الطلب معلقاً.
class FtthPaymentScreen extends StatefulWidget {
  const FtthPaymentScreen({
    super.key,
    required this.paymentUrl,
    required this.statusPageUrl,
  });

  final Uri paymentUrl;
  final String statusPageUrl;

  /// على الويب لا توجد WebView، فتُفتح الصفحة في المتصفح كما كانت.
  static Future<bool> open(
    BuildContext context, {
    required Uri paymentUrl,
    required String statusPageUrl,
  }) async {
    if (kIsWeb) {
      await launchUrl(paymentUrl, mode: LaunchMode.externalApplication);
      return false;
    }
    final finished = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => FtthPaymentScreen(
          paymentUrl: paymentUrl,
          statusPageUrl: statusPageUrl,
        ),
      ),
    );
    return finished ?? false;
  }

  @override
  State<FtthPaymentScreen> createState() => _FtthPaymentScreenState();
}

class _FtthPaymentScreenState extends State<FtthPaymentScreen> {
  late final WebViewController _controller;
  int _progress = 0;
  String? _error;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (_isStatusPage(request.url)) {
              _finish();
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageStarted: (url) {
            if (_isStatusPage(url)) _finish();
          },
          onProgress: (value) {
            if (mounted) setState(() => _progress = value);
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == false || !mounted) return;
            setState(() => _error = error.description);
          },
        ),
      )
      ..loadRequest(widget.paymentUrl);
  }

  bool _isStatusPage(String url) => url.startsWith(widget.statusPageUrl);

  void _finish() {
    if (_done || !mounted) return;
    _done = true;
    Navigator.of(context).pop(true);
  }

  Future<void> _reload() async {
    setState(() => _error = null);
    await _controller.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('الدفع بالماستر'),
          leading: IconButton(
            tooltip: 'إغلاق',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(false),
          ),
          actions: [
            IconButton(
              tooltip: 'إعادة التحميل',
              icon: const Icon(Icons.refresh),
              onPressed: _reload,
            ),
          ],
          bottom: _progress < 100
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(3),
                  child: LinearProgressIndicator(value: _progress / 100),
                )
              : null,
        ),
        body: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'تعذر تحميل صفحة الدفع:\n$_error',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _reload,
                        child: const Text('إعادة المحاولة'),
                      ),
                    ],
                  ),
                ),
              )
            // صفحة البوابة نفسها باتجاهها الأصلي.
            : Directionality(
                textDirection: TextDirection.ltr,
                child: WebViewWidget(controller: _controller),
              ),
      ),
    );
  }
}
