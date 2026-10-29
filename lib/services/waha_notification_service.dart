import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class WahaSendResult {
  const WahaSendResult({
    required this.success,
    this.messageId,
    this.error,
    this.statusCode,
  });

  final bool success;
  final String? messageId;
  final String? error;
  final int? statusCode;
}

class WahaGatewayException implements Exception {
  const WahaGatewayException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class WahaSessionStatus {
  const WahaSessionStatus(this.status, {this.phoneNumber});

  final String status;
  final String? phoneNumber;

  bool get isConnected => status == 'WORKING';
  bool get needsQr => status == 'SCAN_QR_CODE';
}

class WahaQrCode {
  const WahaQrCode({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;
}

class WahaNotificationService {
  WahaNotificationService({
    required String gatewayUrl,
    required Future<String?> Function() getIdToken,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _gatewayUrl = gatewayUrl.trim(),
       _getIdToken = getIdToken,
       _client = client ?? http.Client();

  static const String _configuredGatewayUrl = String.fromEnvironment(
    'WAHA_GATEWAY_URL',
  );

  final String _gatewayUrl;
  final Future<String?> Function() _getIdToken;
  final http.Client _client;
  final Duration timeout;

  void close() => _client.close();

  factory WahaNotificationService.forCurrentUser({http.Client? client}) {
    final auth = FirebaseAuth.instance;
    return WahaNotificationService(
      gatewayUrl: _configuredGatewayUrl,
      getIdToken: () async {
        final user = auth.currentUser;
        if (user == null) return null;
        return user.getIdToken();
      },
      client: client,
    );
  }

  Future<WahaSessionStatus> startSession() async {
    final payload = await _requestJson('POST', '/api/waha/session/start');
    return _readSessionStatus(payload);
  }

  Future<WahaSessionStatus> getSessionStatus() async {
    final payload = await _requestJson('GET', '/api/waha/session/status');
    return _readSessionStatus(payload);
  }

  Future<WahaQrCode> getSessionQr() async {
    final payload = await _requestJson('GET', '/api/waha/session/qr');
    final data = payload['data'];
    final mimeType = payload['mimetype'];
    if (data is! String || mimeType is! String || !mimeType.startsWith('image/')) {
      throw const WahaGatewayException('Gateway returned an invalid QR response.');
    }

    final dataUriPrefix = 'data:$mimeType;base64,';
    final base64Data = data.startsWith('data:')
        ? data.startsWith(dataUriPrefix)
            ? data.substring(dataUriPrefix.length)
            : null
        : data;
    if (base64Data == null) {
      throw const WahaGatewayException('Gateway returned an invalid QR image.');
    }
    try {
      final bytes = base64Decode(base64Data);
      if (bytes.isEmpty) throw const FormatException('Empty QR image.');
      return WahaQrCode(bytes: bytes, mimeType: mimeType);
    } on FormatException {
      throw const WahaGatewayException('Gateway returned an invalid QR image.');
    }
  }

  Future<WahaSessionStatus> reconnectSession() async {
    final payload = await _requestJson('POST', '/api/waha/session/reconnect');
    return _readSessionStatus(payload);
  }

  Future<WahaSessionStatus> disconnectSession() async {
    final payload = await _requestJson('POST', '/api/waha/session/disconnect');
    return _readSessionStatus(payload);
  }

  WahaSessionStatus _readSessionStatus(Map<String, dynamic> payload) {
    final status = payload['status'];
    if (status is! String || status.isEmpty) {
      throw const WahaGatewayException('Gateway returned an invalid session status.');
    }
    final phoneNumber = payload['phoneNumber'];
    return WahaSessionStatus(
      status,
      phoneNumber: phoneNumber is String ? phoneNumber : null,
    );
  }

  Future<Map<String, dynamic>> _requestJson(String method, String path) async {
    final baseUri = Uri.tryParse(_gatewayUrl);
    if (baseUri == null || !_isAllowedGatewayUri(baseUri)) {
      throw const WahaGatewayException(
        'WAHA gateway URL is missing or must use HTTPS.',
      );
    }

    String idToken;
    try {
      idToken = (await _getIdToken())?.trim() ?? '';
    } on Exception {
      throw const WahaGatewayException('Could not authenticate with Firebase.');
    }
    if (idToken.isEmpty) {
      throw const WahaGatewayException('A signed-in Firebase user is required.');
    }

    try {
      final endpoint = baseUri.resolve(path);
      final response = method == 'POST'
          ? await _client
                .post(
                  endpoint,
                  headers: {
                    'Authorization': 'Bearer $idToken',
                    'Content-Type': 'application/json',
                  },
                  body: '{}',
                )
                .timeout(timeout)
          : await _client
                .get(
                  endpoint,
                  headers: {'Authorization': 'Bearer $idToken'},
                )
                .timeout(timeout);
      Map<String, dynamic> payload = const {};
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) payload = decoded;
      } on FormatException {
        // Keep upstream bodies out of the client-facing error.
      }

      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          payload['success'] != true) {
        final error = payload['error'];
        throw WahaGatewayException(
          error is String
              ? error
              : 'WAHA gateway returned HTTP ${response.statusCode}.',
          statusCode: response.statusCode,
        );
      }
      return payload;
    } on WahaGatewayException {
      rethrow;
    } on Exception {
      throw const WahaGatewayException('Could not connect to the WAHA gateway.');
    }
  }

  Future<WahaSendResult> sendText({
    required String to,
    required String text,
    required String eventType,
    required String idempotencyKey,
  }) async {
    final normalizedTo = _normalizePhone(to);
    if (normalizedTo.isEmpty || text.trim().isEmpty) {
      return const WahaSendResult(
        success: false,
        error: 'Recipient and message are required.',
      );
    }
    if (idempotencyKey.trim().isEmpty || idempotencyKey.length > 200) {
      return const WahaSendResult(
        success: false,
        error: 'A valid idempotency key is required.',
      );
    }

    final baseUri = Uri.tryParse(_gatewayUrl);
    if (baseUri == null || !_isAllowedGatewayUri(baseUri)) {
      return const WahaSendResult(
        success: false,
        error: 'WAHA gateway URL is missing or must use HTTPS.',
      );
    }

    if (!const {
      'subscription_activated',
      'subscription_renewed',
      'debt_reminder',
      'debt_paid',
      'expiry_3days',
      'subscription_expired',
      'general_message',
      'broadcast',
      'payment_approved',
      'payment_rejected',
    }.contains(eventType)) {
      return const WahaSendResult(
        success: false,
        error: 'Unsupported WhatsApp event type.',
      );
    }

    String idToken;
    try {
      idToken = (await _getIdToken())?.trim() ?? '';
    } on Exception catch (error) {
      return WahaSendResult(success: false, error: error.toString());
    }
    if (idToken.isEmpty) {
      return const WahaSendResult(
        success: false,
        error: 'A signed-in Firebase user is required.',
      );
    }

    final endpoint = baseUri.resolve('/api/waha/send');
    try {
      final response = await _client
          .post(
            endpoint,
            headers: {
              'Authorization': 'Bearer $idToken',
              'Content-Type': 'application/json',
              'Idempotency-Key': idempotencyKey,
            },
            body: jsonEncode({
              'to': normalizedTo,
              'text': text.trim(),
              'eventType': eventType,
            }),
          )
          .timeout(timeout);

      Map<String, dynamic> payload = const {};
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) payload = decoded;
      } catch (_) {
        // The gateway may return a non-JSON error from an upstream service.
      }

      final success = response.statusCode >= 200 &&
          response.statusCode < 300 &&
          payload['success'] == true;
      return WahaSendResult(
        success: success,
        messageId: payload['messageId']?.toString(),
        error: success
            ? null
            : (payload['error']?.toString() ??
                  'WAHA gateway returned HTTP ${response.statusCode}.'),
        statusCode: response.statusCode,
      );
    } on Exception catch (error) {
      return WahaSendResult(success: false, error: error.toString());
    }
  }

  static bool _isAllowedGatewayUri(Uri uri) {
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      return false;
    }
    if (uri.scheme == 'https') return true;
    return uri.scheme == 'http' &&
        (uri.host == 'localhost' || uri.host == '127.0.0.1');
  }

  static String _normalizePhone(String phone) {
    var normalized = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (normalized.startsWith('00')) normalized = normalized.substring(2);
    if (normalized.startsWith('9640')) {
      normalized = '964${normalized.substring(4)}';
    } else if (normalized.startsWith('0')) {
      normalized = '964${normalized.substring(1)}';
    } else if (normalized.length == 10 && normalized.startsWith('7')) {
      normalized = '964$normalized';
    }
    return normalized;
  }
}