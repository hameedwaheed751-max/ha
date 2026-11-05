import 'package:flutter/foundation.dart';
import 'models.dart';
import 'sas_api_service.dart';
import 'services/trial_guard_service.dart';

class SasSyncResult {
  final int read;
  final int added;
  final int updated;
  const SasSyncResult({
    required this.read,
    required this.added,
    required this.updated,
  });
}

class _SessionIndex {
  _SessionIndex(List<Map<String, dynamic>> sessions) {
    for (final session in sessions) {
      final username = SasSyncService._extractSessionText(session, [
        'username',
        'user',
        'user_name',
        'login',
        'name',
      ]).toLowerCase();
      // id الجلسة لا يدل على المشترك إلا إذا خلا الصف من اسمه.
      final sasId = SasSyncService._extractSessionText(session, [
        'user_id',
        if (username.isEmpty) 'id',
        'uid',
        'uuid',
      ]).toLowerCase();
      final ip = SasSyncService._extractIp(session);
      if (username.isNotEmpty) _ipByUser[username] = ip;
      if (sasId.isNotEmpty) _ipBySasId[sasId] = ip;
    }
  }

  final _ipByUser = <String, String>{};
  final _ipBySasId = <String, String>{};

  /// فارغ إذا كان متصلاً دون IP معروف، و null إذا لم يكن متصلاً.
  String? ipOf(Subscriber subscriber) =>
      _ipByUser[subscriber.user.trim().toLowerCase()] ??
      _ipBySasId[subscriber.sasId.trim().toLowerCase()];
}

class SasSyncService {
  static const _endDateKeys = [
    'expiration',
    'expiration_date',
    'expire_date',
    'end_date',
    'endDate',
    'expires_at',
    'expiry_date',
  ];

  static DateTime? activationDateFromSas(dynamic node) {
    const keys = ['activation_date', 'activated_at', 'start_date', 'from_date'];

    DateTime? parse(dynamic value) {
      if (value is DateTime) return value;
      if (value is num) {
        final milliseconds = value.abs() < 100000000000
            ? value.toInt() * 1000
            : value.toInt();
        return DateTime.fromMillisecondsSinceEpoch(milliseconds);
      }
      final text = (value ?? '').toString().trim();
      if (text.isEmpty) return null;
      final parsed = DateTime.tryParse(text);
      if (parsed != null) return parsed;
      final parts = text.split(RegExp(r'[/\-]'));
      if (parts.length == 3) {
        final day = int.tryParse(parts[0]);
        final month = int.tryParse(parts[1]);
        final year = int.tryParse(parts[2].split(' ').first);
        if (day != null && month != null && year != null && year > 1900) {
          return DateTime(year, month, day);
        }
      }
      return null;
    }

    DateTime? find(dynamic value) {
      if (value is Map) {
        for (final key in keys) {
          if (value.containsKey(key)) {
            final parsed = parse(value[key]);
            if (parsed != null) return parsed;
          }
        }
        for (final child in value.values) {
          final parsed = find(child);
          if (parsed != null) return parsed;
        }
      } else if (value is List) {
        for (final child in value) {
          final parsed = find(child);
          if (parsed != null) return parsed;
        }
      }
      return null;
    }

    return find(node);
  }

  static Map<String, dynamic> _mergeSasDataPreservingActivation(
    Subscriber existing,
    Map<String, dynamic> remoteData,
  ) {
    final merged = Map<String, dynamic>.from(remoteData);
    final localActivationDate = existing.sasData['local_activation_date'];
    if (localActivationDate != null &&
        localActivationDate.toString().trim().isNotEmpty) {
      merged['local_activation_date'] = localActivationDate;
      merged['activation_date'] = localActivationDate;
    }
    return merged;
  }

  static DateTime resolveStartDateForSync({
    required Subscriber existing,
    required DateTime remoteStartDate,
  }) {
    final markerValue =
        existing.sasData['local_activation_date'] ??
        existing.sasData['activation_date'];
    if (markerValue is String && markerValue.trim().isNotEmpty) {
      final parsed = DateTime.tryParse(markerValue.trim());
      if (parsed != null) {
        return DateTime(parsed.year, parsed.month, parsed.day);
      }
    }
    return DateTime(
      remoteStartDate.year,
      remoteStartDate.month,
      remoteStartDate.day,
    );
  }

  static Future<SasSyncResult> sync(SasApiService api) async {
    await TrialGuardService.ensureSasAllowed(
      api.settings.serverUrl,
      api.settings.username,
    );
    final response = await api.fetchUsers();
    final rows = api.extractUsers(response);
    final profileNameCache = <int, String?>{};

    // fetchConnectedSessions اختياري - لا يوقف المزامنة إذا فشل
    // (بعض أنظمة SAS مثل JT لا يدعمون endpoint /index/online)
    List<Map<String, dynamic>> sessions = [];
    try {
      sessions = await api.fetchConnectedSessions().timeout(
        const Duration(seconds: 15),
      );
    } catch (e) {
      debugPrint('fetchConnectedSessions failed (non-fatal): $e');
    }

    final connected = _SessionIndex(sessions);

    var added = 0;
    var updated = 0;

    for (final row in rows) {
      final profileName = await _resolveProfileNameForRow(
        row,
        api,
        profileNameCache,
      );
      if (profileName != null &&
          (row['profile_name'] == null ||
              row['profile_name'].toString().trim().isEmpty)) {
        row['profile_name'] = profileName;
      }
      final mapped = _map(row);
      if (mapped.user.trim().isEmpty) continue;

      final sessionIp = connected.ipOf(mapped);
      if (sessionIp != null) {
        mapped.sasOnline = true;
        if (sessionIp.isNotEmpty) mapped.ip = sessionIp;
      }

      final sasId = mapped.sasId;
      var index = -1;
      if (sasId.isNotEmpty) {
        index = AppStore.subscribers.indexWhere(
          (s) => s.source == 'sas' && s.sasId == sasId,
        );
      }
      if (index < 0) {
        index = AppStore.subscribers.indexWhere(
          (s) =>
              s.user.trim().toLowerCase() == mapped.user.trim().toLowerCase(),
        );
      }

      if (index < 0) {
        AppStore.subscribers.add(mapped);
        added++;
      } else {
        final old = AppStore.subscribers[index];

        final nextUser = mapped.user.isNotEmpty ? mapped.user : old.user;
        final nextName = mapped.name.isNotEmpty ? mapped.name : old.name;
        final nextPhone = mapped.phone.isNotEmpty ? mapped.phone : old.phone;
        final nextAddress = mapped.address.isNotEmpty
            ? mapped.address
            : old.address;
        final nextIp = mapped.ip.isNotEmpty ? mapped.ip : old.ip;
        final nextType = mapped.type.isNotEmpty ? mapped.type : old.type;
        final nextSasId = mapped.sasId.isNotEmpty ? mapped.sasId : old.sasId;
        final resolvedStartDate = resolveStartDateForSync(
          existing: old,
          remoteStartDate: mapped.startDate,
        );

        final changed =
            old.user != nextUser ||
            old.name != nextName ||
            old.phone != nextPhone ||
            old.address != nextAddress ||
            old.ip != nextIp ||
            old.type != nextType ||
            old.startDate != resolvedStartDate ||
            old.endDate != mapped.endDate ||
            old.active != mapped.active ||
            old.disabled != mapped.disabled ||
            old.source != 'sas' ||
            old.sasId != nextSasId;

        if (changed) {
          old
            ..user = nextUser
            ..name = nextName
            ..phone = nextPhone
            ..address = nextAddress
            ..ip = nextIp
            ..type = nextType
            ..startDate = resolvedStartDate
            ..endDate = mapped.endDate
            ..active = mapped.active
            ..disabled = mapped.disabled
            ..source = 'sas'
            ..sasId = nextSasId
            ..sasData = _mergeSasDataPreservingActivation(old, mapped.sasData)
            ..sasOnline = mapped.sasOnline
            ..liveOnline = null;
          updated++;
        } else {
          old
            ..sasData = _mergeSasDataPreservingActivation(old, mapped.sasData)
            ..sasOnline = mapped.sasOnline
            ..liveOnline = null;
        }
      }
    }

    // profile_name يُملأ أعلاه من تفاصيل الباقة إذا خلا منه صف المشترك.
    final rowPackages = [
      for (final row in rows)
        if (row['profile_name'] is String) row['profile_name'] as String,
    ];
    await syncPackages(api, extraNames: rowPackages, save: false);

    await AppStore.save();
    return SasSyncResult(read: rows.length, added: added, updated: updated);
  }

  /// يقرأ باقات (Profiles) الساس ويضيف الجديدة منها لقائمة الباقات بسعر يدوي.
  /// فشل القراءة لا يوقف المزامنة؛ تُستخدم عندها باقات المشتركين فقط.
  static Future<int> syncPackages(
    SasApiService api, {
    Iterable<String> extraNames = const [],
    bool save = true,
  }) async {
    final names = <String>[...extraNames];
    var profilesRead = false;
    try {
      var managerId = 5;
      try {
        final parents = await api.fetchParents().timeout(
          const Duration(seconds: 10),
        );
        for (final parent in parents) {
          final id = int.tryParse('${parent['id'] ?? ''}');
          if (id != null) {
            managerId = id;
            break;
          }
        }
      } catch (e) {
        debugPrint('fetchParents for packages failed (non-fatal): $e');
      }
      final profiles = await api
          .fetchProfiles(managerId: managerId)
          .timeout(const Duration(seconds: 15));
      for (final profile in profiles) {
        final name = (profile['name'] ?? profile['profile_name'] ?? '')
            .toString()
            .trim();
        if (name.isNotEmpty) names.add(name);
      }
      profilesRead = profiles.isNotEmpty;
    } catch (e) {
      debugPrint('fetchProfiles for packages failed (non-fatal): $e');
    }
    final added = AppStore.mergeSasPackages(names, complete: profilesRead);
    if (save) await AppStore.save();
    return added;
  }

  /// يحدّث المشترك من رد SAS لمشترك واحد، مغلفاً بـ data أو مباشراً، دون مزامنة
  /// القائمة كاملة. لا يغيّر تاريخ الانتهاء إذا خلا الرد منه.
  static void applyUserSnapshot(Subscriber subscriber, dynamic response) {
    dynamic node = response;
    for (var depth = 0; depth < 3 && node is Map; depth++) {
      if (node['data'] is! Map) break;
      node = node['data'];
    }
    if (node is! Map) return;
    final row = Map<String, dynamic>.from(node);
    final mapped = _map(row);
    if (mapped.ip.isNotEmpty) subscriber.ip = mapped.ip;
    if (_endDateKeys.any((key) => row[key] != null)) {
      subscriber.endDate = mapped.endDate;
    }
    subscriber
      ..active = mapped.active
      ..disabled = mapped.disabled
      ..sasOnline = mapped.sasOnline
      ..liveOnline = null
      ..sasData = {
        ...subscriber.sasData,
        ..._mergeSasDataPreservingActivation(subscriber, row),
      };
  }

  /// يقرأ الجلسات المتصلة فقط لإظهار IP المشترك بعد اتصاله.
  static Future<void> refreshConnection(
    SasApiService api,
    Subscriber subscriber,
  ) async {
    final connected = _SessionIndex(await api.fetchConnectedSessions());
    final ip = connected.ipOf(subscriber);
    if (ip == null) return;
    subscriber
      ..sasOnline = true
      ..liveOnline = true;
    if (ip.isNotEmpty) subscriber.ip = ip;
  }

  /// تحديث سريع للمتصلين وIP دون جلب المشتركين. يعيد عدد المتصلين، و null إذا
  /// لم ترجع SAS أي جلسة، فلا يُعد الجميع غير متصلين بسبب رد فارغ.
  static Future<int?> refreshConnections(SasApiService api) async {
    final sessions = await api.fetchConnectedSessions();
    if (sessions.isEmpty) return null;
    final connected = _SessionIndex(sessions);
    var online = 0;
    for (final subscriber in AppStore.subscribers) {
      if (subscriber.source == 'ftth') continue;
      final ip = connected.ipOf(subscriber);
      subscriber
        ..sasOnline = ip != null
        ..liveOnline = ip != null;
      if (ip == null) continue;
      online++;
      if (ip.isNotEmpty) subscriber.ip = ip;
    }
    return online;
  }

  static String _extractIp(dynamic node) {
    if (node is Map) {
      for (final key in [
        'last_session',
        'lastSession',
        'session',
        'online',
        'active_session',
        'radacct',
        'acct',
      ]) {
        if (node.containsKey(key) && node[key] != null) {
          final nested = _extractIp(node[key]);
          if (nested.isNotEmpty) return nested;
        }
      }
      for (final key in [
        'framedipaddress',
        'framed_ip_address',
        'framed_ip',
        'framedIpAddress',
        'client_ip',
        'remote_ip',
        'calling_station_id',
        'calling_station',
        'called_station_id',
        'ip',
        'ip_address',
        'address',
        // عنوان خادم الاتصال لا المشترك، فلا يُقبل إلا عند غياب غيره.
        'nas_ip',
        'nasip',
      ]) {
        final value = node[key];
        if (value != null) {
          final textValue = value.toString().trim();
          final normalized = _normalizeIp(textValue);
          if (normalized != null) return normalized;
        }
      }
      for (final value in node.values) {
        final nested = _extractIp(value);
        if (nested.isNotEmpty) return nested;
      }
    } else if (node is List) {
      for (final item in node) {
        final nested = _extractIp(item);
        if (nested.isNotEmpty) return nested;
      }
    }
    return '';
  }

  static String? _normalizeIp(String text) {
    final value = text.split(RegExp(r'[:/\\\s]')).first.trim();
    if (value.isEmpty) return null;

    if (_isValidIpv4(value) || _isValidIpv6(value)) {
      return value;
    }

    final match = RegExp(r'(?:\d{1,3}\.){3}\d{1,3}').firstMatch(text);
    if (match != null) {
      final candidate = match.group(0)!;
      if (_isValidIpv4(candidate)) return candidate;
    }

    return null;
  }

  static bool _isValidIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
    for (final part in parts) {
      final number = int.tryParse(part);
      if (number == null || number < 0 || number > 255) return false;
    }
    return true;
  }

  static bool _isValidIpv6(String value) {
    return RegExp(
          r'^([0-9a-fA-F]{1,4}:){1,7}[0-9a-fA-F]{1,4}',
        ).hasMatch(value) ||
        RegExp(r'^::[0-9a-fA-F]{1,4}').hasMatch(value) ||
        RegExp(r'^[0-9a-fA-F]{1,4}::[0-9a-fA-F]{1,4}').hasMatch(value);
  }

  static String _extractSessionText(dynamic node, List<String> keys) {
    if (node is Map) {
      for (final key in keys) {
        final value = node[key];
        if (value != null && value.toString().trim().isNotEmpty) {
          return value.toString().trim();
        }
      }
      for (final child in node.values) {
        final nested = _extractSessionText(child, keys);
        if (nested.isNotEmpty) return nested;
      }
    } else if (node is List) {
      for (final item in node) {
        final nested = _extractSessionText(item, keys);
        if (nested.isNotEmpty) return nested;
      }
    }
    return '';
  }

  static Future<String?> _resolveProfileNameForRow(
    Map<String, dynamic> row,
    SasApiService api,
    Map<int, String?> cache,
  ) async {
    if (_extractProfileName(row)?.isNotEmpty == true) {
      return _extractProfileName(row);
    }
    final profileId = _extractProfileId(row);
    if (profileId == null) return null;
    if (cache.containsKey(profileId)) return cache[profileId];
    try {
      final profile = await api.fetchProfileDetails(profileId);
      final profileName = _extractProfileName(profile);
      cache[profileId] = profileName;
      return profileName;
    } catch (_) {
      cache[profileId] = null;
      return null;
    }
  }

  static int? _extractProfileId(Map<String, dynamic> row) {
    final value = row['profile_id'] ?? row['profileId'];
    if (value == null) return null;
    final text = value.toString().trim();
    return int.tryParse(text);
  }

  static String? _extractProfileName(dynamic node) {
    if (node is Map) {
      for (final key in const [
        'profile_name',
        'profile',
        'package_name',
        'package',
        'plan_name',
        'service_name',
        'name',
        'title',
      ]) {
        final value = node[key];
        if (value is String || value is num || value is bool) {
          final text = value.toString().trim();
          if (text.isNotEmpty) return text;
        } else if (value is Map || value is List) {
          final nested = _extractProfileName(value);
          if (nested != null && nested.isNotEmpty) return nested;
        }
      }
      for (final value in node.values) {
        final nested = _extractProfileName(value);
        if (nested != null && nested.isNotEmpty) return nested;
      }
    } else if (node is List) {
      for (final item in node) {
        final nested = _extractProfileName(item);
        if (nested != null && nested.isNotEmpty) return nested;
      }
    }
    return null;
  }

  static Subscriber _map(Map<String, dynamic> row) {
    dynamic pick(List<String> keys) {
      dynamic walk(dynamic node) {
        if (node is Map) {
          for (final key in keys) {
            final value = node[key];
            if (value is String || value is num || value is bool) {
              final textValue = value.toString().trim();
              if (textValue.isNotEmpty) return value;
            } else if (value is Map || value is List) {
              final nested = walk(value);
              if (nested != null) return nested;
            }
          }
          for (final value in node.values) {
            final nested = walk(value);
            if (nested != null) return nested;
          }
        } else if (node is List) {
          for (final item in node) {
            final nested = walk(item);
            if (nested != null) return nested;
          }
        }
        return null;
      }

      return walk(row);
    }

    String text(List<String> keys, [String fallback = '']) =>
        (pick(keys) ?? fallback).toString().trim();
    DateTime date(List<String> keys, DateTime fallback) {
      final v = pick(keys);
      if (v == null) return fallback;
      if (v is num) {
        final n = v.toInt();
        return DateTime.fromMillisecondsSinceEpoch(
          n > 9999999999 ? n : n * 1000,
        );
      }
      return DateTime.tryParse(v.toString()) ?? fallback;
    }

    bool truthy(List<String> keys, bool fallback) {
      final v = pick(keys);
      if (v == null) return fallback;
      if (v is bool) return v;
      if (v is num) return v != 0;
      final x = v.toString().toLowerCase().trim();
      if (['1', 'true', 'active', 'enabled', 'yes', 'on'].contains(x)) {
        return true;
      }
      if ([
        '0',
        'false',
        'inactive',
        'disabled',
        'no',
        'off',
        'expired',
      ].contains(x)) {
        return false;
      }
      return fallback;
    }

    final now = DateTime.now();
    final end = date(_endDateKeys, now);

    final explicitDisabled = truthy([
      'disabled',
      'is_disabled',
      'blocked',
      'is_blocked',
      'disable',
      'isDisable',
      'isDisabled',
    ], false);
    final statusText = text([
      'status',
      'state',
      'user_status',
      'account_status',
    ]).toLowerCase();
    final statusDisabled = [
      'disabled',
      'disable',
      'blocked',
      'block',
      'inactive',
      'suspended',
      'stopped',
      'معطل',
      'موقوف',
    ].contains(statusText);

    final hasActiveFlag = [
      'active',
      'is_active',
      'enabled',
      'is_enabled',
      'enable',
    ].any((k) => row.containsKey(k) && row[k] != null);
    final sasActiveFlag = truthy([
      'active',
      'is_active',
      'enabled',
      'is_enabled',
      'enable',
    ], !end.isBefore(now));

    final disabled =
        explicitDisabled || statusDisabled || (hasActiveFlag && !sasActiveFlag);
    final active = !disabled && sasActiveFlag;

    final packageValue = text([
      'profile_name',
      'profile',
      'package_name',
      'package',
      'plan_name',
      'service_name',
    ]);
    final firstName = (row['firstname'] ?? '').toString().trim();
    final lastName = (row['lastname'] ?? '').toString().trim();

    return Subscriber(
      user: text(['username', 'user', 'user_name', 'login', 'name']),
      name: firstName.isNotEmpty
          ? [
              firstName,
              if (lastName.isNotEmpty && lastName != '-') lastName,
            ].join(' ')
          : text([
              'full_name',
              'fullname',
              'customer_name',
              'display_name',
              'name',
              'username',
            ]),
      phone: text(['phone', 'mobile', 'phone_number', 'mobile_number']),
      address: text(['address', 'location', 'city']),
      ip: _extractIp(row),
      type: packageValue,
      price: 0,
      startDate: date([
        'activation_date',
        'activated_at',
        'start_date',
        'from_date',
        'created_at',
        'creation_date',
        'registered_at',
      ], now),
      endDate: end,
      active: active,
      disabled: disabled,
      source: 'sas',
      sasId: text(['id', 'user_id', 'uid', 'uuid', 'username', 'user']),
      sasOnline: Subscriber.detectOnline(row),
      sasData: Map<String, dynamic>.from(row),
    );
  }
}
