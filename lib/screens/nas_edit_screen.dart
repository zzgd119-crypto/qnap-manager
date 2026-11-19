import 'package:material_ui/material_ui.dart';

import '../api/qnap_client.dart';
import '../app_state.dart';
import '../models/nas_profile.dart';

class NasEditScreen extends StatefulWidget {
  const NasEditScreen({super.key, this.profile});
  final NasProfile? profile;

  @override
  State<NasEditScreen> createState() => _NasEditScreenState();
}

class _NasEditScreenState extends State<NasEditScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.profile?.name ?? '');
  late final _primary =
      TextEditingController(text: widget.profile?.primaryUrl ?? '');
  late final _secondary =
      TextEditingController(text: widget.profile?.secondaryUrl ?? '');
  late final _user = TextEditingController(text: widget.profile?.username ?? '');
  final _pw = TextEditingController();
  late bool _selfSigned = widget.profile?.allowSelfSigned ?? true;
  bool _testing = false;
  String? _testResult;

  bool get _isEdit => widget.profile != null;

  NasProfile _build() => NasProfile(
        id: widget.profile?.id ??
            DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        name: _name.text.trim(),
        primaryUrl: _primary.text.trim(),
        secondaryUrl: _secondary.text.trim(),
        username: _user.text.trim(),
        allowSelfSigned: _selfSigned,
      );

  Future<String> _password() async {
    if (_pw.text.isNotEmpty) return _pw.text;
    if (_isEdit) return await app.store.password(widget.profile!.id) ?? '';
    return '';
  }

  Future<void> _test() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final c = QnapClient(_build(), await _password());
    try {
      await c.login();
      _testResult = '✅ 연결 성공: ${c.baseUrl}';
      await c.logout();
    } on TwoFactorRequired {
      _testResult = '✅ 주소·비밀번호 확인됨 (2단계 인증은 접속 시 입력)';
    } catch (e) {
      _testResult = '❌ $e';
    } finally {
      c.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final pw = _pw.text.isNotEmpty ? _pw.text : null;
    await app.saveProfile(_build(), pw);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    String? required(String? v) =>
        (v == null || v.trim().isEmpty) ? '입력해 주세요' : null;
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'NAS 수정' : 'NAS 추가')),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          TextFormField(
            controller: _name,
            decoration: const InputDecoration(
                labelText: '이름', hintText: '예: 집 NAS', border: OutlineInputBorder()),
            validator: required,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _primary,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '주소 1 (먼저 시도)',
              hintText: 'http://192.168.0.10:8080',
              helperText: '내부망 주소를 넣으면 집에서 빠르게 연결됩니다',
              border: OutlineInputBorder(),
            ),
            validator: required,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _secondary,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '주소 2 (선택, 주소 1이 안 될 때)',
              hintText: 'https://내도메인.myqnapcloud.com:8081',
              helperText: '외부에서 접속할 DDNS 주소. 릴레이 대신 포트포워딩 주소 권장',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _user,
            decoration: const InputDecoration(
                labelText: '사용자 이름', border: OutlineInputBorder()),
            validator: required,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _pw,
            obscureText: true,
            decoration: InputDecoration(
              labelText: '비밀번호',
              helperText: _isEdit ? '비워 두면 기존 비밀번호 유지' : '기기 보안 저장소에 암호화해 저장됩니다',
              border: const OutlineInputBorder(),
            ),
            validator: (v) => !_isEdit && (v == null || v.isEmpty) ? '입력해 주세요' : null,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('자체 서명 인증서 허용'),
            subtitle: const Text('NAS 기본 HTTPS 인증서를 쓰는 경우 켜 두세요'),
            value: _selfSigned,
            onChanged: (v) => setState(() => _selfSigned = v),
          ),
          if (_testResult != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_testResult!),
            ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering),
                label: const Text('연결 테스트'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save),
                label: const Text('저장'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
