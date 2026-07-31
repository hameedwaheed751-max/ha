import 'dart:io';

void configureSasHttpOverrides({required bool allowBadCertificates}) {
  if (!allowBadCertificates) return;
  HttpOverrides.global = _SasHttpOverrides();
}

class _SasHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}