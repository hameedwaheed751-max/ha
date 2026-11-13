import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/services/onboarding_gate.dart';

void main() {
  bool needed({
    bool isAdmin = false,
    bool onFreeTrial = true,
    bool alreadyFlagged = false,
    bool hasRadius = false,
    bool radiusSynced = false,
    bool ftthConfigured = false,
    bool ftthHasSubscribers = false,
  }) => OnboardingGate.trialOnboardingNeeded(
    isAdmin: isAdmin,
    onFreeTrial: onFreeTrial,
    alreadyFlagged: alreadyFlagged,
    hasRadius: hasRadius,
    radiusSynced: radiusSynced,
    ftthConfigured: ftthConfigured,
    ftthHasSubscribers: ftthHasSubscribers,
  );

  group('trialOnboardingNeeded', () {
    test('admins are never gated', () {
      expect(needed(isAdmin: true), isFalse);
    });

    test('paid plans are never gated (handled by the reminder)', () {
      expect(needed(onFreeTrial: false), isFalse);
    });

    test('an already-onboarded trial agent is not gated again', () {
      expect(needed(alreadyFlagged: true), isFalse);
    });

    test('a fresh trial agent with nothing linked is gated', () {
      expect(needed(), isTrue);
    });

    test('radius linked but never synced is still gated', () {
      expect(needed(hasRadius: true, radiusSynced: false), isTrue);
    });

    test('radius linked and synced passes', () {
      expect(needed(hasRadius: true, radiusSynced: true), isFalse);
    });

    test('ftth configured but no subscribers yet is gated', () {
      expect(needed(ftthConfigured: true, ftthHasSubscribers: false), isTrue);
    });

    test('ftth configured with subscribers passes', () {
      expect(needed(ftthConfigured: true, ftthHasSubscribers: true), isFalse);
    });

    test('either linked-and-synced side satisfies the gate', () {
      // radius linked but unsynced, yet ftth is synced → passes.
      expect(
        needed(
          hasRadius: true,
          radiusSynced: false,
          ftthConfigured: true,
          ftthHasSubscribers: true,
        ),
        isFalse,
      );
    });
  });
}
