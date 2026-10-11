import 'package:firebase_auth/firebase_auth.dart';

class UserRoleService {
  static const String adminRole = 'admin';
  static const String agentRole = 'agent';
  static const String trustedAdminUid = 'wE10WciDVudIOJziBurjhBxpDfO2';

  static Future<String> resolveRole({String? uid}) {
    final resolvedUid = (uid ?? FirebaseAuth.instance.currentUser?.uid ?? '')
        .trim();
    return Future<String>.value(
      resolvedUid == trustedAdminUid ? adminRole : agentRole,
    );
  }

  static Future<bool> isAgent({String? uid}) async {
    return (await resolveRole(uid: uid)) == agentRole;
  }
}
