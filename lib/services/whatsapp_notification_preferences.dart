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

class FirebaseWhatsAppNotificationPreferences
    implements WhatsAppNotificationPreferences {
  FirebaseWhatsAppNotificationPreferences({
    FirebaseAuth? auth,
    FirebaseDatabase? database,
  }) : _auth = auth,
       _database = database;

  static const Set<String> eventTypes = {
    'subscription_activated',
    'debt_reminder',
    'expiry_3days',
    'subscription_expired',
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
