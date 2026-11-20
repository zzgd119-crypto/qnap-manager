import 'dart:convert';

import 'package:http/http.dart' as http;

import 'qnap_client.dart';

class ContainerInfo {
  ContainerInfo(this.id, this.name, this.image, this.state, this.type,
      {this.project = ''});
  final String id;
  final String name;
  final String image;
  final String state;
  final String type;
  final String project;
  bool get running => state.toLowerCase() == 'running';
}

/// Container Station API.
///
/// Container Station 3 (QTS 5)는 QTS 세션과 별도로 자체 로그인이 필요하다.
///   POST /container-station/api/v1/login  {"username","password"} (JSON)
///   → Set-Cookie 로 받은 값을 Cookie 와 "Authorization: Bearer" 로 보낸다.
/// 목록/제어는 v1 경로를 먼저 쓰고, 없으면 v3 경로를 쓴다.
class ContainerApi {
  ContainerApi(this.c);
  final QnapClient c;

  static const _prefixes = ['/container-station/api', '/containerstation/api'];

  String? _prefix; // 동작 확인된 경로 접두어
  bool _v3 = false; // v1 목록이 없어서 v3 를 쓰는지
  String? _cookie; // CS 로그인 쿠키 "name=value"

  Map<String, String> get _headers {
    final cookies = [
      ?_cookie,
      if (c.sid != null) 'NAS_SID=${c.sid}',
    ];
    final token = _cookie?.split('=').skip(1).join('=');
    return {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (cookies.isNotEmpty) 'Cookie': cookies.join('; '),
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  Future<http.Response> _send(String method, String url, {Object? body}) async {
    final req = http.Request(method, Uri.parse('${c.baseUrl}$url'))
      ..headers.addAll(_headers);
    if (body != null) req.body = jsonEncode(body);
    final streamed =
        await c.client.send(req).timeout(const Duration(seconds: 30));
    return http.Response.fromStream(streamed);
  }

  Future<void> _login(String prefix) async {
    _cookie = null;
    final res = await _send('POST', '$prefix/v1/login',
        body: {'username': c.profile.username, 'password': c.password});
    if (res.statusCode == 404) throw _NotFound();
    if (res.statusCode >= 400) {
      throw ApiException(
          'Container Station 로그인 실패 (HTTP ${res.statusCode}) ${_short(res.body)}');
    }
    final setCookie = res.headers['set-cookie'];
    if (setCookie != null && setCookie.isNotEmpty) {
      _cookie = setCookie.split(';').first.trim();
    }
  }

  /// 로그인하고, 목록이 나오는 경로(v1 또는 v3)를 찾는다.
  Future<void> _connect() async {
    final errors = <String>[];
    for (final prefix in _prefixes) {
      try {
        await _login(prefix);
      } on _NotFound {
        continue;
      } catch (e) {
        errors.add('$e');
        continue;
      }
      _prefix = prefix;
      var res = await _send('GET', '$prefix/v1/container');
      if (res.statusCode == 200 && _looksJson(res.body)) {
        _v3 = false;
        return;
      }
      res = await _send('GET', '$prefix/v3/containers');
      if (res.statusCode == 200 && _looksJson(res.body)) {
        _v3 = true;
        return;
      }
      errors.add('목록 조회 실패 (HTTP ${res.statusCode}) ${_short(res.body)}');
    }
    _prefix = null;
    throw ApiException(errors.isEmpty
        ? 'Container Station API를 찾지 못했습니다. Container Station이 설치·실행 중인지 확인하세요.'
        : errors.join('\n'));
  }

  /// 연결 후 요청. 401이면 한 번 다시 로그인한다.
  Future<http.Response> _request(String method, String path,
      {Object? body}) async {
    if (_prefix == null) await _connect();
    var res = await _send(method, '$_prefix$path', body: body);
    if (res.statusCode == 401 || res.statusCode == 403) {
      await _login(_prefix!);
      res = await _send(method, '$_prefix$path', body: body);
    }
    if (res.statusCode >= 400) {
      throw ApiException(
          'Container Station 오류 (HTTP ${res.statusCode}) ${_short(res.body)}');
    }
    return res;
  }

  static bool _looksJson(String s) {
    final t = s.trimLeft();
    return t.startsWith('[') || t.startsWith('{');
  }

  static String _short(String s) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length > 200 ? '${t.substring(0, 200)}…' : t;
  }

  Future<List<ContainerInfo>> list() async {
    if (_prefix == null) await _connect();
    final res =
        await _request('GET', _v3 ? '/v3/containers' : '/v1/container');
    return parseList(jsonDecode(utf8.decode(res.bodyBytes)));
  }

  static List<ContainerInfo> parseList(dynamic j) {
    List items = const [];
    if (j is List) {
      items = j;
    } else if (j is Map) {
      dynamic d = j['data'] ?? j['containers'] ?? j['result'] ?? j['items'];
      if (d is Map) d = d['items'] ?? d['containers'] ?? d['data'];
      if (d is List) items = d;
    }
    String s(Map m, List<String> keys) {
      for (final k in keys) {
        final v = m[k];
        if (v != null && '$v'.isNotEmpty) return '$v';
      }
      return '';
    }

    return [
      for (final e in items.whereType<Map>())
        ContainerInfo(
          s(e, ['id', 'Id', 'container_id', 'cid']),
          s(e, ['name', 'Name', 'Names'])
              .replaceFirst(RegExp(r'^\[?/?'), '')
              .replaceAll(']', ''),
          s(e, ['image', 'Image']),
          s(e, ['state', 'State', 'status', 'Status']),
          s(e, ['type', 'Type', 'ctype']).isEmpty
              ? 'docker'
              : s(e, ['type', 'Type', 'ctype']),
          project: s(e, ['project']),
        )
    ];
  }

  /// action: start | stop | restart
  Future<void> action(ContainerInfo ct, String action) async {
    if (_prefix == null) await _connect();
    if (!_v3) {
      await _request('PUT', '/v1/container/${ct.type}/${ct.id}/$action');
      return;
    }
    // v3: 일괄 작업 형식, restart 는 stop 후 start
    final body = {
      'data': {
        'items': [
          {'cid': ct.id, 'ctype': ct.type}
        ]
      }
    };
    if (action == 'restart') {
      await _request('PUT', '/v3/containers/stop', body: body);
      await _request('PUT', '/v3/containers/start', body: body);
    } else {
      await _request('PUT', '/v3/containers/$action', body: body);
    }
  }

  Future<String> logs(ContainerInfo ct) async {
    if (_prefix == null) await _connect();
    final res = await _request(
        'GET', '/v1/container/${ct.type}/${ct.id}/logs?tail=300');
    final body = utf8.decode(res.bodyBytes, allowMalformed: true);
    try {
      final j = jsonDecode(body);
      if (j is String) return j;
      if (j is Map) return '${j['logs'] ?? j['data'] ?? j['result'] ?? body}';
      if (j is List) return j.join('\n');
    } catch (_) {}
    return body;
  }

  /// 진단 화면용: 로그인과 각 목록 경로의 원본 응답
  Future<String> diagnose() async {
    final b = StringBuffer();
    for (final prefix in _prefixes) {
      b.writeln('--- $prefix');
      try {
        await _login(prefix);
        b.writeln('login: 성공, 쿠키 ${_cookie == null ? '없음' : _cookie!.split('=').first}');
        for (final p in ['/v1/container', '/v3/containers']) {
          final r = await _send('GET', '$prefix$p');
          b.writeln('GET $p: HTTP ${r.statusCode} ${_short(r.body)}');
        }
      } on _NotFound {
        b.writeln('login: 404 (이 경로 없음)');
      } catch (e) {
        b.writeln('오류: $e');
      }
    }
    _prefix = null;
    return b.toString();
  }
}

class _NotFound implements Exception {}
