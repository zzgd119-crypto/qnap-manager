import 'package:material_ui/material_ui.dart';

String fmtBytes(num bytes, {int digits = 1}) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : digits)} ${units[i]}';
}

String fmtRate(num bytesPerSec) => '${fmtBytes(bytesPerSec)}/s';

String fmtDate(DateTime? d) {
  if (d == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

void showMsg(BuildContext context, String msg, {SnackBarAction? action}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), action: action));
}

Future<String?> promptText(BuildContext context, String title,
    {String initial = '', String? hint, String ok = '확인'}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(ok)),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String title, String body,
    {String ok = '확인', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// 오류 표시 + 다시 시도 버튼
class ErrorView extends StatelessWidget {
  const ErrorView(this.error, {super.key, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.error_outline,
              size: 40, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 12),
          Text('$error', textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('다시 시도')),
          ],
        ]),
      ),
    );
  }
}

/// 사용률 막대 (80% 이상 주황, 90% 이상 빨강)
class UsageBar extends StatelessWidget {
  const UsageBar(this.percent, {super.key});
  final double percent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = percent >= 90
        ? cs.error
        : percent >= 80
            ? Colors.orange
            : cs.primary;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: (percent / 100).clamp(0, 1),
        minHeight: 8,
        color: color,
        backgroundColor: cs.surfaceContainerHighest,
      ),
    );
  }
}
