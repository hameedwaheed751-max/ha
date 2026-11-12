import 'package:flutter/widgets.dart';

/// غير الويب: لا إطار مضمّن — تُستخدم WebView الأصلية (webview_flutter) بدلاً
/// منه. هذا البديل يضمن أن ملف الشاشة يُترجم على الجوال دون أي رمز ويب.
Widget buildStoreIframe(String url) => const SizedBox.shrink();
