import 'package:material_ui/material_ui.dart';

import 'app_state.dart';
import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  app.init();
  runApp(const QnapManagerApp());
}

class QnapManagerApp extends StatelessWidget {
  const QnapManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF3A5BD9), brightness: b),
          visualDensity: VisualDensity.standard,
        );
    return MaterialApp(
      title: 'QNAP 매니저',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: const HomeScreen(),
    );
  }
}
