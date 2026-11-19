import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api/container_api.dart';
import '../api/qnap_client.dart';
import '../widgets/common.dart';

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

  @override
  Widget build(BuildContext context) {
    if (_items == null) {
      return _error != null
          ? ErrorView(_error!, onRetry: _load)
          : const Center(child: CircularProgressIndicator());
    }
    final items = _items!;
    final running = items.where((c) => c.running).length;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text('실행 중 $running / 전체 ${items.length}',
              style: Theme.of(context).textTheme.titleSmall),
        ),
        if (items.isEmpty) const Center(child: Text('컨테이너가 없습니다')),
        for (final c in items)
          Card(
            child: ListTile(
              leading: Icon(Icons.circle,
                  size: 14, color: c.running ? Colors.green : Colors.grey),
              title: Text(c.name),
              subtitle: Text('${c.image}\n${c.state}', maxLines: 2),
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
                      if (c.running) ...[
                        IconButton(
                            tooltip: '재시작',
                            icon: const Icon(Icons.restart_alt),
                            onPressed: () => _act(c, 'restart')),
                        IconButton(
                            tooltip: '중지',
                            icon: const Icon(Icons.stop),
                            onPressed: () => _act(c, 'stop')),
                      ],
                    ]),
            ),
          ),
      ]),
    );
  }
}
