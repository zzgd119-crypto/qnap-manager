import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/nas_profile.dart';

/// NAS 목록은 일반 설정에, 비밀번호·토큰은 OS 보안 저장소(Android Keystore / Windows DPAPI)에 저장한다.
class ProfileStore {
  static const _profilesKey = 'nas_profiles';
  static const _lastKey = 'last_selected';
  static const _tokenKey = 'github_token';

  final _secure = const FlutterSecureStorage();

  Future<List<NasProfile>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_profilesKey);
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map((e) => NasProfile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveAll(List<NasProfile> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _profilesKey, jsonEncode(list.map((p) => p.toJson()).toList()));
  }

  Future<String?> lastSelected() async =>
      (await SharedPreferences.getInstance()).getString(_lastKey);

  Future<void> setLastSelected(String id) async =>
      (await SharedPreferences.getInstance()).setString(_lastKey, id);

  Future<String?> password(String id) => _secure.read(key: 'pw_$id');
  Future<void> setPassword(String id, String pw) =>
      _secure.write(key: 'pw_$id', value: pw);
  Future<void> deletePassword(String id) => _secure.delete(key: 'pw_$id');

  Future<String?> githubToken() => _secure.read(key: _tokenKey);
  Future<void> setGithubToken(String? t) => t == null || t.isEmpty
      ? _secure.delete(key: _tokenKey)
      : _secure.write(key: _tokenKey, value: t);

  Future<String?> getString(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);
  Future<void> setString(String key, String value) async =>
      (await SharedPreferences.getInstance()).setString(key, value);
}
