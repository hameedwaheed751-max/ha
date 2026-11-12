import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// أنواع العرض المسجّلة، كي لا نسجّل النوع نفسه مرتين (تسجيل مكرر يرمي خطأ).
final Set<String> _registered = <String>{};

/// الويب: يضمّن رابط المتجر داخل التطبيق عبر عنصر <iframe>، فيُفتح المتجر
/// داخل «المشتريات» بدل تبويب خارجي. قد يرفض بعض المواقع التضمين
/// (X-Frame-Options)، فيبقى زر «فتح في المتصفح» بديلاً في الشاشة.
Widget buildStoreIframe(String url) {
  final viewType = 'store-iframe:$url';
  if (_registered.add(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(
      viewType,
      (int viewId) {
        final iframe =
            web.document.createElement('iframe') as web.HTMLIFrameElement;
        iframe.src = url;
        iframe.setAttribute('loading', 'lazy');
        // صندوق أمان: يسمح بالتصفّح والنماذج دون منح الإطار صلاحيات أوسع.
        iframe.setAttribute(
          'sandbox',
          'allow-forms allow-scripts allow-same-origin allow-popups',
        );
        iframe.style
          ..setProperty('border', 'none')
          ..setProperty('width', '100%')
          ..setProperty('height', '100%');
        return iframe;
      },
    );
  }
  return HtmlElementView(viewType: viewType);
}
