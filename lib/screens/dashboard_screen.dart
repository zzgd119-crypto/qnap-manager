import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api/qnap_client.dart';
import '../api/system_api.dart';
import '../widgets/common.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.client});
  final QnapClient client;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final api = SystemApi(widget.client);
  SystemStats? _stats;
  List<VolumeInfo>? _volumes;
  List<DiskInfo>? _disks;
  Object? _error;
  Timer? _timer;
  int _tick = 0;

  // 네트워크 속도 계산용 이전 값
  Map<String, (int, int)> _prevNet = {};
  DateTime? _prevTime;
  Map<String, (double, double)> _rates = {};

  @override
  void initState() {
    super.initState();
    _refresh(full: true);
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      _tick++;
      _refresh(full: _tick % 12 == 0); // 디스크·볼륨은 1분마다
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool full = false}) async {
    try {
      final s = await api.stats();
      _updateRates(s);
      _stats = s;
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (full) {
      // 실패해도 다른 정보는 보여준다
      await Future.wait([
        api.volumes().then((v) => _volumes = v).catchError((_) => _volumes ??= []),
        api.disks().then((d) => _disks = d).catchError((_) => _disks ??= []),
      ]);
    }
    if (mounted) setState(() {});
  }

  void _updateRates(SystemStats s) {
    final now = DateTime.now();
    if (_prevTime != null) {
      final sec = now.difference(_prevTime!).inMilliseconds / 1000;
      final rates = <String, (double, double)>{};
      for (final n in s.nets) {
        final prev = _prevNet[n.name];
        if (prev != null && sec > 0) {
          rates[n.name] = (
            ((n.rxBytes - prev.$1) / sec).clamp(0, double.infinity).toDouble(),
            ((n.txBytes - prev.$2) / sec).clamp(0, double.infinity).toDouble(),
          );
        }
      }
      _rates = rates;
    }
    _prevNet = {for (final n in s.nets) n.name: (n.rxBytes, n.txBytes)};
    _prevTime = now;
  }

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    if (s == null) {
      return _error != null
          ? ErrorView(_error!, onRetry: () => _refresh(full: true))
          : const Center(child: CircularProgressIndicator());
    }
    final cards = <Widget>[
      _card('시스템', Icons.memory, [
        if (s.model.isNotEmpty) _row('모델', s.model),
        _row('가동 시간', s.uptime),
        if (s.cpuTemp != null) _row('CPU 온도', '${s.cpuTemp}°C'),
        if (s.sysTemp != null) _row('시스템 온도', '${s.sysTemp}°C'),
      ]),
      _card('CPU', Icons.speed, [
        _big('${s.cpuPercent.toStringAsFixed(1)}%'),
        UsageBar(s.cpuPercent),
      ]),
      _card('메모리', Icons.sd_storage_outlined, [
        _big('${s.memUsedPercent.toStringAsFixed(0)}%'),
        UsageBar(s.memUsedPercent),
        const SizedBox(height: 6),
        Text(
            '${fmtBytes((s.memTotalMb - s.memFreeMb) * 1024 * 1024)} / ${fmtBytes(s.memTotalMb * 1024 * 1024)}'),
      ]),
      _card('네트워크', Icons.lan_outlined, [
        for (final n in s.nets.where((n) => n.up))
          _row(
            '${n.name}${n.ip.isNotEmpty ? ' (${n.ip})' : ''}',
            _rates[n.name] == null
                ? '측정 중…'
                : '↓ ${fmtRate(_rates[n.name]!.$1)}  ↑ ${fmtRate(_rates[n.name]!.$2)}',
          ),
      ]),
      _card('볼륨', Icons.storage, [
        if (_volumes == null) const LinearProgressIndicator(),
        if (_volumes?.isEmpty ?? false) const Text('정보를 가져오지 못했습니다'),
        for (final v in _volumes ?? <VolumeInfo>[]) ...[
          _row(v.label,
              '${fmtBytes(v.totalBytes - v.freeBytes)} / ${fmtBytes(v.totalBytes)}'),
          UsageBar(v.usedPercent),
          const SizedBox(height: 10),
        ],
      ]),
      _card('디스크', Icons.album_outlined, [
        if (_disks == null) const LinearProgressIndicator(),
        if (_disks?.isEmpty ?? false) const Text('정보를 가져오지 못했습니다'),
        for (final d in _disks ?? <DiskInfo>[])
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: switch (d.level) {
              0 => const Icon(Icons.check_circle, color: Colors.green),
              1 => const Icon(Icons.warning_amber, color: Colors.orange),
              2 => const Icon(Icons.error, color: Colors.red),
              _ => const Icon(Icons.help_outline, color: Colors.grey),
            },
            title: Text('${d.alias}  ${d.model}'),
            subtitle: Text(
                '${d.health}${d.tempC != null ? ' · ${d.tempC}°C' : ''}${d.capacity.isNotEmpty ? ' · ${d.capacity}' : ''}'),
          ),
      ]),
    ];

    return RefreshIndicator(
      onRefresh: () => _refresh(full: true),
      child: LayoutBuilder(builder: (context, box) {
        final cols = box.maxWidth >= 1100 ? 3 : box.maxWidth >= 700 ? 2 : 1;
        final w = (box.maxWidth - 16 * (cols + 1)) / cols;
        return ListView(padding: const EdgeInsets.all(16), children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('갱신 실패: $_error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [for (final c in cards) SizedBox(width: w, child: c)],
          ),
        ]);
      }),
    );
  }

  Widget _card(String title, IconData icon, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, size: 20),
                const SizedBox(width: 8),
                Text(title, style: Theme.of(context).textTheme.titleMedium),
              ]),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      );

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(k, overflow: TextOverflow.ellipsis)),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _big(String v) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(v, style: Theme.of(context).textTheme.headlineMedium),
      );
}
