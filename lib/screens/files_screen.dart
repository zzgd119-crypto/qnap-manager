import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../api/file_station.dart';
import '../api/qnap_client.dart';
import '../widgets/common.dart';

class _Transfer {
  _Transfer(this.label, this.upload);
  final String label;
  final bool upload;
  double? progress;
  String? error;
  bool done = false;
}

Future<Directory> localDownloadDir() async {
  if (Platform.isAndroid) {
    return Directory('/storage/emulated/0/Download/QnapManager');
  }
  final d = await getDownloadsDirectory();
  return d ?? await getApplicationDocumentsDirectory();
}

class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key, required this.client});
  final QnapClient client;

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  late final fs = FileStation(widget.client);
  String _path = ''; // '' = 공유 폴더 목록
  List<NasFile>? _files;
  Object? _error;
  final Set<String> _selected = {};
  final List<_Transfer> _transfers = [];
  String _filter = '';

  bool get _atRoot => _path.isEmpty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _files = null;
      _error = null;
      _selected.clear();
    });
    try {
      final f = _atRoot ? await fs.shares() : await fs.list(_path);
      if (mounted) setState(() => _files = f);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _open(String path) {
    _path = path;
    _filter = '';
    _load();
  }

  String _child(String name) => _atRoot ? '/$name' : '$_path/$name';

  void _up() {
    final i = _path.lastIndexOf('/');
    _open(i <= 0 ? '' : _path.substring(0, i));
  }

  Future<void> _run(Future<void> Function() fn, String okMsg) async {
    try {
      await fn();
      if (mounted) showMsg(context, okMsg);
    } catch (e) {
      if (mounted) showMsg(context, '실패: $e');
    }
    await _load();
  }

  List<NasFile> get _selectedFiles =>
      (_files ?? []).where((f) => _selected.contains(f.name)).toList();

  // ---------- 작업들 ----------

  Future<void> _download(List<NasFile> files) async {
    final dir = await localDownloadDir();
    for (final f in files) {
      final t = _Transfer(f.isDir ? '${f.name}.zip' : f.name, false);
      setState(() => _transfers.add(t));
      try {
        final out = await fs.download(_path, f, dir, onProgress: (d, total) {
          if (!mounted) return;
          setState(() => t.progress = total > 0 ? d / total : null);
        });
        t.done = true;
        if (mounted) {
          showMsg(context, '저장됨: ${out.path}',
              action: SnackBarAction(
                  label: '열기', onPressed: () => OpenFilex.open(out.path)));
        }
      } catch (e) {
        t.error = '$e';
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> _upload() async {
    final picked = await FilePicker.pickFiles(dialogTitle: '업로드할 파일 선택');
    if (picked.isEmpty) return;
    final dest = _path;
    for (final pf in picked) {
      if (pf.path == null) continue;
      final t = _Transfer(pf.name, true);
      setState(() => _transfers.add(t));
      try {
        await fs.upload(File(pf.path!), dest, onProgress: (d, total) {
          if (!mounted) return;
          setState(() => t.progress = total > 0 ? d / total : null);
        });
        t.done = true;
      } catch (e) {
        t.error = '$e';
      }
      if (mounted) setState(() {});
    }
    if (_path == dest) await _load();
  }

  Future<void> _newFolder() async {
    final name = await promptText(context, '새 폴더', hint: '폴더 이름');
    if (name == null || name.isEmpty) return;
    await _run(() => fs.createFolder(_path, name), '폴더를 만들었습니다');
  }

  Future<void> _rename(NasFile f) async {
    final name = await promptText(context, '이름 변경', initial: f.name);
    if (name == null || name.isEmpty || name == f.name) return;
    await _run(() => fs.rename(_path, f.name, name), '이름을 변경했습니다');
  }

  Future<void> _delete(List<NasFile> files) async {
    final ok = await confirm(context, '삭제',
        '${files.length == 1 ? files.first.name : '${files.length}개 항목'}을(를) 삭제할까요?\n(휴지통 설정에 따라 @Recycle로 이동)',
        ok: '삭제', danger: true);
    if (!ok) return;
    await _run(() => fs.delete(_path, files.map((f) => f.name).toList()),
        '삭제했습니다');
  }

  Future<void> _copyMove(List<NasFile> files, bool move) async {
    final dest = await showDialog<String>(
      context: context,
      builder: (_) => _FolderPicker(fs: fs, title: move ? '이동할 위치' : '복사할 위치'),
    );
    if (dest == null || dest == _path) return;
    final names = files.map((f) => f.name).toList();
    await _run(
        () => move ? fs.move(_path, names, dest) : fs.copy(_path, names, dest),
        move ? '이동했습니다' : '복사했습니다');
  }

  void _menu(NasFile f) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        Widget item(IconData i, String t, VoidCallback fn) => ListTile(
            leading: Icon(i),
            title: Text(t),
            onTap: () {
              Navigator.pop(ctx);
              fn();
            });
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(title: Text(f.name, style: const TextStyle(fontWeight: FontWeight.bold))),
            item(Icons.download, f.isDir ? '압축해서 다운로드' : '다운로드',
                () => _download([f])),
            item(Icons.drive_file_rename_outline, '이름 변경', () => _rename(f)),
            item(Icons.drive_file_move_outline, '이동', () => _copyMove([f], true)),
            item(Icons.copy, '복사', () => _copyMove([f], false)),
            item(Icons.delete_outline, '삭제', () => _delete([f])),
          ]),
        );
      },
    );
  }

  // ---------- 화면 ----------

  @override
  Widget build(BuildContext context) {
    final selecting = _selected.isNotEmpty;
    return PopScope(
      canPop: _atRoot && !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (selecting) {
          setState(_selected.clear);
        } else {
          _up();
        }
      },
      child: Scaffold(
        body: Column(children: [
          _toolbar(selecting),
          const Divider(height: 1),
          Expanded(child: _list()),
          if (_transfers.isNotEmpty) _transferPanel(),
        ]),
        floatingActionButton: _atRoot || selecting
            ? null
            : FloatingActionButton(
                onPressed: () => showModalBottomSheet(
                  context: context,
                  showDragHandle: true,
                  builder: (ctx) => SafeArea(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      ListTile(
                          leading: const Icon(Icons.upload_file),
                          title: const Text('파일 업로드'),
                          onTap: () {
                            Navigator.pop(ctx);
                            _upload();
                          }),
                      ListTile(
                          leading: const Icon(Icons.create_new_folder_outlined),
                          title: const Text('새 폴더'),
                          onTap: () {
                            Navigator.pop(ctx);
                            _newFolder();
                          }),
                    ]),
                  ),
                ),
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  Widget _toolbar(bool selecting) {
    if (selecting) {
      final files = _selectedFiles;
      return Material(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Row(children: [
          IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear)),
          Text('${_selected.length}개 선택'),
          const Spacer(),
          IconButton(tooltip: '다운로드', icon: const Icon(Icons.download), onPressed: () => _download(files)),
          IconButton(tooltip: '이동', icon: const Icon(Icons.drive_file_move_outline), onPressed: () => _copyMove(files, true)),
          IconButton(tooltip: '복사', icon: const Icon(Icons.copy), onPressed: () => _copyMove(files, false)),
          IconButton(tooltip: '삭제', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(files)),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(children: [
        IconButton(
            tooltip: '상위 폴더',
            icon: const Icon(Icons.arrow_upward),
            onPressed: _atRoot ? null : _up),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Text(_atRoot ? '공유 폴더' : _path,
                style: Theme.of(context).textTheme.titleSmall),
          ),
        ),
        SizedBox(
          width: 160,
          child: TextField(
            decoration: const InputDecoration(
                isDense: true, prefixIcon: Icon(Icons.search, size: 18), hintText: '이 폴더에서 찾기'),
            onChanged: (v) => setState(() => _filter = v.toLowerCase()),
          ),
        ),
        IconButton(tooltip: '새로고침', icon: const Icon(Icons.refresh), onPressed: _load),
      ]),
    );
  }

  Widget _list() {
    if (_error != null) return ErrorView(_error!, onRetry: _load);
    final files = _files;
    if (files == null) return const Center(child: CircularProgressIndicator());
    final shown = _filter.isEmpty
        ? files
        : files.where((f) => f.name.toLowerCase().contains(_filter)).toList();
    if (shown.isEmpty) return const Center(child: Text('비어 있습니다'));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: shown.length,
        itemBuilder: (_, i) {
          final f = shown[i];
          final sel = _selected.contains(f.name);
          return ListTile(
            selected: sel,
            leading: Icon(
              _atRoot ? Icons.folder_shared : f.isDir ? Icons.folder : _iconFor(f.name),
              color: f.isDir ? Colors.amber.shade700 : null,
            ),
            title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: _atRoot
                ? null
                : Text([
                    if (!f.isDir) fmtBytes(f.size),
                    fmtDate(f.modified),
                  ].join('  ·  ')),
            trailing: _atRoot
                ? null
                : _selected.isNotEmpty
                    ? Checkbox(value: sel, onChanged: (_) => _toggle(f))
                    : IconButton(icon: const Icon(Icons.more_vert), onPressed: () => _menu(f)),
            onTap: () {
              if (_selected.isNotEmpty && !_atRoot) {
                _toggle(f);
              } else if (f.isDir) {
                _open(_child(f.name));
              } else {
                _menu(f);
              }
            },
            onLongPress: _atRoot ? null : () => _toggle(f),
          );
        },
      ),
    );
  }

  void _toggle(NasFile f) => setState(() {
        if (!_selected.remove(f.name)) _selected.add(f.name);
      });

  Widget _transferPanel() {
    final active = _transfers.where((t) => !t.done && t.error == null).length;
    return Material(
      elevation: 4,
      child: ExpansionTile(
        dense: true,
        title: Text(active > 0 ? '전송 중 $active개' : '전송 ${_transfers.length}개 완료'),
        trailing: active == 0
            ? IconButton(icon: const Icon(Icons.clear_all), onPressed: () => setState(_transfers.clear))
            : null,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: ListView(shrinkWrap: true, children: [
              for (final t in _transfers.reversed)
                ListTile(
                  dense: true,
                  leading: Icon(t.upload ? Icons.upload : Icons.download),
                  title: Text(t.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: t.error != null
                      ? Text(t.error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
                      : t.done
                          ? const Text('완료')
                          : LinearProgressIndicator(value: t.progress),
                ),
            ]),
          ),
        ],
      ),
    );
  }

  static IconData _iconFor(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' || 'png' || 'gif' || 'heic' || 'webp' || 'bmp' => Icons.image_outlined,
      'mp4' || 'mkv' || 'avi' || 'mov' || 'wmv' || 'ts' => Icons.movie_outlined,
      'mp3' || 'flac' || 'wav' || 'aac' || 'm4a' => Icons.music_note_outlined,
      'zip' || '7z' || 'rar' || 'tar' || 'gz' => Icons.archive_outlined,
      'pdf' => Icons.picture_as_pdf_outlined,
      'doc' || 'docx' || 'hwp' || 'txt' || 'md' => Icons.description_outlined,
      'xls' || 'xlsx' || 'csv' => Icons.table_chart_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }
}

/// 이동/복사 대상 폴더 고르기
class _FolderPicker extends StatefulWidget {
  const _FolderPicker({required this.fs, required this.title});
  final FileStation fs;
  final String title;

  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  String _path = '';
  List<NasFile>? _dirs;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _dirs = null;
      _error = null;
    });
    try {
      final l = _path.isEmpty ? await widget.fs.shares() : await widget.fs.list(_path);
      if (mounted) setState(() => _dirs = l.where((f) => f.isDir).toList());
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        height: 400,
        child: Column(children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.arrow_upward),
            title: Text(_path.isEmpty ? '공유 폴더' : _path),
            enabled: _path.isNotEmpty,
            onTap: () {
              final i = _path.lastIndexOf('/');
              _path = i <= 0 ? '' : _path.substring(0, i);
              _load();
            },
          ),
          const Divider(height: 1),
          Expanded(
            child: _error != null
                ? ErrorView(_error!, onRetry: _load)
                : _dirs == null
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(children: [
                        for (final d in _dirs!)
                          ListTile(
                            leading: const Icon(Icons.folder),
                            title: Text(d.name),
                            onTap: () {
                              _path = _path.isEmpty ? '/${d.name}' : '$_path/${d.name}';
                              _load();
                            },
                          ),
                      ]),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
        FilledButton(
          onPressed: _path.isEmpty ? null : () => Navigator.pop(context, _path),
          child: const Text('여기로'),
        ),
      ],
    );
  }
}
