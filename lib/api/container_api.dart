import 'dart:convert';

import 'package:http/http.dart' as http;

import '../util/compose_yaml.dart';
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

  String? _logsPattern; // 동작 확인된 로그 경로 형식

  static List<String> _logCandidates(ContainerInfo ct) => [
        '/v3/containers/${ct.type}/logs?id=${ct.id}&tail=300',
        '/v3/containers/${ct.type}/${ct.id}/logs?tail=300',
        '/v3/containers/logs?id=${ct.id}&type=${ct.type}&tail=300',
        '/v1/container/${ct.type}/${ct.id}/logs?tail=300',
      ];

  /// Container Station 3 는 버전마다 로그 경로가 달라 후보를 차례로 시도한다.
  Future<String> logs(ContainerInfo ct) async {
    if (_prefix == null) await _connect();
    final candidates = _logCandidates(ct);
    final ordered = _logsPattern == null
        ? candidates
        : [candidates[int.parse(_logsPattern!)], ...candidates];
    for (final path in ordered) {
      var res = await _send('GET', '$_prefix$path');
      if (res.statusCode == 401 || res.statusCode == 403) {
        await _login(_prefix!);
        res = await _send('GET', '$_prefix$path');
      }
      if (res.statusCode == 404 || res.statusCode == 405) continue;
      if (res.statusCode >= 400) {
        throw ApiException(
            'Container Station 오류 (HTTP ${res.statusCode}) ${_short(res.body)}');
      }
      _logsPattern = '${candidates.indexOf(path)}';
      return _extractLogs(utf8.decode(res.bodyBytes, allowMalformed: true));
    }
    throw ApiException(
        '이 Container Station 버전에서 로그 API를 찾지 못했습니다.\n'
        '설정 → API 진단 결과를 보내 주시면 맞춰 고치겠습니다.');
  }

  static String _extractLogs(String body) {
    try {
      dynamic j = jsonDecode(body);
      if (j is Map && j['data'] != null) j = j['data'];
      if (j is String) return j;
      if (j is Map) {
        final v = j['logs'] ?? j['log'] ?? j['items'] ?? j['result'];
        if (v is List) return v.join('\n');
        if (v != null) return '$v';
      }
      if (j is List) return j.join('\n');
    } catch (_) {}
    return body;
  }

  // ---------------- 이미지 당기기 / 애플리케이션 재생성 ----------------

  /// "ghcr.io/a/b:latest" → ("ghcr.io/a/b", "latest")
  static (String, String) splitImage(String image) {
    final at = image.indexOf('@');
    final base = at >= 0 ? image.substring(0, at) : image;
    final slash = base.lastIndexOf('/');
    final colon = base.lastIndexOf(':');
    if (colon > slash) {
      return (base.substring(0, colon), base.substring(colon + 1));
    }
    return (base, 'latest');
  }

  int? _pullPattern;

  static List<(String, Object)> _pullCandidates(String image) {
    final (repo, tag) = splitImage(image);
    final slash = repo.indexOf('/');
    final hasRegistry = slash > 0 &&
        (repo.substring(0, slash).contains('.') ||
            repo.substring(0, slash).contains(':'));
    return [
      ('/v3/images/pull', {'image': '$repo:$tag'}),
      ('/v3/images/pull', {'data': {'image': repo, 'tag': tag}}),
      ('/v1/background/image_download', {
        'type': 'docker',
        'repository': hasRegistry ? repo.substring(0, slash) : '',
        'image': hasRegistry ? repo.substring(slash + 1) : repo,
        'tag': tag,
      }),
    ];
  }

  /// 이미지를 레지스트리에서 다시 받는다. 작업 ID가 있으면 반환한다.
  Future<String?> pullImage(String image) async {
    if (_prefix == null) await _connect();
    final cands = _pullCandidates(image);
    final order = _pullPattern == null
        ? List.generate(cands.length, (i) => i)
        : [_pullPattern!, ...List.generate(cands.length, (i) => i)];
    final tried = <String>[];
    for (final i in order.toSet()) {
      final (path, body) = cands[i];
      var res = await _send('POST', '$_prefix$path', body: body);
      if (res.statusCode == 401 || res.statusCode == 403) {
        await _login(_prefix!);
        res = await _send('POST', '$_prefix$path', body: body);
      }
      if (res.statusCode == 404 || res.statusCode == 405) {
        tried.add('$path → ${res.statusCode}');
        continue;
      }
      if (res.statusCode == 400 && i < cands.length - 1) {
        tried.add('$path → 400 ${_short(res.body)}');
        continue; // 형식이 다를 수 있어 다음 후보로
      }
      if (res.statusCode >= 400) {
        throw ApiException(
            '이미지 당기기 실패 (HTTP ${res.statusCode}) ${_short(res.body)}');
      }
      _pullPattern = i;
      return _taskId(res.body);
    }
    throw ApiException('이 Container Station 버전의 이미지 당기기 API를 찾지 못했습니다.\n'
        '${tried.join('\n')}');
  }

  /// 애플리케이션(compose) 정보: yml, 리소스 제한, 기본 URL
  Future<Map> inspectApp(String name) async {
    final res = await _request(
        'GET', '/v3/apps/${Uri.encodeComponent(name)}/inspect');
    final j = jsonDecode(utf8.decode(res.bodyBytes));
    final d = j is Map ? (j['data'] ?? j) : null;
    if (d is! Map || d['yml'] == null) {
      throw ApiException('애플리케이션 정보를 읽지 못했습니다: ${_short(res.body)}');
    }
    return d;
  }

  /// Container Station 의 "재생성"과 같다: 현재 yml 로 애플리케이션을 다시 만든다.
  /// [pullLatest] 이면 yml 의 서비스에 pull_policy: always 를 넣어
  /// 재생성하면서 최신 이미지를 받게 한다 (yml 에 그대로 저장됨).
  Future<String?> recreateApp(String name, {bool pullLatest = false}) async {
    final d = await inspectApp(name);
    var yml = '${d['yml']}';
    if (pullLatest) yml = ensurePullAlways(yml);
    final url = d['defaultURL'] is Map ? d['defaultURL'] as Map : const {};
    final body = {
      'name': name,
      'yml': yml,
      'operation': 'recreate',
      'default_url': {
        'port': url['port'] ?? 0,
        'service': url['service'] ?? '',
      },
      'cpu_limit': d['cpuLimit'] ?? 0,
      'mem_limit': d['memLimit'] ?? 0,
      'mem_reservation': d['memReservation'] ?? 0,
      'last_updated': '${d['lastUpdated'] ?? d['last_updated'] ?? ''}',
    };
    final res = await _request('POST', '/v3/apps/compose', body: body);
    return _taskId(res.body);
  }

  static String? _taskId(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final d = j['data'];
        final id = (d is Map ? (d['taskID'] ?? d['taskId'] ?? d['id']) : null) ??
            j['taskID'] ?? j['taskId'];
        return id?.toString();
      }
    } catch (_) {}
    return null;
  }

  /// 백그라운드 작업이 끝날 때까지 기다린다. onUpdate(진행률, 설명)
  Future<void> waitTask(String taskId,
      {void Function(int progress, String text)? onUpdate,
      Duration timeout = const Duration(minutes: 20)}) async {
    final end = DateTime.now().add(timeout);
    var notFound = 0;
    while (DateTime.now().isBefore(end)) {
      final res = await _request('GET', '/v3/tasks');
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      final items = (j is Map && j['data'] is Map ? j['data']['items'] : null)
              as List? ??
          const [];
      final t = items.whereType<Map>().where((e) => '${e['id']}' == taskId).firstOrNull;
      if (t == null) {
        // 끝난 작업은 목록에서 빠지기도 한다. 성공 여부는 호출한 쪽에서 다시 확인한다.
        if (++notFound >= 3) return;
      } else {
        final state = '${t['state']}'.toLowerCase();
        onUpdate?.call(int.tryParse('${t['progress']}') ?? 0,
            '${t['description'] ?? ''} ${t['detail'] ?? ''}'.trim());
        if (state == 'completed' || state == 'done' || state == 'success') return;
        if (state.contains('fail') || state.contains('error') || state == 'canceled') {
          throw ApiException('작업 실패: ${t['detail'] ?? t['description'] ?? state}');
        }
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw ApiException('작업이 제한 시간 안에 끝나지 않았습니다 (Container Station에서 확인하세요)');
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
          if (r.statusCode == 200 && _looksJson(r.body)) {
            final first = parseList(jsonDecode(r.body)).firstOrNull;
            if (first != null) {
              if (first.project.isNotEmpty) {
                final ar = await _send('GET',
                    '$prefix/v3/apps/${Uri.encodeComponent(first.project)}/inspect');
                b.writeln('앱 inspect: HTTP ${ar.statusCode} ${_short(ar.body).length > 80 ? '${_short(ar.body).substring(0, 80)}…' : _short(ar.body)}');
              }
              final tr = await _send('GET', '$prefix/v3/tasks');
              b.writeln('작업 목록: HTTP ${tr.statusCode}');
              for (final lp in _logCandidates(first)) {
                final lr = await _send('GET', '$prefix$lp');
                b.writeln('로그 ${lp.replaceAll(first.id, '{id}')}: HTTP ${lr.statusCode} ${_short(lr.body).length > 80 ? '${_short(lr.body).substring(0, 80)}…' : _short(lr.body)}');
              }
            }
          }
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
