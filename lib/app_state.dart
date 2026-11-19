import 'package:flutter/foundation.dart';

import 'api/qnap_client.dart';
import 'models/nas_profile.dart';
import 'services/profile_store.dart';

/// 앱 전체 상태: NAS 목록, 선택된 NAS, NAS별 로그인 세션.
class AppState extends ChangeNotifier {
  final store = ProfileStore();
  List<NasProfile> profiles = [];
  String? currentId;
  bool connecting = false;
  Object? error;
  final Map<String, QnapClient> _clients = {};

  NasProfile? get current =>
      profiles.where((p) => p.id == currentId).firstOrNull;
  QnapClient? get client => currentId == null ? null : _clients[currentId];

  Future<void> init() async {
    profiles = await store.load();
    final last = await store.lastSelected();
    currentId = profiles.any((p) => p.id == last) ? last : profiles.firstOrNull?.id;
    notifyListeners();
  }

  /// NAS를 선택하고, 아직 로그인 전이면 로그인한다. 세션은 NAS별로 유지되어 전환이 빠르다.
  Future<void> select(String id, {String? otp, bool force = false}) async {
    currentId = id;
    error = null;
    await store.setLastSelected(id);
    if (!force && otp == null && (_clients[id]?.isLoggedIn ?? false)) {
      notifyListeners();
      return;
    }
    connecting = true;
    notifyListeners();
    try {
      final p = current!;
      final pw = await store.password(p.id) ?? '';
      final c = QnapClient(p, pw);
      await c.login(otp: otp);
      _clients.remove(id)?.close();
      _clients[id] = c;
    } catch (e) {
      error = e;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> saveProfile(NasProfile p, String? password) async {
    final i = profiles.indexWhere((x) => x.id == p.id);
    if (i >= 0) {
      profiles[i] = p;
    } else {
      profiles.add(p);
    }
    await store.saveAll(profiles);
    if (password != null) await store.setPassword(p.id, password);
    _clients.remove(p.id)?.close();
    if (currentId == null || currentId == p.id) {
      await select(p.id);
    } else {
      notifyListeners();
    }
  }

  Future<void> deleteProfile(String id) async {
    profiles.removeWhere((p) => p.id == id);
    await store.saveAll(profiles);
    await store.deletePassword(id);
    _clients.remove(id)?.close();
    if (currentId == id) {
      currentId = null;
      if (profiles.isNotEmpty) {
        await select(profiles.first.id);
        return;
      }
    }
    notifyListeners();
  }
}

final app = AppState();
