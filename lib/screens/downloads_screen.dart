import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api/download_api.dart';
import '../api/qnap_client.dart';
import '../app_state.dart';
import '../widgets/common.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key, required this.client});
  final QnapClient client;

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  late final api = DownloadApi(widget.client);
  List<DownloadTask>? _tasks;
  Object? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      _tasks = await api.tasks();
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  Future<void> _act(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      if (mounted) showMsg(context, '실패: $e');
    }
    await _load();
  }

  Future<void> _add() async {
    final key = 'ds_dirs_${widget.client.profile.id}';
    final saved = (await app.store.getString(key))?.split('|');
    if (!mounted) return;
    final url = TextEditingController();
    final temp = TextEditingController(text: saved?.first ?? 'Download');
    final move = TextEditingController(text: saved?.last ?? 'Download');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('다운로드 추가'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: url,
            autofocus: true,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'URL / 마그넷 링크'),
          ),
          TextField(
            controller: temp,
            decoration: const InputDecoration(labelText: '임시 폴더 (공유 폴더 기준)'),
          ),
          TextField(
            controller: move,
            decoration: const InputDecoration(labelText: '완료 후 이동할 폴더'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('추가')),
        ],
      ),
    );
    if (ok != true || url.text.trim().isEmpty) return;
    await app.store.setString(key, '${temp.text.trim()}|${move.text.trim()}');
    await _act(() => api.addUrl(url.text.trim(), temp.text.trim(), move.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _tasks;
    Widget body;
    if (tasks == null) {
      body = _error != null
          ? ErrorView(_error!, onRetry: _load)
          : const Center(child: CircularProgressIndicator());
    } else if (tasks.isEmpty) {
      body = const Center(child: Text('다운로드 작업이 없습니다'));
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(12), children: [
          for (final t in tasks)
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Text(t.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    if (!t.done && !t.active)
                      IconButton(
                          tooltip: '시작',
                          icon: const Icon(Icons.play_arrow),
                          onPressed: () => _act(() => api.start(t.hash))),
                    if (t.active)
                      IconButton(
                          tooltip: '정지',
                          icon: const Icon(Icons.pause),
                          onPressed: () => _act(() => api.stop(t.hash))),
                    IconButton(
                      tooltip: '목록에서 삭제',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        if (await confirm(context, '작업 삭제',
                            '목록에서 지울까요? (받은 파일은 남습니다)', ok: '삭제')) {
                          await _act(() => api.remove(t.hash));
                        }
                      },
                    ),
                  ]),
                  const SizedBox(height: 4),
                  UsageBar(t.progress),
                  const SizedBox(height: 6),
                  Text([
                    t.stateLabel,
                    '${t.progress.toStringAsFixed(1)}%',
                    if (t.size > 0) fmtBytes(t.size),
                    if (t.active) '↓ ${fmtRate(t.downRate)}  ↑ ${fmtRate(t.upRate)}',
                  ].join('  ·  ')),
                ]),
              ),
            ),
        ]),
      );
    }
    return Scaffold(
      body: body,
      floatingActionButton: FloatingActionButton(
        tooltip: '다운로드 추가',
        onPressed: _add,
        child: const Icon(Icons.add_link),
      ),
    );
  }
}
