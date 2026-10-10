import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../models.dart';
import 'subscriber_financial_ledger.dart'
  show FinancialTransaction, SubscriberFinancialLedger;

class BackupRestoreResult {
  const BackupRestoreResult({this.syncWarning});

  final String? syncWarning;
}

class BackupRestoreService {
  static const String formatName = 'netagent_backup';
  static const int formatVersion = 1;

  Future<Map<String, dynamic>> createBackup() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final financialLedger = uid.isEmpty
        ? <String, dynamic>{}
        : await SubscriberFinancialLedger().exportAllTransactions();

    return {
      'format': formatName,
      'version': formatVersion,
      'accountUid': uid,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'data': {
        'subscribers': AppStore.subscribers
          .map((subscriber) => _sanitizeMap(subscriber.toJson()))
            .toList(),
        'packages': AppStore.packages.map((package) => package.toJson()).toList(),
        'dailyTaskEvents': AppStore.dailyTaskEvents
            .map((event) => event.toJson())
            .toList(),
        'accountingActivations': AppStore.accountingActivations
            .map((record) => record.toJson())
            .toList(),
        'financialLedger': financialLedger,
        'settings': {
          'officeName': AppStore.officeName,
          'officePhone': AppStore.officePhone,
          'officeAddress': AppStore.officeAddress,
          'officeLogoBase64': AppStore.officeLogoBase64,
          'receiptFooter': AppStore.receiptFooter,
          'balance': AppStore.balance,
          'nextReceiptNumber': AppStore.nextReceiptNumber,
          'isDarkMode': AppStore.isDarkMode,
          'lastSasSync': AppStore.lastSasSync?.toIso8601String(),
          'messageTemplates': Map<String, String>.from(
            AppStore.messageTemplates,
          ),
        },
      },
    };
  }

  Future<BackupRestoreResult> restoreBackup(String contents) async {
    final decoded = jsonDecode(contents);
    if (decoded is! Map) {
      throw const FormatException('ملف النسخة الاحتياطية غير صالح.');
    }
    final backup = Map<String, dynamic>.from(decoded);
    if (backup['format'] != formatName || backup['version'] != formatVersion) {
      throw const FormatException('صيغة النسخة الاحتياطية غير مدعومة.');
    }

    final backupUid = (backup['accountUid'] ?? '').toString();
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (backupUid != currentUid) {
      throw StateError(
        'هذه النسخة تخص حساباً آخر. سجل الدخول إلى الحساب نفسه أولاً.',
      );
    }

    if (backup['data'] is! Map) {
      throw const FormatException('بيانات النسخة الاحتياطية غير مكتملة.');
    }
    final data = Map<String, dynamic>.from(backup['data'] as Map);
    final subscribers = _decodeList(
      data,
      'subscribers',
      (json) => Subscriber.fromJson(_sanitizeMap(json)),
    );
    final packages = _decodeList(data, 'packages', PackagePlan.fromJson);
    final events = _decodeList(data, 'dailyTaskEvents', DailyTaskEvent.fromJson);
    final accountingActivations = _decodeList(
      data,
      'accountingActivations',
      AccountingActivationRecord.fromJson,
    );
    final financialLedger = _decodeMap(data, 'financialLedger');
    _validateFinancialLedger(financialLedger);
    final settings = _decodeMap(data, 'settings');
    final templates = _decodeMap(settings, 'messageTemplates');

    final highestReceipt = subscribers
        .expand((subscriber) => subscriber.invoices)
        .fold<int>(0, (highest, invoice) =>
            invoice.receiptNumber > highest ? invoice.receiptNumber : highest);
    final requestedReceiptNumber = _readInt(
      settings['nextReceiptNumber'],
      fallback: 1,
    );

    AppStore.subscribers
      ..clear()
      ..addAll(subscribers);
    AppStore.packages
      ..clear()
      ..addAll(packages);
    AppStore.dailyTaskEvents
      ..clear()
      ..addAll(events);
    AppStore.accountingActivations
      ..clear()
      ..addAll(accountingActivations);

    AppStore.officeName = _readString(settings['officeName']);
    AppStore.officePhone = _readString(settings['officePhone']);
    AppStore.officeAddress = _readString(settings['officeAddress']);
    AppStore.officeLogoBase64 = _readString(settings['officeLogoBase64']);
    AppStore.receiptFooter = _readString(settings['receiptFooter']);
    AppStore.balance = _readDouble(settings['balance']);
    AppStore.nextReceiptNumber =
        requestedReceiptNumber > highestReceipt
        ? requestedReceiptNumber
        : highestReceipt + 1;
    AppStore.isDarkMode = settings['isDarkMode'] == true;
    AppStore.themeModeChange.value = AppStore.isDarkMode;
    AppStore.lastSasSync = DateTime.tryParse(
      _readString(settings['lastSasSync']),
    );
    AppStore.messageTemplates
      ..clear()
      ..addAll(templates.map((key, value) => MapEntry(key, value.toString())));

    await AppStore.save();
    String? syncWarning = AppStore.lastSaveSyncError;

    if (currentUid.isNotEmpty) {
      try {
        final agentRef = FirebaseDatabase.instance.ref('agents/$currentUid');
        final dailyEvents = AppStore.buildDailyTaskEventsPayload();
        final activationRecords = AppStore.buildAccountingActivationsPayload();
        await agentRef
            .child(AppStore.dailyTaskEventsKey)
            .set(dailyEvents.isEmpty ? null : dailyEvents)
            .timeout(const Duration(seconds: 30));
        await agentRef
            .child(AppStore.accountingActivationsKey)
            .set(activationRecords.isEmpty ? null : activationRecords)
            .timeout(const Duration(seconds: 30));
        await SubscriberFinancialLedger().replaceAllTransactions(
          financialLedger,
        );
      } catch (error) {
        syncWarning = 'تعذرت مزامنة بعض البيانات السحابية: $error';
      }
    }

    return BackupRestoreResult(syncWarning: syncWarning);
  }

  List<T> _decodeList<T>(
    Map<String, dynamic> data,
    String key,
    T Function(Map<String, dynamic>) decode,
  ) {
    final value = data[key];
    if (value is! List) {
      throw FormatException('قائمة $key مفقودة أو غير صالحة.');
    }
    return value.map((item) {
      if (item is! Map) throw FormatException('عنصر غير صالح في $key.');
      return decode(Map<String, dynamic>.from(item));
    }).toList();
  }

  Map<String, dynamic> _decodeMap(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value is! Map) {
      throw FormatException('بيانات $key مفقودة أو غير صالحة.');
    }
    return Map<String, dynamic>.from(value);
  }

  Map<String, dynamic> _sanitizeMap(Map<String, dynamic> value) => {
    for (final entry in value.entries)
      if (!_isSecretKey(entry.key)) entry.key: _sanitizeValue(entry.value),
  };

  dynamic _sanitizeValue(dynamic value) {
    if (value is Map) {
      return _sanitizeMap(Map<String, dynamic>.from(value));
    }
    if (value is List) {
      return value.map(_sanitizeValue).toList();
    }
    return value;
  }

  bool _isSecretKey(String key) {
    final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return normalized.contains('password') ||
        normalized.contains('passwd') ||
        normalized.contains('secret') ||
        normalized.contains('token') ||
        normalized.contains('credential') ||
        normalized.contains('authorization') ||
        normalized.contains('apikey') ||
        normalized.contains('accesskey');
  }

  void _validateFinancialLedger(Map<String, dynamic> ledger) {
    for (final subscriberEntry in ledger.entries) {
      if (subscriberEntry.value is! Map) {
        throw const FormatException('بيانات سجل مالي غير صالحة.');
      }
      final subscriberLedger =
          Map<String, dynamic>.from(subscriberEntry.value as Map);
      final rawTransactions = subscriberLedger['transactions'];
      if (rawTransactions == null) continue;
      if (rawTransactions is! Map) {
        throw const FormatException('قائمة معاملات مالية غير صالحة.');
      }
      for (final transactionEntry in rawTransactions.entries) {
        if (transactionEntry.value is! Map) {
          throw const FormatException('معاملة مالية غير صالحة.');
        }
        final transaction = Map<String, dynamic>.from(
          transactionEntry.value as Map,
        );
        transaction['id'] ??= transactionEntry.key;
        final parsed = FinancialTransaction.fromJson(transaction);
        if (parsed.subscriberId != subscriberEntry.key.toString()) {
          throw const FormatException(
            'معرّف المشترك في السجل المالي لا يطابق مساره.',
          );
        }
      }
    }
  }

  String _readString(dynamic value) => value?.toString() ?? '';

  double _readDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(_readString(value)) ?? 0;
  }

  int _readInt(dynamic value, {required int fallback}) {
    if (value is int) return value;
    return int.tryParse(_readString(value)) ?? fallback;
  }
}