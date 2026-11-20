import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../api/container_api.dart';
import '../app_state.dart';
import '../update/updater.dart';
import '../widgets/common.dart';
import 'nas_edit_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.autoUpdate = false});
  final bool autoUpdate;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _version = '';
  bool _hasToken = false;
  String? _updateStatus;
  double? _updateProgress;
  bool _updating = false;

  @override
  void initState() {
    super.initState();
    app.addListener(_refresh);
    _init();
  }

  @override
  void dispose() {
    app.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    _version = await Updater.currentVersion();
    _hasToken = ((await app.store.githubToken()) ?? '').isNotEmpty;
    _refresh();
    if (widget.autoUpdate) _checkUpdate();
  }

  Future<void> _setToken() async {
    final t = await promptText(context, 'GitHub 토큰',
        hint: 'github_pat_… (비워 두면 삭제)', ok: '저장');
    if (t == null) return;
    await app.store.setGithubToken(t);
    _hasToken = t.isNotEmpty;
    _refresh();
  }

  Future<void> _checkUpdate() async {
    final token = await app.store.githubToken();
    if (token == null || token.isEmpty) {
      setState(() => _updateStatus = '먼저 GitHub 토큰을 등록하세요');
      return;
    }
    setState(() {
      _updating = true;
      _updateStatus = '확인 중…';
      _updateProgress = null;
    });
    try {
      final u = Updater(token);
      final info = await u.check();
      if (info == null) {
        setState(() => _updateStatus = '최신 버전입니다');
        return;
      }
      if (!mounted) return;
      final go = await confirm(context, '새 버전 ${info.version}',
          info.notes.isEmpty ? '업데이트할까요?' : '${info.notes}\n\n업데이트할까요?',
          ok: '업데이트');
      if (!go) {
        setState(() => _updateStatus = '새 버전 ${info.version} 사용 가능');
        return;
      }
      setState(() => _updateStatus = '내려받는 중…');
      final file = await u.download(info, onProgress: (d, t) {
        if (mounted) setState(() => _updateProgress = t > 0 ? d / t : null);
      });
      setState(() => _updateStatus = '설치 중…');
      await Updater.install(file);
    } catch (e) {
      setState(() => _updateStatus = '실패: $e');
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final header = Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary);
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListView(children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('NAS', style: header)),
        for (final p in app.profiles)
          ListTile(
            leading: const Icon(Icons.storage),
            title: Text(p.name),
            subtitle: Text(p.urls.join('\n')),
            isThreeLine: p.urls.length > 1,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => NasEditScreen(profile: p))),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (await confirm(context, 'NAS 삭제', '${p.name}을(를) 목록에서 지울까요?',
                    ok: '삭제', danger: true)) {
                  await app.deleteProfile(p.id);
                }
              },
            ),
          ),
        ListTile(
          leading: const Icon(Icons.add),
          title: const Text('NAS 추가'),
          onTap: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const NasEditScreen())),
        ),
        const Divider(),
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('업데이트', style: header)),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text('현재 버전 $_version'),
          subtitle: Text(kGithubRepo.isEmpty ? '로컬 빌드 (자동 업데이트 없음)' : kGithubRepo),
        ),
        ListTile(
          leading: const Icon(Icons.key_outlined),
          title: const Text('GitHub 토큰'),
          subtitle: Text(_hasToken ? '등록됨' : '등록 안 됨 — 비공개 저장소의 업데이트를 받으려면 필요'),
          onTap: _setToken,
        ),
        ListTile(
          leading: const Icon(Icons.system_update),
          title: const Text('업데이트 확인'),
          subtitle: _updateStatus == null
              ? null
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_updateStatus!),
                  if (_updating && _updateStatus == '내려받는 중…')
                    LinearProgressIndicator(value: _updateProgress),
                ]),
          enabled: !_updating,
          onTap: _checkUpdate,
        ),
        const Divider(),
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('문제 해결', style: header)),
        ListTile(
          leading: const Icon(Icons.bug_report_outlined),
          title: const Text('API 진단'),
          subtitle: const Text('현재 NAS의 각 API 응답을 확인하고 복사합니다'),
          enabled: app.client != null,
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const DiagnosticsScreen())),
        ),
      ]),
    );
  }
}

/// 각 API의 원본 응답을 보여준다. 기능이 안 될 때 이 내용을 보고 고친다.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final _results = <String, String>{};
  bool _running = false;

  static const _endpoints = <(String, String, Map<String, String>)>[
    ('시스템 정보', '/cgi-bin/management/manaRequest.cgi',
        {'subfunc': 'sysinfo', 'hd': 'no', 'multicpu': '1'}),
    ('볼륨', '/cgi-bin/management/chartReq.cgi',
        {'chart_func': 'disk_usage', 'disk_select': 'all', 'include': 'all'}),
    ('디스크 SMART', '/cgi-bin/disk/qsmart.cgi', {'func': 'all_hd_data'}),
    ('공유 폴더', '/cgi-bin/filemanager/utilRequest.cgi',
        {'func': 'get_tree', 'is_iso': '0', 'node': 'share_root'}),
    ('Download Station', '/downloadstation/V4/Task/Query',
        {'from': '0', 'limit': '5', 'status': 'all', 'type': 'all'}),
  ];

  Future<void> _run() async {
    final c = app.client!;
    setState(() {
      _running = true;
      _results.clear();
    });
    for (final (name, path, q) in _endpoints) {
      try {
        final res = await c.client
            .get(c.uri(path, q), headers: c.cookieHeaders)
            .timeout(const Duration(seconds: 15));
        var body = res.body;
        if (body.length > 3000) body = '${body.substring(0, 3000)}\n…(생략)';
        _results[name] = 'HTTP ${res.statusCode}\n$body';
      } catch (e) {
        _results[name] = '오류: $e';
      }
      if (mounted) setState(() {});
    }
    try {
      _results['Container Station'] = await ContainerApi(c).diagnose();
    } catch (e) {
      _results['Container Station'] = '오류: $e';
    }
    if (mounted) setState(() => _running = false);
  }

  String get _report {
    final sid = app.client?.sid ?? '';
    final b = StringBuffer('QNAP 매니저 진단\n');
    _results.forEach((k, v) => b.write('\n===== $k =====\n$v\n'));
    // 세션 ID는 지운다
    return sid.isEmpty ? b.toString() : b.toString().replaceAll(sid, '<sid>');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('API 진단'), actions: [
        IconButton(
          tooltip: '복사',
          icon: const Icon(Icons.copy),
          onPressed: _results.isEmpty
              ? null
              : () {
                  Clipboard.setData(ClipboardData(text: _report));
                  showMsg(context, '복사했습니다 (세션 ID는 제거됨)');
                },
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _running ? null : _run,
        icon: const Icon(Icons.play_arrow),
        label: Text(_running ? '실행 중…' : '진단 실행'),
      ),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        for (final e in _results.entries)
          Card(
            child: ExpansionTile(
              title: Text(e.key),
              subtitle: Text(e.value.split('\n').first),
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(e.value.replaceAll(app.client?.sid ?? '\u0000', '<sid>'),
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                ),
              ],
            ),
          ),
      ]),
    );
  }
}
