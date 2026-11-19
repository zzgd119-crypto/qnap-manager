import 'package:xml/xml.dart';

import 'qnap_client.dart';

class NetInterface {
  NetInterface(this.name, this.rxBytes, this.txBytes, this.ip, this.up);
  final String name;
  final int rxBytes;
  final int txBytes;
  final String ip;
  final bool up;
}

class SystemStats {
  SystemStats({
    required this.cpuPercent,
    required this.memTotalMb,
    required this.memFreeMb,
    this.cpuTemp,
    this.sysTemp,
    required this.uptime,
    required this.model,
    required this.nets,
  });
  final double cpuPercent;
  final double memTotalMb;
  final double memFreeMb;
  final int? cpuTemp;
  final int? sysTemp;
  final String uptime;
  final String model;
  final List<NetInterface> nets;

  double get memUsedPercent =>
      memTotalMb <= 0 ? 0 : (memTotalMb - memFreeMb) / memTotalMb * 100;
}

class VolumeInfo {
  VolumeInfo(this.label, this.totalBytes, this.freeBytes, this.status);
  final String label;
  final int totalBytes;
  final int freeBytes;
  final String status;
  double get usedPercent =>
      totalBytes <= 0 ? 0 : (totalBytes - freeBytes) / totalBytes * 100;
}

class DiskInfo {
  DiskInfo(this.alias, this.model, this.health, this.tempC, this.capacity);
  final String alias;
  final String model;
  final String health;
  final int? tempC;
  final String capacity;
  bool get isGood => health.toLowerCase().contains('good') || health == '정상';
}

double _num(String? s) {
  if (s == null) return 0;
  final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(s);
  return m == null ? 0 : double.parse(m.group(0)!);
}

int? _intOrNull(String? s) {
  if (s == null || s.isEmpty) return null;
  final v = _num(s);
  return v == 0 ? null : v.round();
}

class SystemApi {
  SystemApi(this.c);
  final QnapClient c;

  static const _sysinfo = '/cgi-bin/management/manaRequest.cgi';

  Future<SystemStats> stats() => c.authed(() async {
        final doc = await c.getXml(_sysinfo,
            {'subfunc': 'sysinfo', 'hd': 'no', 'multicpu': '1'});
        return parseStats(doc);
      });

  static SystemStats parseStats(XmlDocument doc) {
    String? t(String tag) => xmlText(doc, tag);
    final ethCount = _num(t('eth_count')).round();
    final nets = <NetInterface>[];
    for (var i = 1; i <= (ethCount == 0 ? 1 : ethCount); i++) {
      final rx = t('rx_packet$i');
      if (rx == null) continue;
      nets.add(NetInterface(
        t('ifindex$i') ?? t('dname$i') ?? 'eth${i - 1}',
        _num(rx).round(),
        _num(t('tx_packet$i')).round(),
        t('eth_ip$i') ?? '',
        (t('eth_status$i') ?? '1') != '0',
      ));
    }
    final d = _num(t('uptime_day')).round();
    final h = _num(t('uptime_hour')).round();
    final m = _num(t('uptime_min')).round();
    final modelEl = doc.findAllElements('displayModelName').firstOrNull ??
        doc.findAllElements('modelName').firstOrNull;
    return SystemStats(
      cpuPercent: _num(t('cpu_usage')),
      memTotalMb: _num(t('total_memory')),
      memFreeMb: _num(t('free_memory')),
      cpuTemp: _intOrNull(t('cpu_tempc')),
      sysTemp: _intOrNull(t('sys_tempc')),
      uptime: '$d일 $h시간 $m분',
      model: modelEl?.innerText.trim() ?? '',
      nets: nets,
    );
  }

  Future<List<VolumeInfo>> volumes() => c.authed(() async {
        final doc = await c.getXml('/cgi-bin/management/chartReq.cgi', {
          'chart_func': 'disk_usage',
          'disk_select': 'all',
          'include': 'all',
        });
        return parseVolumes(doc);
      });

  static List<VolumeInfo> parseVolumes(XmlDocument doc) {
    final usage = <String, XmlElement>{};
    for (final u in doc.findAllElements('volumeUse')) {
      final v = xmlText(u, 'volumeValue');
      if (v != null) usage[v] = u;
    }
    final out = <VolumeInfo>[];
    for (final v in doc.findAllElements('volume')) {
      final id = xmlText(v, 'volumeValue');
      final u = usage[id];
      if (u == null) continue;
      out.add(VolumeInfo(
        xmlText(v, 'volumeLabel') ?? 'Volume $id',
        _num(xmlText(u, 'total_size')).round(),
        _num(xmlText(u, 'free_size')).round(),
        xmlText(v, 'volumeStatus') ?? xmlText(v, 'volumeStat') ?? '',
      ));
    }
    return out;
  }

  Future<List<DiskInfo>> disks() => c.authed(() async {
        final doc =
            await c.getXml('/cgi-bin/disk/qsmart.cgi', {'func': 'all_hd_data'});
        return parseDisks(doc);
      });

  static List<DiskInfo> parseDisks(XmlDocument doc) {
    final out = <DiskInfo>[];
    for (final e in doc.findAllElements('entry')) {
      final alias = xmlText(e, 'Disk_Alias');
      if (alias == null) continue;
      final tempEl = e.findAllElements('Temperature').firstOrNull;
      out.add(DiskInfo(
        alias,
        xmlText(e, 'Model') ?? '',
        xmlText(e, 'Health') ?? '',
        tempEl == null
            ? null
            : _intOrNull(xmlText(tempEl, 'oC') ?? tempEl.innerText),
        xmlText(e, 'Capacity') ?? '',
      ));
    }
    return out;
  }
}
