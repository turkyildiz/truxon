import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';
import 'i18n.dart';
import 'screens/login_screen.dart';
import 'screens/home_shell.dart';
import 'services/alarms.dart';
import 'services/session_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (AppConfig.supabaseUrl.isEmpty || AppConfig.supabaseAnonKey.isEmpty) {
    runApp(const _ConfigErrorApp());
    return;
  }

  // Background tracking service comms + the DND-bypass alarm channel.
  FlutterForegroundTask.initCommunicationPort();
  await Alarms.init();
  await loadLocale();

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey, // publishableKey alias when available
  );

  // Hand the current access token to the background GPS isolate, and keep it
  // fresh on every refresh so uploads keep authenticating while on duty.
  final auth = Supabase.instance.client.auth;
  await SessionStore.saveAccessToken(auth.currentSession?.accessToken);
  auth.onAuthStateChange.listen((data) {
    SessionStore.saveAccessToken(data.session?.accessToken);
  });

  // Rebuild the whole app when the language changes.
  runApp(ValueListenableBuilder<String>(
    valueListenable: appLocale,
    builder: (_, __, ___) => const TruxCompanionApp(),
  ));
}

class TruxCompanionApp extends StatelessWidget {
  const TruxCompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Trux Companion',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F2744), brightness: Brightness.light),
        useMaterial3: true,
      ),
      home: const _AuthGate(),
    );
  }
}

class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snap) {
        final session = Supabase.instance.client.auth.currentSession;
        if (session == null) return const LoginScreen();
        return const HomeShell();
      },
    );
  }
}

class _ConfigErrorApp extends StatelessWidget {
  const _ConfigErrorApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Missing SUPABASE_URL / SUPABASE_ANON_KEY.\n'
              'Pass via --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
