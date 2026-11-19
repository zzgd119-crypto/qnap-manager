import 'package:material_ui/material_ui.dart';

import '../api/qnap_client.dart';
import '../app_state.dart';
import '../update/updater.dart';
import '../widgets/common.dart';
import 'containers_screen.dart';
import 'dashboard_screen.dart';
import 'downloads_screen.dart';
import 'files_screen.dart';
import 'nas_edit_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  bool _askingOtp = false;
  bool _initialConnectDone = false;

  static const _tabs = [
    (Icons.dashboard_outlined, Icons.dashboard, '대시보드'),
    (Icons.folder_outlined, Icons.folder, '파일'),
    (Icons.view_in_ar_outlined, Icons.view_in_ar, 'Docker'),
    (Icons.download_outlined, Icons.download, '다운로드'),
  ];

  @override
  void initState() {
    super.initState();
    app.addListener(_onApp);
    _checkUpdateSilently();
  }

  @override
  void dispose() {
    app.removeListener(_onApp);
    super.dispose();
  }

  void _onApp() {
    // 앱 시작 직후 마지막으로 쓰던 NAS에 자동 접속
    if (!_initialConnectDone && app.currentId != null && app.client == null && !app.connecting) {
      _initialConnectDone = true;
      app.select(app.currentId!);
    }
    if (app.error is TwoFactorRequired && !_askingOtp) _askOtp();
    if (mounted) setState(() {});
  }

  Future<void> _askOtp() async {
    _askingOtp = true;
    final code = await promptText(context, '2단계 인증',
        hint: '인증 앱의 6자리 코드', ok: '로그인');
    _askingOtp = false;
    if (code != null && code.isNotEmpty && app.currentId != null) {
      await app.select(app.currentId!, otp: code);
    }
  }

  Future<void> _checkUpdateSilently() async {
    final token = await app.store.githubToken();
    if (token == null || token.isEmpty || kGithubRepo.isEmpty) return;
    try {
      final info = await Updater(token).check();
      if (info != null && mounted) {
        showMsg(context, '새 버전 ${info.version}이 있습니다',
            action: SnackBarAction(
                label: '업데이트',
                onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const SettingsScreen(autoUpdate: true)))));
      }
    } catch (_) {
      // 조용히 무시 (설정 화면에서 수동 확인 가능)
    }
  }

  Widget _nasPicker() {
    if (app.profiles.isEmpty) return const Text('QNAP 매니저');
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: app.currentId,
        borderRadius: BorderRadius.circular(12),
        items: [
          for (final p in app.profiles)
            DropdownMenuItem(
              value: p.id,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.storage, size: 18),
                const SizedBox(width: 8),
                Text(p.name),
              ]),
            ),
        ],
        onChanged: (id) {
          if (id != null) app.select(id);
        },
      ),
    );
  }

  Widget _body() {
    if (app.profiles.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.dns_outlined, size: 56),
          const SizedBox(height: 16),
          const Text('등록된 NAS가 없습니다'),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('NAS 추가'),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const NasEditScreen())),
          ),
        ]),
      );
    }
    if (app.connecting) {
      return const Center(child: CircularProgressIndicator());
    }
    final c = app.client;
    if (c == null || app.error != null) {
      return ErrorView(app.error ?? '연결되지 않았습니다',
          onRetry: () => app.select(app.currentId!, force: true));
    }
    final key = ValueKey('${app.currentId}-${c.sid}');
    return switch (_tab) {
      0 => DashboardScreen(key: key, client: c),
      1 => FilesScreen(key: key, client: c),
      2 => ContainersScreen(key: key, client: c),
      _ => DownloadsScreen(key: key, client: c),
    };
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final appBar = AppBar(
      title: _nasPicker(),
      actions: [
        if (app.client != null)
          IconButton(
            tooltip: '다시 연결',
            icon: const Icon(Icons.sync),
            onPressed: () => app.select(app.currentId!, force: true),
          ),
        IconButton(
          tooltip: '설정',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const SettingsScreen())),
        ),
      ],
    );
    if (wide) {
      return Scaffold(
        appBar: appBar,
        body: Row(children: [
          NavigationRail(
            selectedIndex: _tab,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              for (final t in _tabs)
                NavigationRailDestination(
                    icon: Icon(t.$1), selectedIcon: Icon(t.$2), label: Text(t.$3)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _body()),
        ]),
      );
    }
    return Scaffold(
      appBar: appBar,
      body: _body(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          for (final t in _tabs)
            NavigationDestination(
                icon: Icon(t.$1), selectedIcon: Icon(t.$2), label: t.$3),
        ],
      ),
    );
  }
}
