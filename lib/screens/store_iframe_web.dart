import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// أنواع العرض المسجّلة، كي لا نسجّل النوع نفسه مرتين (تسجيل مكرر يرمي خطأ).
final Set<String> _registered = <String>{};
final Set<String> _registeredLogos = <String>{};

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

web.HTMLImageElement _imgElement(String imageUrl) {
  final img = web.document.createElement('img') as web.HTMLImageElement;
  img.src = imageUrl;
  img.setAttribute('referrerpolicy', 'no-referrer');
  img.setAttribute('alt', '');
  img.style
    ..setProperty('width', '100%')
    ..setProperty('height', '100%')
    ..setProperty('object-fit', 'contain');
  return img;
}

/// شعار المتجر على الويب: عنصر <img> مضمّن بدل Image.network، كي لا تفشل
/// صور الأيقونات عبر النطاقات بسبب CORS على محرّك CanvasKit.
Widget buildStoreLogo(String imageUrl, double size) {
  final viewType = 'store-logo:$imageUrl';
  if (_registeredLogos.add(viewType)) {
    ui_web.platformViewRegistry
        .registerViewFactory(viewType, (int viewId) => _imgElement(imageUrl));
  }
  return SizedBox(
    width: size,
    height: size,
    child: HtmlElementView(viewType: viewType),
  );
}

/// صورة تملأ حيّزها (للمعارض والبطاقات) على الويب، عبر <img> مضمّن.
Widget buildStoreImageFill(String imageUrl) {
  final viewType = 'store-img:$imageUrl';
  if (_registeredLogos.add(viewType)) {
    ui_web.platformViewRegistry
        .registerViewFactory(viewType, (int viewId) => _imgElement(imageUrl));
  }
  return HtmlElementView(viewType: viewType);
}
