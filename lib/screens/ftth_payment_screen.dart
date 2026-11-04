import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

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

  /// تُبنى مرة واحدة: إعادة بناء WebView أو تغيير حجمها أثناء الكتابة
  /// تُفقدها التركيز فتُغلق لوحة المفاتيح.
  late final Widget _webView;

  // التقدم والخطأ خارج setState حتى لا يُعاد بناء الصفحة مع كل نسبة تحميل.
  final _progress = ValueNotifier<int>(0);
  final _error = ValueNotifier<String?>(null);
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigation,
          onPageStarted: (url) {
            if (_isStatusPage(url)) _finish();
          },
          onProgress: (value) => _progress.value = value,
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) return;
            _error.value = error.description;
          },
        ),
      );

    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      // صفحة رمز التحقق من البنك (3-D Secure) تعمل داخل إطار من نطاق آخر
      // وتحتاج كوكيز ذلك النطاق، وأندرويد يمنعها افتراضياً فيفشل التأكيد.
      AndroidWebViewCookieManager(
        const PlatformWebViewCookieManagerCreationParams(),
      ).setAcceptThirdPartyCookies(platform, true);
      _webView = WebViewWidget.fromPlatformCreationParams(
        params: AndroidWebViewWidgetCreationParams(
          controller: platform,
          // العرض الهجين يُبقي لوحة المفاتيح ثابتة في حقول الإدخال.
          displayWithHybridComposition: true,
        ),
      );
    } else {
      _webView = WebViewWidget(controller: _controller);
    }
    _controller.loadRequest(widget.paymentUrl);
  }

  @override
  void dispose() {
    _progress.dispose();
    _error.dispose();
    super.dispose();
  }

  NavigationDecision _onNavigation(NavigationRequest request) {
    if (_isStatusPage(request.url)) {
      _finish();
      return NavigationDecision.prevent;
    }
    // بعض البنوك تفتح تطبيقها للتأكيد (intent:// أو ما يشبهه).
    final uri = Uri.tryParse(request.url);
    if (uri != null && uri.scheme != 'http' && uri.scheme != 'https') {
      launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      ).catchError((_) => false);
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  bool _isStatusPage(String url) => url.startsWith(widget.statusPageUrl);

  void _finish() {
    if (_done || !mounted) return;
    _done = true;
    Navigator.of(context).pop(true);
  }

  Future<void> _reload() async {
    _error.value = null;
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
        ),
        body: Stack(
          children: [
            // صفحة البوابة نفسها باتجاهها الأصلي.
            Positioned.fill(
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: _webView,
              ),
            ),
            // شريط التحميل فوق الصفحة لا يغيّر حجمها.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ValueListenableBuilder<int>(
                valueListenable: _progress,
                builder: (context, value, child) => value >= 100
                    ? const SizedBox.shrink()
                    : LinearProgressIndicator(value: value / 100),
              ),
            ),
            Positioned.fill(
              child: ValueListenableBuilder<String?>(
                valueListenable: _error,
                builder: (context, error, child) => error == null
                    ? const IgnorePointer(child: SizedBox.shrink())
                    : ColoredBox(
                        color: Theme.of(context).colorScheme.surface,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'تعذر تحميل صفحة الدفع:\n$error',
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
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
