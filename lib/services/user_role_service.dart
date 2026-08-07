import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class UserRoleService {
  static const String adminRole = 'admin';
  static const String agentRole = 'agent';

  static Future<String> resolveRole({String? uid}) async {
    final resolvedUid = (uid ?? FirebaseAuth.instance.currentUser?.uid ?? '').trim();
    if (resolvedUid.isEmpty) return adminRole;

    try {
      final snapshot = await FirebaseDatabase.instance.ref('agents/$resolvedUid/profile/role').get();
      final raw = snapshot.value?.toString().trim().toLowerCase() ?? '';
      if (raw == agentRole) return agentRole;
      return adminRole;
    } catch (_) {
      return adminRole;
    }
  }

  static Future<bool> isAgent({String? uid}) async {
    return (await resolveRole(uid: uid)) == agentRole;
  }
}
