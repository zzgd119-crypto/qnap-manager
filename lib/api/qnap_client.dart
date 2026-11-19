import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:xml/xml.dart';

import '../models/nas_profile.dart';

class AuthException implements Exception {
  AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 2단계 인증이 켜진 계정: OTP 코드를 받아 다시 로그인해야 한다.
class TwoFactorRequired implements Exception {
  @override
  String toString() => '2단계 인증 코드가 필요합니다';
}

/// 세션(sid)이 만료됨 → 자동 재로그인 대상
class SessionExpired implements Exception {
  @override
  String toString() => '세션이 만료되었습니다';
}

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// QTS 비밀번호 인코딩(ezEncode)은 UTF-8 바이트의 Base64와 같다.
String ezEncode(String s) => base64.encode(utf8.encode(s));

String? xmlText(XmlNode doc, String tag) {
  final e = doc.findAllElements(tag).firstOrNull;
  return e?.innerText.trim();
}

/// NAS 한 대와의 연결. 로그인해서 받은 sid를 들고 다니며, 만료되면 한 번 재로그인한다.
class QnapClient {
  QnapClient(this.profile, this.password) {
    final io = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..idleTimeout = const Duration(seconds: 30);
    if (profile.allowSelfSigned) {
      io.badCertificateCallback = (cert, host, port) => true;
    }
    client = IOClient(io);
  }

  final NasProfile profile;
  final String password;
  late final http.Client client;

  String baseUrl = '';
  String? sid;
  Future<void>? _relogin;

  bool get isLoggedIn => sid != null;

  /// 등록된 주소를 순서대로 시도해서 먼저 되는 곳에 로그인한다.
  Future<void> login({String? otp}) async {
    final urls = profile.urls;
    if (urls.isEmpty) throw ApiException('NAS 주소가 없습니다');
    Object? lastError;
    for (final url in urls) {
      try {
        await _loginAt(url, otp);
        baseUrl = url;
        return;
      } on AuthException {
        rethrow;
      } on TwoFactorRequired {
        rethrow;
      } catch (e) {
        lastError = e;
      }
    }
    throw ApiException('NAS에 연결할 수 없습니다: $lastError');
  }

  Future<void> _loginAt(String url, String? otp) async {
    final body = {
      'user': profile.username,
      'pwd': ezEncode(password),
      'serviceKey': '1',
      'remme': '1',
      'client_app': 'qnap_manager',
      if (otp != null && otp.isNotEmpty) 'security_code': otp,
    };
    final res = await client
        .post(Uri.parse('$url/cgi-bin/authLogin.cgi'), body: body)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw ApiException('HTTP ${res.statusCode}');
    }
    final doc = XmlDocument.parse(res.body);
    if (xmlText(doc, 'authPassed') == '1') {
      sid = xmlText(doc, 'authSid');
      if (sid == null || sid!.isEmpty) throw ApiException('sid를 받지 못했습니다');
      return;
    }
    if (xmlText(doc, 'need_2sv') == '1') throw TwoFactorRequired();
    throw AuthException('아이디 또는 비밀번호가 올바르지 않습니다');
  }

  Future<void> logout() async {
    if (sid == null) return;
    try {
      await client
          .get(Uri.parse('$baseUrl/cgi-bin/authLogin.cgi?logout=1&sid=$sid'))
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
    sid = null;
  }

  Uri uri(String path, [Map<String, String>? query, bool withSid = true]) {
    final q = <String, String>{...?query};
    if (withSid && sid != null) q['sid'] = sid!;
    return Uri.parse('$baseUrl$path')
        .replace(queryParameters: q.isEmpty ? null : q);
  }

  Map<String, String> get cookieHeaders =>
      sid == null ? {} : {'Cookie': 'NAS_SID=$sid'};

  Future<http.Response> get(String path, [Map<String, String>? query]) async {
    final res = await client
        .get(uri(path, query), headers: cookieHeaders)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 401) throw SessionExpired();
    if (res.statusCode != 200) {
      throw ApiException('HTTP ${res.statusCode} ($path)');
    }
    return res;
  }

  Future<XmlDocument> getXml(String path, [Map<String, String>? query]) async {
    final res = await get(path, query);
    final doc = XmlDocument.parse(utf8.decode(res.bodyBytes));
    if (xmlText(doc, 'authPassed') == '0') throw SessionExpired();
    return doc;
  }

  Future<dynamic> getJson(String path, [Map<String, String>? query]) async {
    final res = await get(path, query);
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  /// 세션이 만료되면 한 번만 재로그인 후 다시 시도한다.
  Future<T> authed<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on SessionExpired {
      _relogin ??= login().whenComplete(() => _relogin = null);
      await _relogin;
      return await fn();
    }
  }

  void close() => client.close();
}
