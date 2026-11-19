/// 등록된 NAS 한 대의 접속 정보. 비밀번호는 여기 두지 않고 보안 저장소에 따로 보관한다.
class NasProfile {
  NasProfile({
    required this.id,
    required this.name,
    required this.primaryUrl,
    this.secondaryUrl = '',
    required this.username,
    this.allowSelfSigned = true,
  });

  final String id;
  String name;

  /// 먼저 시도할 주소 (예: http://192.168.0.10:8080)
  String primaryUrl;

  /// 첫 주소가 안 될 때 시도할 주소 (예: https://mynas.myqnapcloud.com:8081)
  String secondaryUrl;

  String username;

  /// NAS 기본 인증서(자체 서명)를 허용할지 여부
  bool allowSelfSigned;

  List<String> get urls => [primaryUrl, secondaryUrl]
      .map(normalizeUrl)
      .where((u) => u.isNotEmpty)
      .toList();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'primaryUrl': primaryUrl,
        'secondaryUrl': secondaryUrl,
        'username': username,
        'allowSelfSigned': allowSelfSigned,
      };

  factory NasProfile.fromJson(Map<String, dynamic> j) => NasProfile(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'NAS',
        primaryUrl: j['primaryUrl'] as String? ?? '',
        secondaryUrl: j['secondaryUrl'] as String? ?? '',
        username: j['username'] as String? ?? '',
        allowSelfSigned: j['allowSelfSigned'] as bool? ?? true,
      );
}

/// "192.168.0.10:8080" 처럼 입력해도 "http://192.168.0.10:8080" 으로 맞춘다.
String normalizeUrl(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return '';
  if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'http://$s';
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}
