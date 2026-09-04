import 'package:flutter/foundation.dart';
import 'models.dart';
import 'sas_api_service.dart';

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

class SasSyncService {
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
      if (parsed != null)
        return DateTime(parsed.year, parsed.month, parsed.day);
    }
    return DateTime(
      remoteStartDate.year,
      remoteStartDate.month,
      remoteStartDate.day,
    );
  }

  static Future<SasSyncResult> sync(SasApiService api) async {
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

    final sessionIpByUser = <String, String>{};
    final sessionIpBySasId = <String, String>{};
    for (final session in sessions) {
      final username = _extractSessionText(session, [
        'username',
        'user',
        'user_name',
        'login',
        'name',
      ]);
      final sasId = _extractSessionText(session, [
        'user_id',
        'id',
        'uid',
        'uuid',
      ]);
      final ip = _extractIp(session);
      debugPrint('session sasId=$sasId username=$username ip=$ip');
      if (ip.isEmpty) continue;
      if (username.isNotEmpty) sessionIpByUser[username.toLowerCase()] = ip;
      if (sasId.isNotEmpty) sessionIpBySasId[sasId.toLowerCase()] = ip;
    }

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
      debugPrint(
        'SAS sync raw profile_name=${row['profile_name'] ?? ''}, profile_id=${row['profile_id'] ?? ''}',
      );
      final mapped = _map(row);
      if (mapped.user.trim().isEmpty) continue;
      debugPrint(
        'SAS sync mapped profile_name=${mapped.sasData['profile_name'] ?? ''}, type=${mapped.type}',
      );

      final userKey = mapped.user.trim().toLowerCase();
      debugPrint('CHECK user=${mapped.user} ip=${mapped.ip}');
      final sasIdKey = mapped.sasId.trim().toLowerCase();
      debugPrint('mapped.user=${mapped.user}  mapped.sasId=${mapped.sasId}');
      debugPrint('session username keys=${sessionIpByUser.keys}');
      if (sasIdKey.isNotEmpty && sessionIpBySasId.containsKey(sasIdKey)) {
        mapped.ip = sessionIpBySasId[sasIdKey]!;
      } else if (userKey.isNotEmpty && sessionIpByUser.containsKey(userKey)) {
        mapped.ip = sessionIpByUser[userKey]!;
      }
      debugPrint('AFTER MATCH user=${mapped.user} ip=${mapped.ip}');

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

        final changed =
            old.user != nextUser ||
            old.name != nextName ||
            old.phone != nextPhone ||
            old.address != nextAddress ||
            old.ip != nextIp ||
            old.type != nextType ||
            old.startDate != mapped.startDate ||
            old.endDate != mapped.endDate ||
            old.active != mapped.active ||
            old.disabled != mapped.disabled ||
            old.source != 'sas' ||
            old.sasId != nextSasId;

        if (changed) {
          final resolvedStartDate = resolveStartDateForSync(
            existing: old,
            remoteStartDate: mapped.startDate,
          );

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
            ..sasOnline = mapped.sasOnline;
          updated++;
        } else {
          old
            ..sasData = _mergeSasDataPreservingActivation(old, mapped.sasData)
            ..sasOnline = mapped.sasOnline;
        }
      }
    }

    await AppStore.save();
    return SasSyncResult(read: rows.length, added: added, updated: updated);
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
        'nas_ip',
        'nasip',
        'client_ip',
        'remote_ip',
        'calling_station_id',
        'calling_station',
        'called_station_id',
        'ip',
        'ip_address',
        'address',
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
      if (['1', 'true', 'active', 'enabled', 'yes', 'on'].contains(x))
        return true;
      if ([
        '0',
        'false',
        'inactive',
        'disabled',
        'no',
        'off',
        'expired',
      ].contains(x))
        return false;
      return fallback;
    }

    final now = DateTime.now();
    final end = date([
      'expiration',
      'expiration_date',
      'expire_date',
      'end_date',
      'endDate',
      'expires_at',
      'expiry_date',
    ], now);

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
    debugPrint(
      'SAS _map profile_name=${row['profile_name'] ?? ''}, packageValue=$packageValue',
    );

    return Subscriber(
      user: text(['username', 'user', 'user_name', 'login', 'name']),
      name: text([
        'firstname',
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
