import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class WhatsAppNotificationEventPreference {
  const WhatsAppNotificationEventPreference({
    this.enabled = true,
    this.message,
  });

  final bool enabled;
  final String? message;
}

abstract interface class WhatsAppNotificationPreferences {
  Future<WhatsAppNotificationEventPreference> load(String eventType);

  Future<void> save(
    String eventType,
    WhatsAppNotificationEventPreference preference,
  );
}

/// Maps a saved-template key (as used by [AppStore.messageTemplates] and the
/// manual send sheet) to the WhatsApp notification event type whose per-event
/// preference message overrides it. `'extension'` has no notification event.
const Map<String, String> manualTemplateEventTypes = {
  'activation': 'subscription_activated',
  'nearExpiry': 'expiry_3days',
  'expired': 'subscription_expired',
  'debt': 'debt_reminder',
  'debtPaid': 'debt_paid',
};

/// Resolves the message a manual send should use: the agent's saved event
/// preference ([preferenceMessage]) wins, falling back to the local template
/// ([fallback]) when it is null or blank. Keeps the manual send sheet in sync
/// with what the agent edited in the WhatsApp events screen.
String resolveManualTemplateMessage({
  required String? preferenceMessage,
  required String fallback,
}) {
  final trimmed = preferenceMessage?.trim() ?? '';
  return trimmed.isEmpty ? fallback : preferenceMessage!;
}

class FirebaseWhatsAppNotificationPreferences
    implements WhatsAppNotificationPreferences {
  FirebaseWhatsAppNotificationPreferences({
    this._auth,
    this._database,
  });

  static const Set<String> eventTypes = {
    'subscription_activated',
    'debt_reminder',
    'expiry_3days',
    'subscription_expired',
    'debt_paid',
  };

  final FirebaseAuth? _auth;
  final FirebaseDatabase? _database;

  String get _currentUid {
    final uid = (_auth ?? FirebaseAuth.instance).currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw StateError('A signed-in Firebase user is required.');
    }
    return uid;
  }

  DatabaseReference _eventRef(String eventType) {
    if (!eventTypes.contains(eventType)) {
      throw ArgumentError.value(eventType, 'eventType', 'Unsupported event.');
    }
    return (_database ?? FirebaseDatabase.instance).ref(
      'agents/$_currentUid/settings/whatsappNotifications/$eventType',
    );
  }

  @override
  Future<WhatsAppNotificationEventPreference> load(String eventType) async {
    final snapshot = await _eventRef(eventType).get();
    if (!snapshot.exists) {
      return const WhatsAppNotificationEventPreference();
    }
    final value = snapshot.value;
    if (value is! Map) {
      throw const FormatException('Invalid WhatsApp event settings.');
    }
    final enabled = value['enabled'];
    final message = value['message'];
    if ((enabled != null && enabled is! bool) ||
        (message != null && message is! String)) {
      throw const FormatException('Invalid WhatsApp event settings.');
    }
    return WhatsAppNotificationEventPreference(
      enabled: enabled as bool? ?? true,
      message: message as String?,
    );
  }

  @override
  Future<void> save(
    String eventType,
    WhatsAppNotificationEventPreference preference,
  ) async {
    await _eventRef(eventType).update({
      'enabled': preference.enabled,
      'message': (preference.message?.trim().isEmpty ?? true)
          ? null
          : preference.message,
    });
  }
}
