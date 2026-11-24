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

  // ---------------- 이미지 당기기 / 컨테이너 재생성 ----------------
  // Container Station 3 웹 화면이 보내는 요청과 똑같이 보낸다 (NAS 화면 코드 분석으로 확인).
  //   이미지 당기기:   POST api/v3/images/{type}/pull        {image: "이름:태그", rememberme: false}
  //   컨테이너 재생성: POST api/v3/containers/{type}/recreate {id, pull, commit: false}

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

  /// 이미지를 레지스트리에서 다시 받는다 (Container Station 의 "이미지 당기기").
  Future<void> pullImage(String image,
      {String type = 'docker',
      void Function(int progress, String text)? onUpdate}) async {
    final (repo, tag) = splitImage(image);
    final started = DateTime.now();
    final res = await _request('POST', '/v3/images/$type/pull',
        body: {'image': '$repo:$tag', 'rememberme': false});
    await _waitBackground(
        category: 'imagepull',
        hint: repo.split('/').last,
        since: started,
        taskId: _taskId(res.body),
        onUpdate: onUpdate);
  }

  /// 컨테이너를 같은 설정으로 다시 만든다 (Container Station 의 "재생성").
  /// [pull] 이면 최신 이미지를 먼저 받는다. 볼륨 데이터는 유지된다.
  Future<void> recreateContainer(ContainerInfo ct,
      {required bool pull,
      void Function(int progress, String text)? onUpdate}) async {
    final started = DateTime.now();
    final res = await _request('POST', '/v3/containers/${ct.type}/recreate',
        body: {'pull': pull, 'commit': false, 'id': ct.id});
    await _waitBackground(
        category: 'containerrecreate',
        hint: ct.name,
        since: started,
        taskId: _taskId(res.body),
        onUpdate: onUpdate);
    // 재생성 뒤에도 같은 이름의 컨테이너가 있는지 확인
    final after = await list();
    if (!after.any((c) => c.name == ct.name)) {
      throw ApiException('재생성 후 ${ct.name} 컨테이너가 보이지 않습니다. '
          'Container Station에서 상태를 확인해 주세요.');
    }
  }

  /// 애플리케이션 재생성 (Container Station 화면의 Applications → Recreate 와 같은 요청).
  /// POST api/v3/apps/compose {name, yml, defaultURL?, cpupin, cpuLimit, memLimit,
  ///   memReservation, operation: "recreate", fromTemplate: null}
  /// NAS 가 기존 앱 삭제 → 같은 yml 로 생성까지 진행한다. 볼륨 데이터는 유지된다.
  Future<void> recreateApp(String name,
      {void Function(int progress, String text)? onUpdate}) async {
    final res = await _request(
        'GET', '/v3/apps/${Uri.encodeComponent(name)}/inspect');
    final j = jsonDecode(utf8.decode(res.bodyBytes));
    final d = j is Map ? j['data'] : null;
    if (d is! Map || d['yml'] is! String || (d['yml'] as String).trim().isEmpty) {
      throw ApiException('애플리케이션 설정(yml)을 읽지 못해 재생성을 중단했습니다.');
    }
    final url = d['defaultURL'];
    final port = url is Map ? int.tryParse('${url['port']}') ?? 0 : 0;
    final body = <String, Object?>{
      'name': name,
      'yml': d['yml'],
      if (port > 0) 'defaultURL': {'port': port, 'service': url['service'] ?? ''},
      if (d['cpupin'] != null) 'cpupin': d['cpupin'],
      'cpuLimit': d['cpuLimit'],
      'memLimit': d['memLimit'],
      'memReservation': d['memReservation'],
      'operation': 'recreate',
      'fromTemplate': null,
    };
    final started = DateTime.now();
    final r = await _request('POST', '/v3/apps/compose', body: body);
    await _waitBackground(
        category: 'compose',
        hint: name,
        since: started,
        taskId: _taskId(r.body),
        onUpdate: onUpdate);
    // 다시 만들어질 때까지 최대 3분 확인
    final end = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(end)) {
      final now = await list();
      if (now.any((c) => c.project == name)) return;
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    throw ApiException('재생성 후 $name 앱의 컨테이너가 보이지 않습니다.\n'
        'Container Station → Applications에서 확인해 주세요.\n\n'
        '복구용 yml:\n${d['yml']}');
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

  /// 백그라운드 작업(api/v3/tasks)이 끝날 때까지 기다린다.
  /// 작업 ID 를 모르면 종류(category)와 이름으로 찾는다.
  Future<void> _waitBackground({
    required String category,
    required String hint,
    required DateTime since,
    String? taskId,
    void Function(int progress, String text)? onUpdate,
    Duration timeout = const Duration(minutes: 30),
  }) async {
    final end = DateTime.now().add(timeout);
    var seen = false;
    var emptyPolls = 0;
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final res = await _request('GET', '/v3/tasks');
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      final items = (j is Map && j['data'] is Map ? j['data']['items'] : null)
              as List? ??
          const [];
      final mine = items.whereType<Map>().where((t) {
        if (taskId != null) return '${t['id']}' == taskId;
        final cat = '${t['category']}'.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
        final text = '${t['description']} ${t['detail']}'.toLowerCase();
        return cat.contains(category) || text.contains(hint.toLowerCase());
      }).toList();

      if (mine.isEmpty) {
        // 작업이 목록에 안 나타나거나 이미 사라짐 → 몇 번 확인 후 끝난 것으로 봄
        if (++emptyPolls >= (seen ? 2 : 4)) return;
        continue;
      }
      seen = true;
      emptyPolls = 0;
      final t = mine.first;
      final state = '${t['state']}'.toLowerCase();
      onUpdate?.call(int.tryParse('${t['progress']}') ?? 0,
          '${t['description'] ?? ''} ${t['detail'] ?? ''}'.trim());
      if (state.contains('fail') || state.contains('error') || state.contains('cancel')) {
        throw ApiException('작업 실패: ${t['detail'] ?? t['description'] ?? state}');
      }
      if (state == 'completed' || state == 'done' || state == 'success' || state == 'finished') {
        return;
      }
    }
    throw ApiException('작업이 제한 시간 안에 끝나지 않았습니다 (Container Station에서 확인하세요)');
  }

  // ---------------- Container Station 화면 코드 분석 (읽기 전용) ----------------

  /// NAS 의 Container Station 웹 화면(JS)을 내려받아, 이미지 Pull·재생성 등에 쓰는
  /// 실제 API 경로와 요청 형식을 찾는다. GET 요청만 보낸다.
  Future<String> analyzeWebUi(
      {List<String>? searchTerms, void Function(String)? onStatus}) async {
    final out = StringBuffer('Container Station 화면 분석\n');
    if (_prefix == null) {
      try {
        await _connect();
      } catch (e) {
        out.writeln('로그인: $e');
      }
    }
    Future<http.Response> get(Uri u) async {
      final req = http.Request('GET', u)..headers.addAll(_headers);
      final r = await c.client.send(req).timeout(const Duration(seconds: 60));
      return http.Response.fromStream(r);
    }

    // 1) 화면 HTML 찾기
    Uri? indexUri;
    var html = '';
    for (final path in [
      '/container-station/',
      '/container-station/index.html',
      '/containerstation/'
    ]) {
      try {
        final u = Uri.parse('${c.baseUrl}$path');
        final r = await get(u);
        out.writeln('GET $path → ${r.statusCode} (${r.bodyBytes.length} B)');
        if (r.statusCode == 200 && r.body.contains('<script')) {
          indexUri = u;
          html = r.body;
          break;
        }
      } catch (e) {
        out.writeln('GET $path → 오류 $e');
      }
    }
    if (indexUri == null) {
      out.writeln('화면 HTML을 찾지 못했습니다.');
      return out.toString();
    }

    // 2) 스크립트 모으기 (HTML 의 script/modulepreload + JS 안의 .js 참조)
    final queue = <Uri>[];
    final seen = <String>{};
    void addRef(Uri from, String ref) {
      if (!ref.endsWith('.js')) return;
      if (ref.contains('://') && !ref.startsWith(c.baseUrl)) return;
      final u = from.resolve(ref);
      if (seen.add(u.toString())) queue.add(u);
    }

    final scriptTag =
        RegExp(r'''(?:src|href)\s*=\s*["']([^"'?]+\.js)(?:\?[^"']*)?["']''');
    for (final m in scriptTag.allMatches(html)) {
      addRef(indexUri, m.group(1)!);
    }
    final jsRef = RegExp(r'''["'`(]((?:\.{0,2}/)?[\w\-./]+?\.js)["'`)]''');
    // 찾을 대상: 요청 함수가 호출되는 곳(버튼 → 어떤 값을 넘기는지)
    final terms = <String, RegExp>{
      for (final t in (searchTerms ?? const ['createApplication', 'removeApplication', 'isRecreate']))
        if (t.trim().isNotEmpty) t.trim(): RegExp(RegExp.escape(t.trim())),
    };
    final snippets = {for (final k in terms.keys) k: <String>[]};
    var totalBytes = 0;
    var files = 0;
    while (queue.isNotEmpty && files < 300 && totalBytes < 60 * 1024 * 1024) {
      final u = queue.removeAt(0);
      files++;
      onStatus?.call('스크립트 $files개 분석 중… '
          '(${u.pathSegments.isEmpty ? u : u.pathSegments.last})');
      String js;
      try {
        final r = await get(u);
        if (r.statusCode != 200) continue;
        js = utf8.decode(r.bodyBytes, allowMalformed: true);
        totalBytes += r.bodyBytes.length;
      } catch (_) {
        continue;
      }
      for (final m in jsRef.allMatches(js)) {
        final ref = m.group(1)!;
        if (ref.contains('/')) addRef(u, ref);
      }
      for (final e in terms.entries) {
        final list = snippets[e.key]!;
        for (final m in e.value.allMatches(js)) {
          if (list.length >= 8) break;
          final a = (m.start - 600).clamp(0, js.length);
          final b = (m.end + 600).clamp(0, js.length);
          final norm = js.substring(a, b).replaceAll(RegExp(r'\s+'), ' ');
          final nonAscii = norm.runes.where((r) => r > 127).length;
          if (nonAscii > norm.length * 0.1) continue; // 번역 문구 건너뜀
          final core = norm.substring(
              (norm.length ~/ 2 - 60).clamp(0, norm.length),
              (norm.length ~/ 2 + 60).clamp(0, norm.length));
          // 이미 다른 항목에 같은 부분이 있으면 건너뜀
          if (snippets.values.any((l) => l.any((x) => x.contains(core)))) continue;
          list.add(norm);
        }
      }
    }
    out.writeln('스크립트 $files개, '
        '${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB 분석');
    for (final e in snippets.entries) {
      out.writeln('\n===== ${e.key} (${e.value.length}) =====');
      for (final s in e.value) {
        out.writeln('… $s …\n');
      }
    }
    return out.toString();
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
