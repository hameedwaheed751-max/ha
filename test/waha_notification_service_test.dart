import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:untitled/services/waha_notification_service.dart';

void main() {
  test('sends through gateway with Firebase auth and idempotency only', () async {
    http.Request? captured;
    final service = WahaNotificationService(
      gatewayUrl: 'https://gateway.example.test',
      getIdToken: () async => 'firebase-id-token',
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({'success': true, 'messageId': 'message-1'}),
          200,
        );
      }),
    );

    final result = await service.sendText(
      to: '0790 000 0000',
      text: 'Test message',
      eventType: 'subscription_activated',
      idempotencyKey: 'activation:subscriber-1:event-1',
    );

    expect(result.success, isTrue);
    expect(result.messageId, 'message-1');
    expect(captured!.url.path, '/api/waha/send');
    expect(captured!.headers['authorization'], 'Bearer firebase-id-token');
    expect(captured!.headers['idempotency-key'], 'activation:subscriber-1:event-1');
    expect(captured!.headers.containsKey('x-api-key'), isFalse);
    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    expect(body, {
      'to': '9647900000000',
      'text': 'Test message',
      'eventType': 'subscription_activated',
    });
    expect(body.containsKey('session'), isFalse);
  });

  test('starts the authenticated account session and reads its status', () async {
    http.Request? captured;
    final service = WahaNotificationService(
      gatewayUrl: 'https://gateway.example.test',
      getIdToken: () async => 'firebase-id-token',
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({'success': true, 'status': 'SCAN_QR_CODE'}),
          200,
        );
      }),
    );

    final status = await service.startSession();

    expect(status.status, 'SCAN_QR_CODE');
    expect(captured!.method, 'POST');
    expect(captured!.url.path, '/api/waha/session/start');
    expect(captured!.headers['authorization'], 'Bearer firebase-id-token');
    service.close();
  });

  test('decodes the authenticated session QR returned by the gateway', () async {
    http.Request? captured;
    final service = WahaNotificationService(
      gatewayUrl: 'https://gateway.example.test',
      getIdToken: () async => 'firebase-id-token',
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'success': true,
            'mimetype': 'image/png',
            'data': 'data:image/png;base64,AQID',
          }),
          200,
        );
      }),
    );

    final qr = await service.getSessionQr();

    expect(captured!.url.path, '/api/waha/session/qr');
    expect(captured!.headers['authorization'], 'Bearer firebase-id-token');
    expect(qr.mimeType, 'image/png');
    expect(qr.bytes, [1, 2, 3]);
    service.close();
  });

  test('rejects a non-HTTPS remote gateway URL', () async {
    var requestSent = false;
    final service = WahaNotificationService(
      gatewayUrl: 'http://gateway.example.test',
      getIdToken: () async => 'firebase-id-token',
      client: MockClient((_) async {
        requestSent = true;
        return http.Response('{}', 200);
      }),
    );

    final result = await service.sendText(
      to: '0790 000 0000',
      text: 'Test message',
      eventType: 'subscription_activated',
      idempotencyKey: 'manual:event-1',
    );

    expect(result.success, isFalse);
    expect(requestSent, isFalse);
  });

  test('does not send without a Firebase ID token', () async {
    var requestSent = false;
    final service = WahaNotificationService(
      gatewayUrl: 'https://gateway.example.test',
      getIdToken: () async => null,
      client: MockClient((_) async {
        requestSent = true;
        return http.Response('{}', 200);
      }),
    );

    final result = await service.sendText(
      to: '0790 000 0000',
      text: 'Test message',
      eventType: 'subscription_activated',
      idempotencyKey: 'manual:event-2',
    );

    expect(result.success, isFalse);
    expect(requestSent, isFalse);
  });

  test('accepts all dispatcher event types without adding session identity to body', () async {
    final eventTypes = [
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
    ];
    final sentTypes = <String>[];
    final service = WahaNotificationService(
      gatewayUrl: 'https://gateway.example.test',
      getIdToken: () async => 'firebase-id-token',
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        sentTypes.add(body['eventType'] as String);
        expect(body.containsKey('uid'), isFalse);
        expect(body.containsKey('session'), isFalse);
        return http.Response(jsonEncode({'success': true}), 200);
      }),
    );

    for (final (index, eventType) in eventTypes.indexed) {
      final result = await service.sendText(
        to: '0790 000 0000',
        text: 'Mock-only message',
        eventType: eventType,
        idempotencyKey: 'event:$index',
      );
      expect(result.success, isTrue, reason: eventType);
    }

    expect(sentTypes, eventTypes);
    service.close();
  });
}