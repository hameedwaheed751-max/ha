import 'package:flutter/material.dart';

/// غير الويب: لا إطار مضمّن — تُستخدم WebView الأصلية (webview_flutter) بدلاً
/// منه. هذا البديل يضمن أن ملف الشاشة يُترجم على الجوال دون أي رمز ويب.
Widget buildStoreIframe(String url) => const SizedBox.shrink();

/// شعار المتجر على الجوال: Image.network عادية (لا مشكلة CORS على الجوال)،
/// مع أيقونة بديلة إن فشل التحميل.
Widget buildStoreLogo(String imageUrl, double size) => Image.network(
      imageUrl,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) =>
          Icon(Icons.storefront_rounded, size: size * 0.9),
    );

/// صورة تملأ حيّزها (للمعارض والبطاقات) على الجوال.
Widget buildStoreImageFill(String imageUrl) => Image.network(
      imageUrl,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) =>
          const Center(child: Icon(Icons.broken_image_outlined, size: 48)),
    );
