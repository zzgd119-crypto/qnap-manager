import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api/container_api.dart';
import '../api/qnap_client.dart';
import '../widgets/common.dart';

/// 재생성/이미지 당기기는 앱이 삭제되는 문제가 확인되어 정확한 API 확인 전까지 막아 둔다.
const kRecreateEnabled = false;

class ContainersScreen extends StatefulWidget {
  const ContainersScreen({super.key, required this.client});
  final QnapClient client;

  @override
  State<ContainersScreen> createState() => _ContainersScreenState();
}

class _ContainersScreenState extends State<ContainersScreen> {
  late final api = ContainerApi(widget.client);
  List<ContainerInfo>? _items;
  Object? _error;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await api.list();
      l.sort((a, b) {
        if (a.running != b.running) return a.running ? -1 : 1;
        return a.name.compareTo(b.name);
      });
      _items = l;
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  Future<void> _act(ContainerInfo c, String action) async {
    if (action == 'stop' &&
        !await confirm(context, '컨테이너 중지', '${c.name}을(를) 중지할까요?', ok: '중지')) {
      return;
    }
    setState(() => _busy.add(c.id));
    try {
      await api.action(c, action);
    } catch (e) {
      if (mounted) showMsg(context, '실패: $e');
    }
    _busy.remove(c.id);
    await _load();
  }

  // ---------- 이미지 당기기 / 재생성 ----------

  /// 여러 단계 작업을 진행 상황 창과 함께 실행한다.
  Future<void> _runSteps(String title, List<(String, Future<String?> Function())> steps) async {
    final status = ValueNotifier<(String, double?)>(('준비 중…', null));
    var closed = false;
    unawaited(showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(title),
          content: ValueListenableBuilder(
            valueListenable: status,
            builder: (_, v, _) => Column(mainAxisSize: MainAxisSize.min, children: [
              LinearProgressIndicator(value: v.$2),
              const SizedBox(height: 12),
              Text(v.$1),
            ]),
          ),
        ),
      ),
    ).whenComplete(() => closed = true));

    Object? error;
    try {
      for (final (i, (label, fn)) in steps.indexed) {
        final prefix = steps.length > 1 ? '(${i + 1}/${steps.length}) ' : '';
        status.value = ('$prefix$label', null);
        final task = await fn();
        if (task != null) {
          await api.waitTask(task, onUpdate: (p, text) {
            status.value = (
              '$prefix$label${text.isNotEmpty ? '\n$text' : ''}',
              p > 0 ? p / 100 : null
            );
          });
        }
      }
    } catch (e) {
      error = e;
    }
    if (mounted && !closed) Navigator.of(context, rootNavigator: true).pop();
    if (!mounted) return;
    if (error != null) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('$title 실패'),
          content: SingleChildScrollView(child: SelectableText('$error')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기')),
          ],
        ),
      );
    } else {
      showMsg(context, '$title 완료');
    }
    await _load();
  }

  Future<void> _pull(ContainerInfo c) async {
    if (!kRecreateEnabled) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('일시 중지된 기능'),
          content: const Text('재생성 중 애플리케이션이 삭제되는 문제가 확인되어 '
              '이 기능을 잠시 막아 두었습니다.\n\n'
              '정확한 요청 형식을 확인해 고친 뒤 다시 열겠습니다. '
              '그동안은 Container Station 화면에서 재생성해 주세요.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('확인')),
          ],
        ),
      );
      return;
    }
    if (!await confirm(context, '이미지 당기기',
        '${c.image}\n\n레지스트리에서 이 이미지를 다시 받습니다.\n'
            '실행 중인 컨테이너에 반영하려면 받은 뒤 재생성해야 합니다.',
        ok: '당기기')) {
      return;
    }
    await _runSteps('이미지 당기기', [
      ('${c.image} 받는 중', () => api.pullImage(c.image)),
    ]);
  }

  Future<void> _recreate(String app, List<ContainerInfo> members) async {
    if (!kRecreateEnabled) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('일시 중지된 기능'),
          content: const Text('재생성 중 애플리케이션이 삭제되는 문제가 확인되어 '
              '이 기능을 잠시 막아 두었습니다.\n\n'
              '정확한 요청 형식을 확인해 고친 뒤 다시 열겠습니다. '
              '그동안은 Container Station 화면에서 재생성해 주세요.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('확인')),
          ],
        ),
      );
      return;
    }
    var pull = true;
    final images = members.map((c) => c.image).where((i) => i.isNotEmpty).toSet().toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('$app 재생성'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('현재 설정(yml)으로 애플리케이션의 컨테이너를 다시 만듭니다. '
                '볼륨에 저장된 데이터는 유지되고, 잠깐 서비스가 중단됩니다.'),
            const SizedBox(height: 4),
            Text('이미지: ${images.join(', ')}', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: pull,
              onChanged: (v) => setLocal(() => pull = v ?? false),
              title: const Text('최신 이미지로 재생성'),
              subtitle: const Text(
                  '레지스트리에서 최신 이미지를 받아 재생성합니다. '
                  '이를 위해 yml의 각 서비스에 pull_policy: always 가 추가됩니다.',
                  style: TextStyle(fontSize: 12)),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('재생성')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _runSteps('$app 재생성', [
      (pull ? '최신 이미지 받고 재생성 중' : '$app 재생성 중',
          () => api.recreateApp(app, pullLatest: pull)),
    ]);
  }

  Future<void> _logs(ContainerInfo c) async {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${c.name} 로그'),
        content: SizedBox(
          width: 700,
          height: 500,
          child: FutureBuilder<String>(
            future: api.logs(c),
            builder: (_, snap) {
              if (snap.hasError) return Text('${snap.error}');
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              return SingleChildScrollView(
                reverse: true,
                child: SelectableText(snap.data!,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기')),
        ],
      ),
    );
  }

  // ---------- 화면 ----------

  @override
  Widget build(BuildContext context) {
    if (_items == null) {
      return _error != null
          ? ErrorView(_error!, onRetry: _load)
          : const Center(child: CircularProgressIndicator());
    }
    final items = _items!;
    final running = items.where((c) => c.running).length;

    // 애플리케이션(compose 프로젝트)별로 묶기
    final apps = <String, List<ContainerInfo>>{};
    final singles = <ContainerInfo>[];
    for (final c in items) {
      if (c.project.isNotEmpty) {
        apps.putIfAbsent(c.project, () => []).add(c);
      } else {
        singles.add(c);
      }
    }
    final appNames = apps.keys.toList()..sort();
    final titleStyle = Theme.of(context).textTheme.titleSmall;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text('실행 중 $running / 전체 ${items.length}', style: titleStyle),
        ),
        if (items.isEmpty) const Center(child: Text('컨테이너가 없습니다')),
        for (final app in appNames) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 0, 4),
            child: Row(children: [
              const Icon(Icons.apps, size: 18),
              const SizedBox(width: 6),
              Expanded(child: Text('앱: $app', style: titleStyle)),
              TextButton.icon(
                icon: const Icon(Icons.autorenew, size: 18),
                label: const Text('재생성'),
                onPressed: () => _recreate(app, apps[app]!),
              ),
            ]),
          ),
          for (final c in apps[app]!) _card(c, app: app, members: apps[app]!),
        ],
        if (singles.isNotEmpty && appNames.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
            child: Text('개별 컨테이너', style: titleStyle),
          ),
        for (final c in singles) _card(c),
      ]),
    );
  }

  Widget _card(ContainerInfo c, {String? app, List<ContainerInfo>? members}) {
    return Card(
      child: ListTile(
        leading: Icon(Icons.circle, size: 14, color: c.running ? Colors.green : Colors.grey),
        title: Text(c.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(c.image, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(c.state),
          ],
        ),
        isThreeLine: true,
        onTap: () => _logs(c),
        trailing: _busy.contains(c.id)
            ? const SizedBox(
                width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : Row(mainAxisSize: MainAxisSize.min, children: [
                if (!c.running)
                  IconButton(
                      tooltip: '시작',
                      icon: const Icon(Icons.play_arrow),
                      onPressed: () => _act(c, 'start')),
                if (c.running)
                  IconButton(
                      tooltip: '중지',
                      icon: const Icon(Icons.stop),
                      onPressed: () => _act(c, 'stop')),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    switch (v) {
                      case 'restart':
                        _act(c, 'restart');
                      case 'logs':
                        _logs(c);
                      case 'pull':
                        // 앱 소속이면 "최신 이미지로 재생성"이 확실한 방법
                        app != null ? _recreate(app, members!) : _pull(c);
                      case 'recreate':
                        _recreate(app!, members!);
                    }
                  },
                  itemBuilder: (_) => [
                    if (c.running)
                      const PopupMenuItem(
                          value: 'restart',
                          child: ListTile(leading: Icon(Icons.restart_alt), title: Text('재시작'))),
                    const PopupMenuItem(
                        value: 'logs',
                        child: ListTile(leading: Icon(Icons.article_outlined), title: Text('로그'))),
                    const PopupMenuItem(
                        value: 'pull',
                        child: ListTile(
                            leading: Icon(Icons.cloud_download_outlined),
                            title: Text('이미지 당기기 (최신 버전으로)'))),
                    if (app != null)
                      PopupMenuItem(
                          value: 'recreate',
                          child: ListTile(
                              leading: const Icon(Icons.autorenew),
                              title: Text('앱 재생성 ($app)'))),
                  ],
                ),
              ]),
      ),
    );
  }
}
