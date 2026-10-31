import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../models.dart';
import 'render_whatsapp_service.dart';
import 'whatsapp_notification_dispatcher.dart';

typedef ExpiryNotificationSender =
    Future<WhatsAppDispatchResult> Function(
      Subscriber subscriber, {
      required String eventType,
      required String eventId,
    });

typedef ExpiryAutomationClock = DateTime Function();
typedef ExpiryAutomationDelay = Future<void> Function(Duration duration);

class ExpiryNotificationEvent {
  const ExpiryNotificationEvent({
    required this.subscriberId,
    required this.endDateMicros,
    required this.eventType,
    required this.storageKey,
    required this.eventId,
  });

  final String subscriberId;
  final int endDateMicros;
  final String eventType;
  final String storageKey;
  final String eventId;
}

abstract interface class ExpiryNotificationStore {
  Future<bool> acquireQueueLease({
    required String owner,
    required DateTime now,
    required Duration leaseDuration,
  });

  Future<bool> renewQueueLease({
    required String owner,
    required DateTime now,
    required Duration leaseDuration,
  });

  Future<int?> claimNotification({
    required ExpiryNotificationEvent event,
    required String owner,
    required DateTime now,
    required Duration leaseDuration,
  });

  Future<void> markSent({
    required ExpiryNotificationEvent event,
    required String owner,
    required DateTime sentAt,
    required String? messageId,
  });

  Future<void> markRetry({
    required ExpiryNotificationEvent event,
    required String owner,
    required DateTime retryAt,
    required int? statusCode,
  });

  Future<void> markManualReview({
    required ExpiryNotificationEvent event,
    required String owner,
    required int statusCode,
  });

  Future<void> pauseQueue({required String owner, required DateTime until});

  Future<void> releaseQueueLease(String owner);
}

class FirebaseExpiryNotificationStore implements ExpiryNotificationStore {
  FirebaseExpiryNotificationStore({FirebaseAuth? auth, this._database})
    : _uid = (auth ?? FirebaseAuth.instance).currentUser?.uid;

  final String? _uid;
  final FirebaseDatabase? _database;

  DatabaseReference get _queueRef {
    final uid = _uid;
    if (uid == null || uid.isEmpty) {
      throw StateError('A signed-in Firebase user is required.');
    }
    return (_database ?? FirebaseDatabase.instance).ref(
      'agents/$uid/notificationAutomation/expiry3days',
    );
  }

  @override
  Future<bool> acquireQueueLease({
    required String owner,
    required DateTime now,
    required Duration leaseDuration,
  }) async {
    final nowMs = now.millisecondsSinceEpoch;
    final result = await _queueRef.child('control').runTransaction((
      currentData,
    ) {
      final current = _asMap(currentData);
      final leaseUntil = _intValue(current['leaseUntil']);
      final pauseUntil = _intValue(current['pauseUntil']);
      if (leaseUntil > nowMs || pauseUntil > nowMs) {
        return Transaction.abort();
      }
      return Transaction.success({
        ...current,
        'owner': owner,
        'leaseUntil': now.add(leaseDuration).millisecondsSinceEpoch,
      });
    }, applyLocally: false);
    return result.committed;
  }

  @override
  Future<bool> renewQueueLease({
    required String owner,
    required DateTime now,
    required Duration leaseDuration,
  }) async {
    final nowMs = now.millisecondsSinceEpoch;
    final result = await _queueRef.child('control').runTransaction((
      currentData,
    ) {
      final current = _asMap(currentData);
      if (current['owner'] != owner ||
          _intValue(current['leaseUntil']) <= nowMs) {
        return Transaction.abort();
      }
      return Transaction.success({
        ...current,
        'leaseUntil': now.add(leaseDuration).millisecondsSinceEpoch,
      });
    }, applyLocally: false);
    return result.committed;
  }

  @override
  Future<int?> claimNotification({
    required ExpiryNotificationEvent event,
    required String owner,
    required DateTime now,
    required Duration leaseDuration,
  }) async {
    final nowMs = now.millisecondsSinceEpoch;
    var attempts = 0;
    final result = await _queueRef
        .child('items/${event.storageKey}')
        .runTransaction((currentData) {
          final current = _asMap(currentData);
          if (current['status'] == 'sent' ||
              current['status'] == 'manual_review' ||
              _intValue(current['retryAt']) > nowMs ||
              (current['status'] == 'sending' &&
                  _intValue(current['leaseUntil']) > nowMs)) {
            return Transaction.abort();
          }
          attempts = _intValue(current['attempts']) + 1;
          return Transaction.success({
            'status': 'sending',
            'owner': owner,
            'attempts': attempts,
            'endDateMicros': event.endDateMicros,
            'leaseUntil': now.add(leaseDuration).millisecondsSinceEpoch,
          });
        }, applyLocally: false);
    return result.committed ? attempts : null;
  }

  @override
  Future<void> markSent({
    required ExpiryNotificationEvent event,
    required String owner,
    required DateTime sentAt,
    required String? messageId,
  }) async {
    await _updateOwnedItem(event, owner, (current) {
      return {
        'status': 'sent',
        'attempts': _intValue(current['attempts']),
        'endDateMicros': event.endDateMicros,
        'sentAt': sentAt.millisecondsSinceEpoch,
        ...?messageId == null ? null : {'messageId': messageId},
      };
    });
  }

  @override
  Future<void> markRetry({
    required ExpiryNotificationEvent event,
    required String owner,
    required DateTime retryAt,
    required int? statusCode,
  }) async {
    await _updateOwnedItem(event, owner, (current) {
      return {
        'status': 'retry',
        'attempts': _intValue(current['attempts']),
        'endDateMicros': event.endDateMicros,
        'retryAt': retryAt.millisecondsSinceEpoch,
        ...?statusCode == null ? null : {'statusCode': statusCode},
      };
    });
  }

  @override
  Future<void> markManualReview({
    required ExpiryNotificationEvent event,
    required String owner,
    required int statusCode,
  }) async {
    await _updateOwnedItem(event, owner, (current) {
      return {
        'status': 'manual_review',
        'attempts': _intValue(current['attempts']),
        'endDateMicros': event.endDateMicros,
        'statusCode': statusCode,
      };
    });
  }

  Future<void> _updateOwnedItem(
    ExpiryNotificationEvent event,
    String owner,
    Map<String, Object?> Function(Map<String, Object?> current) update,
  ) async {
    final result = await _queueRef
        .child('items/${event.storageKey}')
        .runTransaction((currentData) {
          final current = _asMap(currentData);
          if (current['owner'] != owner || current['status'] != 'sending') {
            return Transaction.abort();
          }
          return Transaction.success(update(current));
        }, applyLocally: false);
    if (!result.committed) {
      throw StateError('Could not persist expiry notification state.');
    }
  }

  @override
  Future<void> pauseQueue({
    required String owner,
    required DateTime until,
  }) async {
    final result = await _queueRef.child('control').runTransaction((
      currentData,
    ) {
      final current = _asMap(currentData);
      if (current['owner'] != owner) return Transaction.abort();
      final pauseUntil = _intValue(current['pauseUntil']);
      return Transaction.success({
        ...current,
        'owner': null,
        'leaseUntil': 0,
        'pauseUntil': max(pauseUntil, until.millisecondsSinceEpoch),
      });
    }, applyLocally: false);
    if (!result.committed) {
      throw StateError('Could not persist the expiry notification pause.');
    }
  }

  @override
  Future<void> releaseQueueLease(String owner) async {
    await _queueRef.child('control').runTransaction((currentData) {
      final current = _asMap(currentData);
      if (current['owner'] != owner) return Transaction.abort();
      return Transaction.success({...current, 'owner': null, 'leaseUntil': 0});
    }, applyLocally: false);
  }

  static Map<String, Object?> _asMap(Object? value) {
    if (value is! Map) return <String, Object?>{};
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  static int _intValue(Object? value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
}

class ExpiryNotificationAutomation {
  ExpiryNotificationAutomation({
    required this.store,
    required this.send,
    required this.subscribers,
    ExpiryAutomationClock? clock,
    ExpiryAutomationDelay? delay,
    this.interMessageDelay = const Duration(seconds: 2),
    this.leaseDuration = const Duration(minutes: 2),
    this.rateLimitPause = const Duration(minutes: 30),
    this.retryDelayForAttempt = _defaultRetryDelay,
  }) : _clock = clock ?? DateTime.now,
       _delay = delay ?? ((duration) => Future<void>.delayed(duration));

  final ExpiryNotificationStore store;
  final ExpiryNotificationSender send;
  final Iterable<Subscriber> Function() subscribers;
  final ExpiryAutomationClock _clock;
  final ExpiryAutomationDelay _delay;
  final Duration interMessageDelay;
  final Duration leaseDuration;
  final Duration rateLimitPause;
  final Duration Function(int attempt) retryDelayForAttempt;
  Future<void>? _activeRun;

  Future<void> run() {
    final activeRun = _activeRun;
    if (activeRun != null) return activeRun;
    final run = _runOnce();
    final sharedRun = run.whenComplete(() => _activeRun = null);
    _activeRun = sharedRun;
    return sharedRun;
  }

  Future<WhatsAppDispatchResult> sendNearExpiryOnce(
    Subscriber subscriber,
  ) async {
    final now = _clock();
    final event = _eventFor(subscriber, 'expiry_3days');
    if (!_eligible(event, subscriber, now) ||
        RenderWhatsAppService.normalizePhone(subscriber.phone).isEmpty ||
        _currentSubscriber(event) == null) {
      return const WhatsAppDispatchResult(
        success: false,
        error: 'notification_not_due_or_subscription_changed',
      );
    }

    final owner = _newOwner(now);
    if (!await store.acquireQueueLease(
      owner: owner,
      now: now,
      leaseDuration: leaseDuration,
    )) {
      return const WhatsAppDispatchResult(
        success: false,
        error: 'notification_queue_busy',
      );
    }

    try {
      final currentTime = _clock();
      if (!_isCurrentAndEligible(event, currentTime)) {
        return const WhatsAppDispatchResult(
          success: false,
          error: 'notification_not_due_or_subscription_changed',
        );
      }
      if (!await store.renewQueueLease(
        owner: owner,
        now: currentTime,
        leaseDuration: leaseDuration,
      )) {
        return const WhatsAppDispatchResult(
          success: false,
          error: 'notification_queue_lease_lost',
        );
      }

      final result = await _processEvent(event, owner);
      return result ??
          const WhatsAppDispatchResult(
            success: false,
            error: 'notification_already_sent_or_in_progress',
          );
    } finally {
      await store.releaseQueueLease(owner);
    }
  }

  Future<void> _runOnce() async {
    final startedAt = _clock();
    final owner = _newOwner(startedAt);
    if (!await store.acquireQueueLease(
      owner: owner,
      now: startedAt,
      leaseDuration: leaseDuration,
    )) {
      return;
    }

    try {
      final events = _dueEvents(subscribers(), startedAt);
      for (final event in events) {
        final now = _clock();
        if (!_isCurrentAndEligible(event, now)) continue;
        if (!await store.renewQueueLease(
          owner: owner,
          now: now,
          leaseDuration: leaseDuration,
        )) {
          break;
        }

        final result = await _processEvent(event, owner);
        if (result?.statusCode == 429) return;

        if (event != events.last) {
          await _delay(interMessageDelay);
        }
      }
    } finally {
      await store.releaseQueueLease(owner);
    }
  }

  Future<WhatsAppDispatchResult?> _processEvent(
    ExpiryNotificationEvent event,
    String owner,
  ) async {
    final attempt = await store.claimNotification(
      event: event,
      owner: owner,
      now: _clock(),
      leaseDuration: leaseDuration,
    );
    if (attempt == null) return null;

    WhatsAppDispatchResult result;
    try {
      final subscriber = _currentSubscriber(event);
      if (subscriber == null || !_eligible(event, subscriber, _clock())) {
        await store.markRetry(
          event: event,
          owner: owner,
          retryAt: _clock(),
          statusCode: null,
        );
        return null;
      }
      result = await send(
        subscriber,
        eventType: event.eventType,
        eventId: event.eventId,
      );
    } on Exception {
      result = const WhatsAppDispatchResult(
        success: false,
        error: 'Notification delivery failed.',
      );
    }

    if (result.success) {
      await store.markSent(
        event: event,
        owner: owner,
        sentAt: _clock(),
        messageId: result.messageId,
      );
    } else {
      if (result.statusCode == 409) {
        await store.markManualReview(
          event: event,
          owner: owner,
          statusCode: result.statusCode!,
        );
      } else {
        await store.markRetry(
          event: event,
          owner: owner,
          retryAt: _clock().add(retryDelayForAttempt(attempt)),
          statusCode: result.statusCode,
        );
      }
      if (result.statusCode == 429) {
        await store.pauseQueue(
          owner: owner,
          until: _clock().add(rateLimitPause),
        );
      }
    }
    return result;
  }

  List<ExpiryNotificationEvent> _dueEvents(
    Iterable<Subscriber> source,
    DateTime now,
  ) {
    final unique = <String, Subscriber>{};
    for (final subscriber in source) {
      unique.putIfAbsent(subscriber.subscriberId, () => subscriber);
    }
    final events = <ExpiryNotificationEvent>[];
    for (final subscriber in unique.values) {
      if (RenderWhatsAppService.normalizePhone(subscriber.phone).isEmpty) {
        continue;
      }
      final remaining = subscriber.endDate.difference(now);
      if (subscriber.active &&
          !subscriber.disabled &&
          remaining > Duration.zero &&
          remaining <= const Duration(hours: 72)) {
        events.add(_eventFor(subscriber, 'expiry_3days'));
      } else if (!subscriber.endDate.isAfter(now)) {
        events.add(_eventFor(subscriber, 'subscription_expired'));
      }
    }
    events.sort((left, right) {
      final dateOrder = left.endDateMicros.compareTo(right.endDateMicros);
      return dateOrder != 0
          ? dateOrder
          : left.subscriberId.compareTo(right.subscriberId);
    });
    return events;
  }

  bool _isCurrentAndEligible(ExpiryNotificationEvent event, DateTime now) {
    final subscriber = _currentSubscriber(event);
    return subscriber != null && _eligible(event, subscriber, now);
  }

  Subscriber? _currentSubscriber(ExpiryNotificationEvent event) {
    for (final subscriber in subscribers()) {
      if (subscriber.subscriberId == event.subscriberId &&
          subscriber.endDate.toUtc().microsecondsSinceEpoch ==
              event.endDateMicros) {
        return subscriber;
      }
    }
    return null;
  }

  static bool _eligible(
    ExpiryNotificationEvent event,
    Subscriber subscriber,
    DateTime now,
  ) {
    if (subscriber.endDate.toUtc().microsecondsSinceEpoch !=
        event.endDateMicros) {
      return false;
    }
    if (event.eventType == 'expiry_3days') {
      final remaining = subscriber.endDate.difference(now);
      return subscriber.active &&
          !subscriber.disabled &&
          remaining > Duration.zero &&
          remaining <= const Duration(hours: 72);
    }
    return !subscriber.endDate.isAfter(now);
  }

  static ExpiryNotificationEvent _eventFor(
    Subscriber subscriber,
    String eventType,
  ) {
    final deadline = subscriber.endDate.toUtc().microsecondsSinceEpoch;
    final identity = '${subscriber.subscriberId}|$eventType|$deadline';
    final digest = sha256.convert(utf8.encode(identity)).toString();
    return ExpiryNotificationEvent(
      subscriberId: subscriber.subscriberId,
      endDateMicros: deadline,
      eventType: eventType,
      storageKey: digest,
      eventId: '$eventType:$digest',
    );
  }

  static String _newOwner(DateTime now) {
    final random = Random.secure();
    final nonce = '${random.nextInt(1 << 32)}:${random.nextInt(1 << 32)}';
    return sha256
        .convert(utf8.encode('${now.microsecondsSinceEpoch}:$nonce'))
        .toString();
  }

  static Duration _defaultRetryDelay(int attempt) {
    final exponent = (attempt - 1).clamp(0, 9).toInt();
    final minutes = min(360, 1 << exponent).toInt();
    return Duration(minutes: minutes);
  }
}

class AutoNotificationService {
  static const Duration expiryCheckInterval = Duration(minutes: 15);
  static Future<void>? _activeExpiryRun;

  static Future<void> runDailyExpiryAutomation() {
    final activeRun = _activeExpiryRun;
    if (activeRun != null) return activeRun;

    final run = _runExpiryAutomation();
    final sharedRun = run
        .catchError((Object error) {
          debugPrint('Expiry notification automation failed: $error');
        })
        .whenComplete(() => _activeExpiryRun = null);
    _activeExpiryRun = sharedRun;
    return sharedRun;
  }

  static Future<void> _runExpiryAutomation() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;

    await _createExpiryAutomation(uid).run();
  }

  static Future<WhatsAppDispatchResult> sendNearExpiryManually(
    Subscriber subscriber, {
    String? template,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return const WhatsAppDispatchResult(
        success: false,
        error: 'A signed-in Firebase user is required.',
      );
    }
    return _createExpiryAutomation(
      uid,
      nearExpiryTemplate: template,
    ).sendNearExpiryOnce(subscriber);
  }

  static ExpiryNotificationAutomation _createExpiryAutomation(
    String uid, {
    String? nearExpiryTemplate,
  }) {
    final dispatcher = WhatsAppNotificationDispatcher();
    final store = FirebaseExpiryNotificationStore();
    return ExpiryNotificationAutomation(
      store: store,
      subscribers: () {
        if (FirebaseAuth.instance.currentUser?.uid != uid) {
          return const <Subscriber>[];
        }
        return AppStore.subscribers;
      },
      send: (subscriber, {required eventType, required eventId}) {
        if (eventType == 'expiry_3days') {
          return dispatcher.notifySubscriptionExpiresIn3Days(
            subscriber,
            template:
                nearExpiryTemplate ?? AppStore.messageTemplates['nearExpiry'],
            eventId: eventId,
          );
        }
        return dispatcher.notifySubscriptionExpired(
          subscriber,
          template: AppStore.messageTemplates['expired'],
          eventId: eventId,
        );
      },
    );
  }

  static Future<void> notifyDebtSettledIfNeeded({
    required Subscriber subscriber,
    required double oldRemaining,
    required double newRemaining,
  }) async {
    if (oldRemaining <= 0.0001 || newRemaining > 0.0001) {
      return;
    }

    final phone = RenderWhatsAppService.normalizePhone(subscriber.phone);
    if (phone.isEmpty) {
      return;
    }

    RenderWhatsAppService.dispatchInBackground(
      WhatsAppNotificationDispatcher().notifyDebtPaid(
        subscriber,
        amountPaid: oldRemaining,
        remainingBalance: newRemaining,
        eventId:
            'settled_${subscriber.subscriberId}_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
  }
}
