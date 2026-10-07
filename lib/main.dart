import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'ui/app_state.dart';
import 'ui/pages/home_page.dart';
import 'ui/theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LanShareApp());
}

class LanShareApp extends StatelessWidget {
  const LanShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..initialize(),
      child: MaterialApp(
        title: 'GUODROP',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.system,
        home: const HomePage(),
      ),
    );
  }
}
