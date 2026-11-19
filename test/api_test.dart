import 'package:flutter_test/flutter_test.dart';
import 'package:qnap_manager/api/container_api.dart';
import 'package:qnap_manager/api/qnap_client.dart';
import 'package:qnap_manager/api/system_api.dart';
import 'package:qnap_manager/models/nas_profile.dart';
import 'package:qnap_manager/update/updater.dart';
import 'package:xml/xml.dart';

void main() {
  test('ezEncode는 UTF-8 Base64', () {
    expect(ezEncode('admin'), 'YWRtaW4=');
    expect(ezEncode('비번1'), '67mE67KIMQ==');
  });

  test('주소 정규화', () {
    expect(normalizeUrl('192.168.0.10:8080/'), 'http://192.168.0.10:8080');
    expect(normalizeUrl(' https://a.b:443 '), 'https://a.b:443');
    expect(normalizeUrl(''), '');
    final p = NasProfile(
        id: '1', name: 'n', primaryUrl: '10.0.0.2', secondaryUrl: '', username: 'u');
    expect(p.urls, ['http://10.0.0.2']);
  });

  test('버전 비교', () {
    expect(compareVersions('1.0.12', '1.0.9'), greaterThan(0));
    expect(compareVersions('1.0.0', '1.0.0'), 0);
    expect(compareVersions('1.0.3', '1.1.0'), lessThan(0));
    expect(compareVersions('1.0.3+5', '1.0.3'), 0);
  });

  test('시스템 정보 XML 파싱', () {
    final doc = XmlDocument.parse('''
<QDocRoot version="1.0"><authPassed><![CDATA[1]]></authPassed>
<func><ownContent><root>
<cpu_usage><![CDATA[12.5 %]]></cpu_usage>
<total_memory><![CDATA[7859.6]]></total_memory>
<free_memory><![CDATA[3929.8]]></free_memory>
<cpu_tempc>48</cpu_tempc><sys_tempc>36</sys_tempc>
<uptime_day>3</uptime_day><uptime_hour>4</uptime_hour><uptime_min>5</uptime_min>
<eth_count>2</eth_count>
<ifindex1>Adapter 1</ifindex1><rx_packet1>1000</rx_packet1><tx_packet1>2000</tx_packet1><eth_ip1>192.168.0.10</eth_ip1><eth_status1>1</eth_status1>
<ifindex2>Adapter 2</ifindex2><rx_packet2>0</rx_packet2><tx_packet2>0</tx_packet2><eth_status2>0</eth_status2>
</root></ownContent></func>
<model><displayModelName><![CDATA[TS-453Be]]></displayModelName></model>
</QDocRoot>''');
    final s = SystemApi.parseStats(doc);
    expect(s.cpuPercent, 12.5);
    expect(s.memUsedPercent, closeTo(50, 0.1));
    expect(s.cpuTemp, 48);
    expect(s.uptime, '3일 4시간 5분');
    expect(s.model, 'TS-453Be');
    expect(s.nets.length, 2);
    expect(s.nets.first.ip, '192.168.0.10');
    expect(s.nets.last.up, false);
  });

  test('볼륨 XML 파싱', () {
    final doc = XmlDocument.parse('''
<QDocRoot><volumeList>
<volume><volumeLabel>DataVol1</volumeLabel><volumeValue>1</volumeValue><volumeStatus>Ready</volumeStatus></volume>
</volumeList>
<volumeUseList><volumeUse><volumeValue>1</volumeValue><total_size>1000</total_size><free_size>250</free_size></volumeUse></volumeUseList>
</QDocRoot>''');
    final v = SystemApi.parseVolumes(doc);
    expect(v.single.label, 'DataVol1');
    expect(v.single.usedPercent, 75);
  });

  test('컨테이너 목록 파싱 (여러 형식)', () {
    final a = ContainerApi.parseList([
      {'id': 'abc', 'name': 'plex', 'image': 'plex:latest', 'state': 'running', 'type': 'docker'}
    ]);
    expect(a.single.running, true);
    final b = ContainerApi.parseList({
      'data': [
        {'Id': 'x', 'Names': '/nginx', 'Image': 'nginx', 'State': 'exited'}
      ]
    });
    expect(b.single.name, 'nginx');
    expect(b.single.type, 'docker');
    expect(b.single.running, false);
  });
}
