import 'dart:convert';

import 'qnap_client.dart';

class DownloadTask {
  DownloadTask(this.hash, this.name, this.state, this.progress, this.downRate,
      this.upRate, this.size, this.eta);
  final String hash;
  final String name;
  final int state;
  final double progress;
  final int downRate;
  final int upRate;
  final int size;
  final int eta;

  bool get done => progress >= 100;
  bool get active => downRate > 0 || upRate > 0;
  String get stateLabel {
    if (done) return '완료';
    if (active) return '진행 중';
    return switch (state) {
      1 => '일시정지',
      2 => '정지',
      3 || 104 || 105 => '오류',
      _ => '대기',
    };
  }
}

/// Download Station V4 API (QTS 5 기본)
class DownloadApi {
  DownloadApi(this.c);
  final QnapClient c;

  String? _dsSid;

  Future<String> _sid() async {
    if (_dsSid != null) return _dsSid!;
    try {
      final j = await c.getJson('/downloadstation/V4/Misc/Login',
          {'user': c.profile.username, 'pass': ezEncode(c.password)});
      if (j is Map && '${j['error']}' == '0' && j['sid'] != null) {
        return _dsSid = '${j['sid']}';
      }
    } catch (_) {}
    return _dsSid = c.sid!; // QTS sid로 대신 시도
  }

  Future<Map> _call(String path, [Map<String, String>? q]) async {
    final sid = await _sid();
    final res = await c.client
        .get(Uri.parse('${c.baseUrl}/downloadstation/V4/$path')
            .replace(queryParameters: {...?q, 'sid': sid}))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 404) {
      throw ApiException('Download Station이 설치되어 있지 않거나 꺼져 있습니다');
    }
    final j = _decode(utf8.decode(res.bodyBytes));
    final err = int.tryParse('${j['error']}') ?? 0;
    if (err == 5 || err == 6) {
      // 세션 만료 → 다시 로그인
      _dsSid = null;
      throw SessionExpired();
    }
    if (err != 0) throw ApiException('Download Station 오류 (코드 $err)');
    return j;
  }

  Map _decode(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) return j;
    } catch (_) {}
    throw ApiException('Download Station 응답을 이해하지 못했습니다');
  }

  Future<List<DownloadTask>> tasks() => _retry(() async {
        final j = await _call('Task/Query',
            {'from': '0', 'limit': '0', 'status': 'all', 'type': 'all'});
        final data = (j['data'] as List?) ?? [];
        return [
          for (final e in data.whereType<Map>())
            DownloadTask(
              '${e['hash']}',
              '${e['source_name'] ?? e['source'] ?? '?'}',
              int.tryParse('${e['state']}') ?? 0,
              double.tryParse('${e['progress']}') ?? 0,
              int.tryParse('${e['down_rate']}') ?? 0,
              int.tryParse('${e['up_rate']}') ?? 0,
              int.tryParse('${e['size']}') ?? 0,
              int.tryParse('${e['eta']}') ?? 0,
            )
        ];
      });

  Future<T> _retry<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on SessionExpired {
      return await fn();
    }
  }

  Future<void> start(String hash) =>
      _retry(() => _call('Task/Start', {'hash': hash}));
  Future<void> stop(String hash) =>
      _retry(() => _call('Task/Stop', {'hash': hash}));
  Future<void> remove(String hash) =>
      _retry(() => _call('Task/Remove', {'hash': hash, 'clean': '0'}));

  Future<void> addUrl(String url, String tempDir, String moveDir) =>
      _retry(() => _call(
          'Task/AddUrl', {'url': url, 'temp': tempDir, 'move': moveDir}));
}
