import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'qnap_client.dart';

class NasFile {
  NasFile(this.name, this.isDir, this.size, this.modified);
  final String name;
  final bool isDir;
  final int size;
  final DateTime? modified;
}

typedef Progress = void Function(int done, int total);

const _statusMessages = {
  0: '작업에 실패했습니다',
  2: '같은 이름의 파일이 이미 있습니다',
  4: '권한이 없습니다',
  5: '파일이 존재하지 않습니다',
};

/// QTS File Station API (/cgi-bin/filemanager/utilRequest.cgi)
class FileStation {
  FileStation(this.c);
  final QnapClient c;

  static const _path = '/cgi-bin/filemanager/utilRequest.cgi';

  Future<dynamic> _call(Map<String, String> q) => c.authed(() async {
        final j = await c.getJson(_path, q);
        _check(j);
        return j;
      });

  static void _check(dynamic j) {
    if (j is Map && j['status'] != null) {
      final s = int.tryParse('${j['status']}') ?? 1;
      if (s == 3) throw SessionExpired();
      if (s != 1) {
        throw ApiException(_statusMessages[s] ?? '오류 (status $s)');
      }
    }
  }

  /// 최상위 공유 폴더 목록
  Future<List<NasFile>> shares() async {
    final j = await _call({'func': 'get_tree', 'is_iso': '0', 'node': 'share_root'});
    final list = j is List ? j : (j is Map ? (j['datas'] ?? []) : []);
    return [
      for (final e in list as List)
        NasFile('${e['text'] ?? e['id']}'.replaceFirst('/', ''), true, 0, null)
    ];
  }

  Future<List<NasFile>> list(String path) async {
    final j = await _call({
      'func': 'get_list',
      'path': path,
      'start': '0',
      'limit': '5000',
      'sort': 'filename',
      'dir': 'ASC',
      'list_mode': 'all',
      'is_iso': '0',
      'hidden_file': '0',
    });
    final datas = (j is Map ? j['datas'] : null) as List? ?? [];
    final files = [
      for (final e in datas)
        NasFile(
          '${e['filename']}',
          '${e['isfolder']}' == '1',
          int.tryParse('${e['filesize']}') ?? 0,
          e['epochmt'] != null
              ? DateTime.fromMillisecondsSinceEpoch(
                  (int.tryParse('${e['epochmt']}') ?? 0) * 1000)
              : null,
        )
    ];
    files.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return files;
  }

  Future<void> createFolder(String parent, String name) =>
      _call({'func': 'createdir', 'dest_path': parent, 'dest_folder': name});

  Future<void> rename(String dir, String from, String to) => _call(
      {'func': 'rename', 'path': dir, 'source_name': from, 'dest_name': to});

  Future<void> delete(String dir, List<String> names) => c.authed(() async {
        // 같은 이름의 파라미터(file_name)를 여러 번 보내야 해서 직접 URL을 만든다.
        final q = StringBuffer('func=delete&path=${Uri.encodeQueryComponent(dir)}'
            '&file_total=${names.length}&sid=${c.sid}');
        for (final n in names) {
          q.write('&file_name=${Uri.encodeQueryComponent(n)}');
        }
        final res = await c.client
            .get(Uri.parse('${c.baseUrl}$_path?$q'))
            .timeout(const Duration(seconds: 60));
        _check(jsonDecode(utf8.decode(res.bodyBytes)));
      });

  Future<void> _copyMove(String func, String srcDir, List<String> names,
          String destDir) =>
      c.authed(() async {
        final q = StringBuffer('func=$func'
            '&source_path=${Uri.encodeQueryComponent(srcDir)}'
            '&dest_path=${Uri.encodeQueryComponent(destDir)}'
            '&source_total=${names.length}&mode=1&sid=${c.sid}');
        for (final n in names) {
          q.write('&source_file=${Uri.encodeQueryComponent(n)}');
        }
        final res = await c.client
            .get(Uri.parse('${c.baseUrl}$_path?$q'))
            .timeout(const Duration(minutes: 10));
        _check(jsonDecode(utf8.decode(res.bodyBytes)));
      });

  Future<void> move(String srcDir, List<String> names, String destDir) =>
      _copyMove('move', srcDir, names, destDir);

  Future<void> copy(String srcDir, List<String> names, String destDir) =>
      _copyMove('copy', srcDir, names, destDir);

  /// 파일(폴더는 zip으로) 다운로드. 저장된 로컬 경로를 반환한다.
  Future<File> download(String dir, NasFile f, Directory target,
      {Progress? onProgress}) async {
    final req = http.Request(
        'GET',
        c.uri(_path, {
          'func': 'download',
          'isfolder': f.isDir ? '1' : '0',
          'compress': f.isDir ? '1' : '0',
          'source_path': dir,
          'source_file': f.name,
          'source_total': '1',
        }));
    final res = await c.client.send(req);
    if (res.statusCode != 200) {
      throw ApiException('다운로드 실패 (HTTP ${res.statusCode})');
    }
    final ctype = res.headers['content-type'] ?? '';
    final name = f.isDir ? '${f.name}.zip' : f.name;
    final out = await _uniqueFile(target, name);
    final sink = out.openWrite();
    final total = res.contentLength ?? (f.isDir ? 0 : f.size);
    var done = 0;
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        done += chunk.length;
        onProgress?.call(done, total);
      }
    } finally {
      await sink.close();
    }
    // 세션 만료 시 파일 대신 JSON 오류가 내려오는 경우
    if (ctype.contains('json') && done < 200) {
      final body = await out.readAsString();
      await out.delete();
      _check(jsonDecode(body));
      throw ApiException('다운로드 실패: $body');
    }
    return out;
  }

  static Future<File> _uniqueFile(Directory dir, String name) async {
    await dir.create(recursive: true);
    var f = File(p.join(dir.path, name));
    var i = 1;
    final base = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    while (await f.exists()) {
      f = File(p.join(dir.path, '$base ($i)$ext'));
      i++;
    }
    return f;
  }

  Future<void> upload(File local, String destDir, {Progress? onProgress}) =>
      c.authed(() async {
        final name = p.basename(local.path);
        final length = await local.length();
        var sent = 0;
        final stream = local.openRead().transform<List<int>>(
          StreamTransformer.fromHandlers(handleData: (data, sink) {
            sent += data.length;
            onProgress?.call(sent, length);
            sink.add(data);
          }),
        );
        final req = http.MultipartRequest(
            'POST',
            c.uri(_path, {
              'func': 'upload',
              'type': 'standard',
              'dest_path': destDir,
              'overwrite': '1',
              'progress': '${destDir.replaceAll('/', '-')}-$name',
            }))
          ..files.add(http.MultipartFile('file', stream, length, filename: name));
        final res = await c.client.send(req);
        final body = await res.stream.bytesToString();
        if (res.statusCode != 200) {
          throw ApiException('업로드 실패 (HTTP ${res.statusCode})');
        }
        try {
          _check(jsonDecode(body));
        } on FormatException {
          // 일부 펌웨어는 JSON이 아닌 응답을 준다 → 성공으로 간주
        }
      });
}
