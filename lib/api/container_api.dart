import 'dart:convert';

import 'package:http/http.dart' as http;

import 'qnap_client.dart';

class ContainerInfo {
  ContainerInfo(this.id, this.name, this.image, this.state, this.type);
  final String id;
  final String name;
  final String image;
  final String state;
  final String type;
  bool get running => state.toLowerCase() == 'running';
}

/// Container Station API.
/// QTS 5의 Container Station 3와 이전 버전의 경로가 달라 처음 호출 때 맞는 경로를 찾는다.
class ContainerApi {
  ContainerApi(this.c);
  final QnapClient c;

  static const _candidates = [
    '/container-station/api/v1',
    '/containerstation/api/v1',
  ];

  String? _base;
  String? _csCookie;

  Map<String, String> get _headers => {
        'Cookie': [
          if (c.sid != null) 'NAS_SID=${c.sid}',
          ?_csCookie,
        ].join('; '),
        'Accept': 'application/json',
      };

  Future<http.Response> _send(String method, String path) async {
    final url = c.uri('${_base!}$path');
    final req = http.Request(method, url)..headers.addAll(_headers);
    final streamed =
        await c.client.send(req).timeout(const Duration(seconds: 30));
    return http.Response.fromStream(streamed);
  }

  /// Container Station 자체 로그인 (sid 쿠키만으로 안 되는 버전용)
  Future<void> _csLogin() async {
    final res = await c.client.post(Uri.parse('${c.baseUrl}${_base!}/login'),
        body: {'username': c.profile.username, 'password': c.password});
    final setCookie = res.headers['set-cookie'];
    if (setCookie != null) {
      _csCookie = setCookie
          .split(RegExp(r',(?=[^ ;]+=)'))
          .map((s) => s.split(';').first.trim())
          .join('; ');
    }
  }

  Future<http.Response> _request(String method, String path) async {
    if (_base == null) await _detect();
    var res = await _send(method, path);
    if (res.statusCode == 401 || res.statusCode == 403) {
      await _csLogin();
      res = await _send(method, path);
    }
    if (res.statusCode >= 400) {
      throw ApiException('Container Station 오류 (HTTP ${res.statusCode})');
    }
    return res;
  }

  Future<void> _detect() async {
    for (final b in _candidates) {
      _base = b;
      try {
        var res = await _send('GET', '/container');
        if (res.statusCode == 401 || res.statusCode == 403) {
          await _csLogin();
          res = await _send('GET', '/container');
        }
        if (res.statusCode == 200 && _looksJson(res.body)) return;
      } catch (_) {}
    }
    _base = null;
    throw ApiException(
        'Container Station API를 찾지 못했습니다. Container Station이 설치·실행 중인지 확인하세요.');
  }

  static bool _looksJson(String s) {
    final t = s.trimLeft();
    return t.startsWith('[') || t.startsWith('{');
  }

  Future<List<ContainerInfo>> list() async {
    final res = await _request('GET', '/container');
    return parseList(jsonDecode(utf8.decode(res.bodyBytes)));
  }

  static List<ContainerInfo> parseList(dynamic j) {
    List items;
    if (j is List) {
      items = j;
    } else if (j is Map) {
      items = (j['data'] ?? j['containers'] ?? j['result'] ?? []) as List;
    } else {
      items = [];
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
          s(e, ['id', 'Id', 'container_id']),
          s(e, ['name', 'Name', 'Names']).replaceFirst(RegExp(r'^\[?/?'), '').replaceAll(']', ''),
          s(e, ['image', 'Image']),
          s(e, ['state', 'State', 'status', 'Status']),
          s(e, ['type', 'Type']).isEmpty ? 'docker' : s(e, ['type', 'Type']),
        )
    ];
  }

  /// action: start | stop | restart
  Future<void> action(ContainerInfo ct, String action) async {
    await _request('PUT', '/container/${ct.type}/${ct.id}/$action');
  }

  Future<String> logs(ContainerInfo ct) async {
    final res =
        await _request('GET', '/container/${ct.type}/${ct.id}/logs?tail=300');
    final body = utf8.decode(res.bodyBytes, allowMalformed: true);
    try {
      final j = jsonDecode(body);
      if (j is Map) return '${j['logs'] ?? j['data'] ?? j['result'] ?? body}';
      if (j is List) return j.join('\n');
    } catch (_) {}
    return body;
  }
}
