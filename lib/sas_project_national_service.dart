import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class SasProjectNationalSettings {
  const SasProjectNationalSettings({
    required this.username,
    required this.password,
    this.baseUrl = 'https://admin.ftth.iq',
    this.clientApp = '53d57a7f-3f89-4e9d-873b-3d071bc6dd9f',
    this.userRole = '0',
  });

  final String username;
  final String password;
  final String baseUrl;
  final String clientApp;
  final String userRole;

  static const _baseUrlKey = 'ftth_sas_base_url';
  static const _usernameKey = 'ftth_sas_username';
  static const _passwordKey = 'ftth_sas_password';
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  static Future<SasProjectNationalSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    String password = '';
    try {
      password = await _secureStorage.read(key: _passwordKey) ?? '';
    } catch (_) {
      password = prefs.getString(_passwordKey) ?? '';
    }
    return SasProjectNationalSettings(
      baseUrl: prefs.getString(_baseUrlKey) ?? 'https://admin.ftth.iq',
      username: prefs.getString(_usernameKey) ?? '',
      password: password,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, baseUrl.trim());
    await prefs.setString(_usernameKey, username.trim());
    try {
      await _secureStorage.write(key: _passwordKey, value: password);
      await prefs.remove(_passwordKey);
    } catch (_) {
      await prefs.setString(_passwordKey, password);
    }
  }
}

class SasProjectNationalData {
  const SasProjectNationalData({
    required this.customers,
    required this.subscriptions,
    required this.sessions,
  });

  final List<Map<String, dynamic>> customers;
  final List<Map<String, dynamic>> subscriptions;
  final List<Map<String, dynamic>> sessions;
}

class SasProjectNationalSyncResult {
  const SasProjectNationalSyncResult({
    required this.read,
    required this.added,
    required this.updated,
  });

  final int read;
  final int added;
  final int updated;
}

class SasProjectNationalService {
  SasProjectNationalService(this.settings, {http.Client? client})
      : _client = client ?? http.Client(),
        _baseUrl = _normalizeBaseUrl(settings.baseUrl);

  final SasProjectNationalSettings settings;
  final http.Client _client;
  final String _baseUrl;
  String? _accessToken;
  String? _refreshToken;

  void _log(String message) {
    debugPrint('[FTTH SAS] $message');
  }

  bool get isAuthenticated => _accessToken?.isNotEmpty == true;
  String? get accessToken => _accessToken;
  String? get refreshToken => _refreshToken;

  static String _normalizeBaseUrl(String value) {
    final normalized = value.trim().replaceFirst(RegExp(r'/+$'), '');
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, 'baseUrl', 'Base URL cannot be empty');
    }
    final uri = Uri.parse(normalized);
    if (uri.scheme != 'https' || uri.host.isEmpty) {
      throw ArgumentError.value(
        value,
        'baseUrl',
        'Base URL must be an HTTPS URL',
      );
    }
    return normalized;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$_baseUrl$cleanPath').replace(queryParameters: query);
  }

  Map<String, String> _headers({bool authenticated = true}) {
    return {
      'Accept': 'application/json, text/plain, */*',
      'X-Client-App': settings.clientApp,
      'X-User-Role': settings.userRole,
      if (authenticated && isAuthenticated)
        'Authorization': 'Bearer $_accessToken',
    };
  }

  Future<void> login() async {
    _log('login start: POST /api/auth/Contractor/token');
    final response = await _client
        .post(
          _uri('/api/auth/Contractor/token'),
          headers: {
            'Accept': 'application/json, text/plain, */*',
            'Content-Type': 'application/x-www-form-urlencoded',
            'X-Client-App': settings.clientApp,
            'X-User-Role': settings.userRole,
          },
          body: {
            'grant_type': 'password',
            'scope': 'openid profile',
            'client_id': '',
            'username': settings.username.trim(),
            'password': settings.password,
          },
        )
        .timeout(const Duration(seconds: 45));

      _log('login response: HTTP ${response.statusCode}');
    final data = _decodeObject(response, 'FTTH login');
    final accessToken = (data['access_token'] ?? data['token'] ?? '')
        .toString()
        .trim();
    if (accessToken.isEmpty) {
      throw SasProjectNationalException(
        'FTTH login response did not contain an access token',
        statusCode: response.statusCode,
      );
    }
    _accessToken = accessToken;
    _refreshToken = data['refresh_token']?.toString();
    _log('login success: access token received');
  }

  Future<SasProjectNationalData> fetchSubscriberData({
    int pageSize = 100,
  }) async {
    _log('sync start');
    final customers = await fetchCustomers(pageSize: pageSize);
    _log('customers loaded: ${customers.length}');
    final subscriptions = await fetchSubscriptions(pageSize: pageSize);
    _log('subscriptions loaded: ${subscriptions.length}');
    final sessions = await fetchSessions(pageSize: pageSize);
    _log('sessions loaded: ${sessions.length}');
    return SasProjectNationalData(
      customers: customers,
      subscriptions: subscriptions,
      sessions: sessions,
    );
  }

  Future<SasProjectNationalSyncResult> syncSubscribers({
    SasProjectNationalData? data,
  }) async {
    final snapshot = data ?? await fetchSubscriberData();
    final customersById = <String, Map<String, dynamic>>{};
    for (final customer in snapshot.customers) {
      final self = customer['self'];
      if (self is Map && self['id'] != null) {
        customersById[self['id'].toString()] = customer;
      }
    }

    var added = 0;
    var updated = 0;
    for (final subscription in snapshot.subscriptions) {
      final customerRef = subscription['customer'];
      final customerId = customerRef is Map
          ? (customerRef['id'] ?? '').toString()
          : '';
      final customer = customersById[customerId] ?? const <String, dynamic>{};
      final primaryContact = customer['primaryContact'];
      final self = customer['self'];
      final customerName = customerRef is Map
          ? (customerRef['displayValue'] ?? '').toString()
          : '';
      final name = customerName.isNotEmpty
          ? customerName
          : self is Map
          ? (self['displayValue'] ?? '').toString()
          : '';
      final username = (subscription['username'] ?? '').toString().trim();
      final subscriptionId = (subscription['self'] is Map
              ? subscription['self']['id']
              : subscription['id'])
          ?.toString()
          .trim();
      final startDate = _parseDate(subscription['startedAt']) ?? DateTime.now();
      final endDate = _parseDate(subscription['expires']) ?? startDate;
      final bundle = subscription['bundle'];
      final type = bundle is Map
          ? (bundle['displayValue'] ?? bundle['id'] ?? '').toString()
          : '';
      final activeSession = subscription['activeSession'];
      final ip = activeSession is Map
          ? (activeSession['ipAddress'] ?? '').toString()
          : (subscription['ipAddress'] ?? '').toString();
      final online = subscription['hasActiveSession'] == true;
      final phone = primaryContact is Map
          ? (primaryContact['mobile'] ??
                    primaryContact['phone'] ??
                    primaryContact['secondaryPhone'] ??
                    '')
                .toString()
          : '';
      final user = username.isNotEmpty
          ? username
          : (customerId.isNotEmpty ? customerId : name);
      if (user.trim().isEmpty) continue;

      final sasData = <String, dynamic>{
        'provider': 'ساس المشروع الوطني',
        'customer_id': customerId,
        'subscription_id': subscriptionId ?? '',
        'status': subscription['status'],
        'bundle': bundle,
        'startedAt': subscription['startedAt'],
        'expires': subscription['expires'],
        'activeSession': activeSession,
        'rawCustomer': customer,
        'rawSubscription': subscription,
      };
      final next = Subscriber(
        user: user,
        name: name,
        phone: phone,
        address: '',
        ip: ip,
        type: type,
        price: 0,
        startDate: startDate,
        endDate: endDate,
        active: subscription['status']?.toString().toLowerCase() == 'active',
        source: 'ftth',
        sasId: subscriptionId ?? customerId,
        sasOnline: online,
        sasData: sasData,
      );

      final index = AppStore.subscribers.indexWhere(
        (item) =>
            item.source == 'ftth' &&
            item.sasId.isNotEmpty &&
            item.sasId == next.sasId,
      );
      if (index < 0) {
        AppStore.subscribers.add(next);
        added++;
      } else {
        final existing = AppStore.subscribers[index];
        existing
          ..user = next.user
          ..name = next.name
          ..phone = next.phone
          ..ip = next.ip
          ..type = next.type
          ..startDate = next.startDate
          ..endDate = next.endDate
          ..active = next.active
          ..disabled = next.disabled
          ..sasOnline = next.sasOnline
          ..sasData = next.sasData;
        updated++;
      }
    }
    await AppStore.save();
    _log('app sync complete: added=$added updated=$updated');
    return SasProjectNationalSyncResult(
      read: snapshot.subscriptions.length,
      added: added,
      updated: updated,
    );
  }

  static DateTime? _parseDate(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : DateTime.tryParse(text);
  }

  Future<List<Map<String, dynamic>>> fetchCustomers({
    int pageSize = 100,
  }) {
    return _fetchPage('/api/customers', pageSize: pageSize);
  }

  Future<List<Map<String, dynamic>>> fetchSubscriptions({
    int pageSize = 100,
  }) async {
    final all = <String, Map<String, dynamic>>{};
    for (final status in ['Active', 'Expired']) {
      final rows = await _fetchPage(
        '/api/subscriptions',
        pageSize: pageSize,
        status: status,
      );
      for (final row in rows) {
        final self = row['self'];
        final id = self is Map ? self['id']?.toString() : row['id']?.toString();
        all[id ?? '${all.length}'] = row;
      }
    }
    return all.values.toList();
  }

  Future<List<Map<String, dynamic>>> fetchSessions({
    int pageSize = 100,
  }) {
    return _fetchPage('/api/sessions', pageSize: pageSize);
  }

  Future<List<Map<String, dynamic>>> _fetchPage(
    String path, {
    required int pageSize,
    String? status,
  }) async {
    if (pageSize <= 0) {
      throw ArgumentError.value(pageSize, 'pageSize', 'Must be positive');
    }
    final data = await _getJson(
      path,
      query: {
        'pageSize': '$pageSize',
        'pageNumber': '1',
        if (path == '/api/customers') ...{
          'sortCriteria.property': 'self.displayValue',
          'sortCriteria.direction': 'asc',
        },
        if (path == '/api/subscriptions') ...{
          'sortCriteria.property': 'expires',
          'sortCriteria.direction': 'asc',
          ...?status == null ? null : {'status': status},
          'hierarchyLevel': '0',
        },
        if (path == '/api/sessions') ...{
          'sortCriteria.property': 'username',
          'sortCriteria.direction': 'asc',
          'status': '1',
          'hierarchyLevel': '0',
        },
      },
    );
    return _extractRows(data);
  }

  Future<dynamic> _getJson(
    String path, {
    Map<String, String>? query,
    bool retryAfterLogin = true,
  }) async {
    if (!isAuthenticated) await login();

    final response = await _client
        .get(_uri(path, query), headers: _headers())
        .timeout(const Duration(seconds: 45));
    _log('$path response: HTTP ${response.statusCode}');
    if (response.statusCode == 401 && retryAfterLogin) {
      _accessToken = null;
      await login();
      return _getJson(path, query: query, retryAfterLogin: false);
    }
    return _decode(response, 'GET $path');
  }

  static dynamic _decode(http.Response response, String operation) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SasProjectNationalException(
        '$operation failed with HTTP ${response.statusCode}',
        statusCode: response.statusCode,
        response: response.body.length > 300
            ? response.body.substring(0, 300)
            : response.body,
      );
    }

    dynamic data;
    try {
      data = jsonDecode(response.body);
    } catch (_) {
      throw SasProjectNationalException(
        '$operation returned invalid JSON',
        statusCode: response.statusCode,
      );
    }
    return data;
  }

  static Map<String, dynamic> _decodeObject(
    http.Response response,
    String operation,
  ) {
    final data = _decode(response, operation);
    if (data is! Map) {
      throw SasProjectNationalException(
        '$operation returned an unexpected response',
        statusCode: response.statusCode,
        response: data,
      );
    }
    return Map<String, dynamic>.from(data);
  }

  static List<Map<String, dynamic>> _extractRows(dynamic data) {
    dynamic rows = data;
    if (data is Map) {
      for (final key in ['items', 'content', 'results', 'data', 'customers', 'subscriptions', 'sessions']) {
        if (data[key] is List) {
          rows = data[key];
          break;
        }
      }
    }
    if (rows is! List) return const [];
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  void dispose() => _client.close();
}

class SasProjectNationalException implements Exception {
  const SasProjectNationalException(
    this.message, {
    this.statusCode,
    this.response,
  });

  final String message;
  final int? statusCode;
  final dynamic response;

  @override
  String toString() => message;
}
