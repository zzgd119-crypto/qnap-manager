import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 빌드할 때 GitHub Actions가 넣어주는 저장소 이름 (owner/repo)
const kGithubRepo = String.fromEnvironment('GH_REPO');

class UpdateInfo {
  UpdateInfo(this.version, this.notes, this.assetApiUrl, this.assetName);
  final String version;
  final String notes;
  final String assetApiUrl;
  final String assetName;
}

/// 비공개 GitHub 저장소의 최신 Release를 확인하고 설치한다.
/// 비공개 저장소라 읽기 전용 토큰(Fine-grained PAT, Contents: Read)이 필요하다.
class Updater {
  Updater(this.token);
  final String token;

  static String get assetName =>
      Platform.isAndroid ? 'qnap-manager-android.apk' : 'qnap-manager-windows.zip';

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  static Future<String> currentVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  /// 새 버전이 있으면 정보를, 없으면 null을 돌려준다.
  Future<UpdateInfo?> check() async {
    if (kGithubRepo.isEmpty) {
      throw Exception('이 빌드에는 저장소 정보가 없습니다 (로컬 빌드)');
    }
    final res = await http.get(
      Uri.parse('https://api.github.com/repos/$kGithubRepo/releases/latest'),
      headers: {..._headers, 'Accept': 'application/vnd.github+json'},
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw Exception('GitHub 토큰이 올바르지 않거나 권한이 없습니다');
    }
    if (res.statusCode == 404) {
      throw Exception('릴리스를 찾지 못했습니다 (저장소 또는 토큰 권한 확인)');
    }
    if (res.statusCode != 200) throw Exception('GitHub HTTP ${res.statusCode}');
    final j = jsonDecode(res.body) as Map;
    final latest = '${j['tag_name']}'.replaceFirst(RegExp(r'^v'), '');
    final current = await currentVersion();
    if (compareVersions(latest, current) <= 0) return null;
    final asset = (j['assets'] as List)
        .cast<Map>()
        .where((a) => a['name'] == assetName)
        .firstOrNull;
    if (asset == null) throw Exception('릴리스에 $assetName 파일이 없습니다');
    return UpdateInfo(latest, '${j['body'] ?? ''}', '${asset['url']}', assetName);
  }

  /// 파일을 내려받는다. GitHub는 실제 파일 주소로 리다이렉트하는데,
  /// 그 주소에는 토큰을 보내면 안 되므로 리다이렉트를 직접 처리한다.
  Future<File> download(UpdateInfo info,
      {void Function(int, int)? onProgress}) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(info.assetApiUrl));
      req.followRedirects = false;
      _headers.forEach(req.headers.set);
      req.headers.set('Accept', 'application/octet-stream');
      var res = await req.close();
      if (res.isRedirect) {
        final loc = res.headers.value('location')!;
        await res.drain<void>();
        res = await (await client.getUrl(Uri.parse(loc))).close();
      }
      if (res.statusCode != 200) {
        throw Exception('업데이트 다운로드 실패 (HTTP ${res.statusCode})');
      }
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, info.assetName));
      final sink = file.openWrite();
      var done = 0;
      await for (final chunk in res) {
        sink.add(chunk);
        done += chunk.length;
        onProgress?.call(done, res.contentLength);
      }
      await sink.close();
      return file;
    } finally {
      client.close();
    }
  }

  /// Android: 설치 화면을 연다. Windows: 앱을 닫고 새 파일로 교체한 뒤 다시 실행한다.
  static Future<void> install(File file) async {
    if (Platform.isAndroid) {
      final r = await OpenFilex.open(file.path,
          type: 'application/vnd.android.package-archive');
      if (r.type != ResultType.done) throw Exception(r.message);
      return;
    }
    if (Platform.isWindows) {
      final exe = Platform.resolvedExecutable;
      final appDir = p.dirname(exe);
      final script = File(p.join(p.dirname(file.path), 'qnap_update.ps1'));
      await script.writeAsString('''
\$ErrorActionPreference = "Stop"
Wait-Process -Id $pid -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
\$tmp = Join-Path \$env:TEMP "qnap_manager_update"
if (Test-Path \$tmp) { Remove-Item \$tmp -Recurse -Force }
Expand-Archive -Path "${file.path}" -DestinationPath \$tmp -Force
Copy-Item -Path (Join-Path \$tmp "*") -Destination "$appDir" -Recurse -Force
Start-Process -FilePath "$exe"
''');
      await Process.start(
        'powershell.exe',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
          '-File', script.path],
        mode: ProcessStartMode.detached,
      );
      exit(0);
    }
    throw Exception('지원하지 않는 플랫폼입니다');
  }
}

/// "1.0.12" 와 "1.0.9" 비교: 앞이 크면 양수
int compareVersions(String a, String b) {
  List<int> parse(String v) =>
      v.split(RegExp(r'[.+]')).map((s) => int.tryParse(s) ?? 0).toList();
  final x = parse(a), y = parse(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}
