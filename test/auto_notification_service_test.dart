import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';
import 'package:untitled/services/auto_notification_service.dart';
import 'package:untitled/services/whatsapp_notification_dispatcher.dart';

final _subscriberIds = <String, String>{};
var _nextSubscriberId = 0;

void main() {
  final now = DateTime.utc(2026, 10, 30, 12);

  test('does not send at 73 hours, but sends at exactly 72 hours', () async {
    final store = _MemoryExpiryStore();
    final sentTypes = <String>[];
    final subscribers = [
      _subscriber('73-hours', now.add(const Duration(hours: 73))),
      _subscriber('72-hours', now.add(const Duration(hours: 72))),
    ];
    final automation = _automation(
      store: store,
      subscribers: () => subscribers,
      now: () => now,
      send: (subscriber, {required eventType, required eventId}) async {
        sentTypes.add(eventType);
        return const WhatsAppDispatchResult(success: true);
      },
    );

    await automation.run();

    expect(sentTypes, ['expiry_3days']);
    expect(store.items, hasLength(1));
  });

  test('sends when 48 hours or one hour remain', () async {
    for (final hours in [48, 1]) {
      final sent = <String>[];
      final subscriber = _subscriber(
        'subscriber-$hours',
        now.add(Duration(hours: hours)),
      );
      final store = _MemoryExpiryStore();
      final automation = _automation(
        store: store,
        subscribers: () => [subscriber],
        now: () => now,
        send: (subscriber, {required eventType, required eventId}) async {
          sent.add(eventType);
          return const WhatsAppDispatchResult(success: true);
        },
      );

      await automation.run();

      expect(subscriber.active, isTrue);
      expect(subscriber.disabled, isFalse);
      expect(subscriber.endDate.difference(now), Duration(hours: hours));
      expect(store.items, hasLength(1));
      expect(sent, ['expiry_3days']);
    }
  });

  test('expired subscriptions do not get near-expiry events', () async {
    final sent = <String>[];
    final automation = _automation(
      store: _MemoryExpiryStore(),
      subscribers: () => [
        _subscriber('expired', now.subtract(const Duration(minutes: 1))),
      ],
      now: () => now,
      send: (subscriber, {required eventType, required eventId}) async {
        sent.add(eventType);
        return const WhatsAppDispatchResult(success: true);
      },
    );

    await automation.run();

    expect(sent, ['subscription_expired']);
  });

  test(
    'reopening later does not resend a successfully sent deadline',
    () async {
      final store = _MemoryExpiryStore();
      var currentTime = now;
      final subscriber = _subscriber(
        'repeat',
        now.add(const Duration(hours: 48)),
      );
      var sends = 0;
      final automation = _automation(
        store: store,
        subscribers: () => [subscriber],
        now: () => currentTime,
        send: (subscriber, {required eventType, required eventId}) async {
          sends += 1;
          return const WhatsAppDispatchResult(success: true);
        },
      );

      await automation.run();
      currentTime = now.add(const Duration(days: 1));
      await _automation(
        store: store,
        subscribers: () => [subscriber],
        now: () => currentTime,
        send: (subscriber, {required eventType, required eventId}) async {
          sends += 1;
          return const WhatsAppDispatchResult(success: true);
        },
      ).run();

      expect(sends, 1);
      expect(store.items.values.single['status'], 'sent');
    },
  );

  test(
    'manual and automatic near-expiry sends share one idempotent event',
    () async {
      for (final manualFirst in [true, false]) {
        final store = _MemoryExpiryStore();
        final subscriber = _subscriber(
          'manual-auto-$manualFirst',
          now.add(const Duration(hours: 24)),
        );
        final sentEventIds = <String>[];
        final automation = _automation(
          store: store,
          subscribers: () => [subscriber],
          now: () => now,
          send: (subscriber, {required eventType, required eventId}) async {
            sentEventIds.add(eventId);
            return const WhatsAppDispatchResult(success: true);
          },
        );

        if (manualFirst) {
          expect(
            (await automation.sendNearExpiryOnce(subscriber)).success,
            isTrue,
          );
          await automation.run();
        } else {
          await automation.run();
          expect(
            (await automation.sendNearExpiryOnce(subscriber)).success,
            isFalse,
          );
        }

        expect(sentEventIds, hasLength(1));
        expect(store.items.values.single['status'], 'sent');
      }
    },
  );

  test('manual near-expiry send uses the exact 72-hour window', () async {
    final subscriber = _subscriber(
      'manual-window',
      now.add(const Duration(hours: 73)),
    );
    final sentEventIds = <String>[];
    final automation = _automation(
      store: _MemoryExpiryStore(),
      subscribers: () => [subscriber],
      now: () => now,
      send: (subscriber, {required eventType, required eventId}) async {
        sentEventIds.add(eventId);
        return const WhatsAppDispatchResult(success: true);
      },
    );

    expect((await automation.sendNearExpiryOnce(subscriber)).success, isFalse);
    subscriber.endDate = now.add(const Duration(hours: 72));
    expect((await automation.sendNearExpiryOnce(subscriber)).success, isTrue);
    expect(sentEventIds, hasLength(1));
  });

  test('failed sends are retried after the persisted backoff', () async {
    final store = _MemoryExpiryStore();
    var currentTime = now;
    var sends = 0;
    final eventIds = <String>[];
    final automation = _automation(
      store: store,
      subscribers: () => [
        _subscriber('retry', now.add(const Duration(hours: 24))),
      ],
      now: () => currentTime,
      retryDelayForAttempt: (_) => const Duration(minutes: 1),
      send: (subscriber, {required eventType, required eventId}) async {
        sends += 1;
        eventIds.add(eventId);
        if (sends == 1) {
          return const WhatsAppDispatchResult(success: false, statusCode: 503);
        }
        return const WhatsAppDispatchResult(success: true);
      },
    );

    await automation.run();
    expect(store.items.values.single['status'], 'retry');
    currentTime = now.add(const Duration(seconds: 59));
    await automation.run();
    expect(sends, 1);
    currentTime = now.add(const Duration(minutes: 1));
    await automation.run();

    expect(sends, 2);
    expect(eventIds[0], eventIds[1]);
    expect(store.items.values.single['status'], 'sent');
  });

  test(
    'a renewal invalidates a queued event for the previous deadline',
    () async {
      final first = _subscriber('first', now.add(const Duration(hours: 1)));
      final renewed = _subscriber('renewed', now.add(const Duration(hours: 2)));
      final subscribers = [first, renewed];
      final sent = <String>[];
      final eventIds = <String>[];
      final automation = _automation(
        store: _MemoryExpiryStore(),
        subscribers: () => subscribers,
        now: () => now,
        send: (subscriber, {required eventType, required eventId}) async {
          sent.add(subscriber.subscriberId);
          eventIds.add(eventId);
          if (subscriber.subscriberId == first.subscriberId) {
            renewed.endDate = now.add(const Duration(hours: 24));
          }
          return const WhatsAppDispatchResult(success: true);
        },
      );

      await automation.run();
      await automation.run();

      expect(sent, [first.subscriberId, renewed.subscriberId]);
      expect(eventIds[0], isNot(eventIds[1]));
    },
  );

  test('messages are sent sequentially with a configurable interval', () async {
    final delays = <Duration>[];
    var activeSends = 0;
    var maxConcurrentSends = 0;
    final automation = _automation(
      store: _MemoryExpiryStore(),
      subscribers: () => [
        _subscriber('one', now.add(const Duration(hours: 10))),
        _subscriber('two', now.add(const Duration(hours: 11))),
        _subscriber('three', now.add(const Duration(hours: 12))),
      ],
      now: () => now,
      interMessageDelay: const Duration(seconds: 7),
      delay: (duration) async {
        delays.add(duration);
      },
      send: (subscriber, {required eventType, required eventId}) async {
        activeSends += 1;
        if (activeSends > maxConcurrentSends) {
          maxConcurrentSends = activeSends;
        }
        await Future<void>.delayed(Duration.zero);
        activeSends -= 1;
        return const WhatsAppDispatchResult(success: true);
      },
    );

    await automation.run();

    expect(maxConcurrentSends, 1);
    expect(delays, [const Duration(seconds: 7), const Duration(seconds: 7)]);
  });

  test('a 429 response pauses the queue and skips later subscribers', () async {
    final store = _MemoryExpiryStore();
    final sent = <String>[];
    final firstSubscriber = _subscriber(
      'one',
      now.add(const Duration(hours: 1)),
    );
    final automation = _automation(
      store: store,
      subscribers: () => [
        firstSubscriber,
        _subscriber('two', now.add(const Duration(hours: 2))),
      ],
      now: () => now,
      rateLimitPause: const Duration(minutes: 5),
      send: (subscriber, {required eventType, required eventId}) async {
        sent.add(subscriber.subscriberId);
        return const WhatsAppDispatchResult(success: false, statusCode: 429);
      },
    );

    await automation.run();

    expect(sent, [firstSubscriber.subscriberId]);
    expect(store.pauseUntil, now.add(const Duration(minutes: 5)));
  });

  test('an ambiguous idempotency conflict is held for manual review', () async {
    final store = _MemoryExpiryStore();
    var sends = 0;
    final automation = _automation(
      store: store,
      subscribers: () => [
        _subscriber('manual-review', now.add(const Duration(hours: 24))),
      ],
      now: () => now,
      send: (subscriber, {required eventType, required eventId}) async {
        sends += 1;
        return const WhatsAppDispatchResult(success: false, statusCode: 409);
      },
    );

    await automation.run();
    await automation.run();

    expect(sends, 1);
    expect(store.items.values.single['status'], 'manual_review');
  });

  test('concurrent automation calls share one in-flight run', () async {
    final store = _MemoryExpiryStore();
    final sendStarted = Completer<void>();
    final finishSend = Completer<WhatsAppDispatchResult>();
    var sends = 0;
    final automation = _automation(
      store: store,
      subscribers: () => [
        _subscriber('concurrent', now.add(const Duration(hours: 24))),
      ],
      now: () => now,
      send: (subscriber, {required eventType, required eventId}) {
        sends += 1;
        sendStarted.complete();
        return finishSend.future;
      },
    );

    final firstRun = automation.run();
    await sendStarted.future;
    final secondRun = automation.run();
    finishSend.complete(const WhatsAppDispatchResult(success: true));
    await Future.wait([firstRun, secondRun]);

    expect(sends, 1);
  });

  test(
    'the persistent queue lease excludes another automation instance',
    () async {
      final store = _MemoryExpiryStore();
      final sendStarted = Completer<void>();
      final finishSend = Completer<WhatsAppDispatchResult>();
      var sends = 0;
      final sharedSubscriber = _subscriber(
        'cross-instance',
        now.add(const Duration(hours: 24)),
      );
      Future<WhatsAppDispatchResult> sender(
        Subscriber subscriber, {
        required String eventType,
        required String eventId,
      }) {
        sends += 1;
        sendStarted.complete();
        return finishSend.future;
      }

      final first = _automation(
        store: store,
        subscribers: () => [sharedSubscriber],
        now: () => now,
        send: sender,
      );
      final second = _automation(
        store: store,
        subscribers: () => [sharedSubscriber],
        now: () => now,
        send: sender,
      );

      final firstRun = first.run();
      await sendStarted.future;
      await second.run();
      finishSend.complete(const WhatsAppDispatchResult(success: true));
      await firstRun;

      expect(sends, 1);
    },
  );

  test(
    'inactive and disabled subscriptions do not get near-expiry events',
    () async {
      final sent = <String>[];
      final inactive = _subscriber(
        'inactive',
        now.add(const Duration(hours: 2)),
      )..active = false;
      final disabled = _subscriber(
        'disabled',
        now.add(const Duration(hours: 3)),
      )..disabled = true;
      final automation = _automation(
        store: _MemoryExpiryStore(),
        subscribers: () => [inactive, disabled],
        now: () => now,
        send: (subscriber, {required eventType, required eventId}) async {
          sent.add(eventType);
          return const WhatsAppDispatchResult(success: true);
        },
      );

      await automation.run();

      expect(sent, isEmpty);
    },
  );
}

ExpiryNotificationAutomation _automation({
  required ExpiryNotificationStore store,
  required Iterable<Subscriber> Function() subscribers,
  required ExpiryAutomationClock now,
  required ExpiryNotificationSender send,
  Duration interMessageDelay = Duration.zero,
  Duration rateLimitPause = const Duration(minutes: 30),
  ExpiryAutomationDelay? delay,
  Duration Function(int attempt) retryDelayForAttempt = _zeroRetryDelay,
}) {
  return ExpiryNotificationAutomation(
    store: store,
    send: send,
    subscribers: subscribers,
    clock: now,
    delay: delay ?? (_) async {},
    interMessageDelay: interMessageDelay,
    rateLimitPause: rateLimitPause,
    retryDelayForAttempt: retryDelayForAttempt,
  );
}

Duration _zeroRetryDelay(int _) => Duration.zero;

Subscriber _subscriber(String id, DateTime endDate) => Subscriber(
  subscriberId: _subscriberIds.putIfAbsent(id, () {
    _nextSubscriberId += 1;
    return '00000000-0000-4000-8000-'
        '${_nextSubscriberId.toRadixString(16).padLeft(12, '0')}';
  }),
  user: 'Test',
  name: 'Test $id',
  phone: '07900000000',
  address: '',
  ip: '',
  type: 'home',
  price: 100,
  startDate: endDate.subtract(const Duration(days: 30)),
  endDate: endDate,
);

class _MemoryExpiryStore implements ExpiryNotificationStore {
  final Map<String, Map<String, Object?>> items = {};
  String? _owner;
  DateTime? _leaseUntil;
  DateTime? pauseUntil;

  @override
  Future<bool> acquireQueueLease({
    required String owner,
    required DateTime now,
    required Duration leaseDuration,
  }) async {
    if ((_leaseUntil?.isAfter(now) ?? false) ||
        (pauseUntil?.isAfter(now) ?? false)) {
      return false;
    }
    _owner = owner;
    _leaseUntil = now.add(leaseDuration);
    return true;
  }

  @override
  Future<int?> claimNotification({
    required ExpiryNotificationEvent event,
    required String owner,
    required DateTime now,
    required Duration leaseDuration,
  }) async {
    final current = items[event.storageKey] ?? <String, Object?>{};
    if (current['status'] == 'sent' ||
        current['status'] == 'manual_review' ||
        (current['retryAt'] is DateTime &&
            (current['retryAt'] as DateTime).isAfter(now)) ||
        (current['status'] == 'sending' &&
            current['leaseUntil'] is DateTime &&
            (current['leaseUntil'] as DateTime).isAfter(now))) {
      return null;
    }
    final attempts = ((current['attempts'] as int?) ?? 0) + 1;
    items[event.storageKey] = {
      'status': 'sending',
      'owner': owner,
      'attempts': attempts,
      'leaseUntil': now.add(leaseDuration),
    };
    return attempts;
  }

  @override
  Future<void> markSent({
    required ExpiryNotificationEvent event,
    required String owner,
    required DateTime sentAt,
    required String? messageId,
  }) async {
    final current = items[event.storageKey]!;
    if (current['owner'] != owner) throw StateError('Unexpected owner');
    items[event.storageKey] = {...current, 'status': 'sent', 'sentAt': sentAt};
  }

  @override
  Future<void> markRetry({
    required ExpiryNotificationEvent event,
    required String owner,
    required DateTime retryAt,
    required int? statusCode,
  }) async {
    final current = items[event.storageKey]!;
    if (current['owner'] != owner) throw StateError('Unexpected owner');
    items[event.storageKey] = {
      ...current,
      'status': 'retry',
      'retryAt': retryAt,
    };
  }

  @override
  Future<void> markManualReview({
    required ExpiryNotificationEvent event,
    required String owner,
    required int statusCode,
  }) async {
    final current = items[event.storageKey]!;
    if (current['owner'] != owner) throw StateError('Unexpected owner');
    items[event.storageKey] = {
      ...current,
      'status': 'manual_review',
      'statusCode': statusCode,
    };
  }

  @override
  Future<void> pauseQueue({
    required String owner,
    required DateTime until,
  }) async {
    if (_owner != owner) throw StateError('Unexpected owner');
    pauseUntil = until;
    _owner = null;
    _leaseUntil = null;
  }

  @override
  Future<void> releaseQueueLease(String owner) async {
    if (_owner == owner) {
      _owner = null;
      _leaseUntil = null;
    }
  }

  @override
  Future<bool> renewQueueLease({
    required String owner,
    required DateTime now,
    required Duration leaseDuration,
  }) async {
    if (_owner != owner || !(_leaseUntil?.isAfter(now) ?? false)) return false;
    _leaseUntil = now.add(leaseDuration);
    return true;
  }
}
