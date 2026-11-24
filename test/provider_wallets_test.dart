import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/sas_api_service.dart';
import 'package:untitled/services/provider_wallets.dart';
import 'package:untitled/services/sas_wallets.dart';

SasSettings _account(String id) => SasSettings(
  serverUrl: 'https://$id.example.com',
  username: 'm',
  password: 'p',
  accountId: id,
  label: id.isEmpty ? 'الأساسي' : 'ساس $id',
  company: id.isEmpty ? 'الأفق' : '',
);

void main() {
  // محمّلات وهمية حتى لا يُستدعى أي مزوّد حقيقي.
  Future<ProviderWallets> load({
    SasWallets? radius,
    ProviderWallet? earthlink,
    ProviderWallet? fiberx,
    ProviderWallet? ftth,
  }) => ProviderWallets.load(
    radius: () async => radius ?? const SasWallets([]),
    earthlink: () async => earthlink,
    fiberx: () async => fiberx,
    ftth: () async => ftth,
  );

  test('يرتّب الساسات أولاً ثم إيرثلنك ففايبر اكس فـFTTH', () async {
    final radius = SasWallets([
      SasWallet(account: _account(''), balance: 250000, rewardPoints: 1200),
    ]);
    final wallets = await load(
      radius: radius,
      earthlink: const ProviderWallet(
        provider: WalletProvider.earthlink,
        company: 'إيرثلنك',
        balance: 1340000,
      ),
      fiberx: const ProviderWallet(
        provider: WalletProvider.fiberx,
        company: 'فايبر اكس',
        note: 'غير متاح',
      ),
      ftth: const ProviderWallet(
        provider: WalletProvider.ftth,
        company: 'FTTH',
        balance: 890000,
      ),
    );

    expect(wallets.items.map((w) => w.provider).toList(), [
      WalletProvider.radius,
      WalletProvider.earthlink,
      WalletProvider.fiberx,
      WalletProvider.ftth,
    ]);
    expect(wallets.several, isTrue);
  });

  test('يحوّل رصيد الساس (RADIUS) مع النقاط والعنوان', () async {
    final radius = SasWallets([
      SasWallet(account: _account(''), balance: 250000, rewardPoints: 1200),
    ]);
    final wallets = await load(radius: radius);
    final first = wallets.items.single;
    expect(first.provider, WalletProvider.radius);
    expect(first.company, contains('الأفق'));
    expect(first.balance, 250000);
    expect(first.rewardPoints, 1200);
    expect(first.hasBalance, isTrue);
  });

  test('يُسقِط المزوّد غير المربوط (null)', () async {
    final wallets = await load(
      earthlink: const ProviderWallet(
        provider: WalletProvider.earthlink,
        company: 'إيرثلنك',
        balance: 100,
      ),
      // فايبر اكس وFTTH غير مربوطين => null => لا يظهران.
    );
    expect(wallets.items.length, 1);
    expect(wallets.items.single.provider, WalletProvider.earthlink);
    expect(wallets.several, isFalse);
  });

  test('يحمل خطأ المزوّد دون رصيد', () async {
    final wallets = await load(
      earthlink: const ProviderWallet(
        provider: WalletProvider.earthlink,
        company: 'إيرثلنك',
        error: 'تعذّر تسجيل الدخول',
      ),
    );
    final el = wallets.items.single;
    expect(el.hasBalance, isFalse);
    expect(el.error, 'تعذّر تسجيل الدخول');
  });

  test('لا شيء مربوط => قائمة فارغة', () async {
    final wallets = await load();
    expect(wallets.isEmpty, isTrue);
    expect(wallets.several, isFalse);
  });
}
