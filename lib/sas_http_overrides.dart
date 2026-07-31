void configureSasHttpOverrides({required bool allowBadCertificates}) {
  // No-op for Flutter Web and any platform without dart:io.
  // Browser networking uses the configured HTTPS Render proxy by default.
}