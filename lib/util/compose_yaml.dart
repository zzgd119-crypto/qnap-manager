/// docker-compose yml 의 모든 서비스에 `pull_policy: always` 를 넣는다.
/// 재생성할 때 Docker Compose 가 레지스트리에서 최신 이미지를 받게 된다.
/// 주석·순서·서식은 그대로 두고 필요한 줄만 추가/수정한다.
String ensurePullAlways(String yml) {
  final lines = yml.split('\n');
  int indentOf(String l) => l.length - l.trimLeft().length;
  bool isContent(String l) =>
      l.trim().isNotEmpty && !l.trimLeft().startsWith('#');

  final svcIdx = lines.indexWhere((l) => RegExp(r'^services:\s*(#.*)?$').hasMatch(l));
  if (svcIdx < 0) {
    throw const FormatException('yml에서 services: 항목을 찾지 못했습니다');
  }

  // 서비스 이름 줄의 들여쓰기
  int? svcIndent;
  for (var i = svcIdx + 1; i < lines.length; i++) {
    if (isContent(lines[i])) {
      svcIndent = indentOf(lines[i]);
      break;
    }
  }
  if (svcIndent == null || svcIndent == 0) {
    throw const FormatException('services 아래에서 서비스를 찾지 못했습니다');
  }

  final keyLine = RegExp(r'^\s*[^\s#][^:]*:\s*(#.*)?$');
  final out = <String>[...lines.sublist(0, svcIdx + 1)];
  var i = svcIdx + 1;
  var changed = 0;
  while (i < lines.length) {
    final l = lines[i];
    if (isContent(l) && indentOf(l) == 0) break; // services 블록 끝
    if (isContent(l) && indentOf(l) == svcIndent && keyLine.hasMatch(l)) {
      // 서비스 블록 범위와 자식 들여쓰기 찾기
      var end = i + 1;
      int? childIndent;
      while (end < lines.length) {
        final m = lines[end];
        if (isContent(m) && indentOf(m) <= svcIndent) break;
        if (isContent(m)) childIndent ??= indentOf(m);
        end++;
      }
      childIndent ??= svcIndent + 2;
      final block = lines.sublist(i + 1, end);
      final pp = block.indexWhere((m) =>
          indentOf(m) == childIndent && m.trimLeft().startsWith('pull_policy:'));
      out.add(l);
      if (pp >= 0) {
        block[pp] = '${' ' * childIndent}pull_policy: always';
      } else {
        out.add('${' ' * childIndent}pull_policy: always');
      }
      out.addAll(block);
      changed++;
      i = end;
      continue;
    }
    out.add(l);
    i++;
  }
  out.addAll(lines.sublist(i));
  if (changed == 0) {
    throw const FormatException('services 아래에서 서비스를 찾지 못했습니다');
  }
  return out.join('\n');
}
