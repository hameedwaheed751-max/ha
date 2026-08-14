import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

String? readRuntimeAppConfig(String key) {
  try {
    final config = web.window
        .getProperty<JSObject?>('__APP_CONFIG__'.toJS);
    if (config == null) return null;

    final value = config.getProperty<JSAny?>(key.toJS);
    if (value != null && value.isA<JSString>()) {
      final text = (value as JSString).toDart.trim();
      if (text.isNotEmpty) return text;
    }
  } catch (_) {}
  return null;
}