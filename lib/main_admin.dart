import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sentry_flutter/sentry_flutter.dart';


import 'src/utils/router_admin.dart';
import 'src/utils/styles.dart';
import 'src/utils/globals.dart';
import 'src/utils/update_dialog.dart';
import 'src/di/providers.dart';
import 'src/di/service_initializer.dart';

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    
    // Visual Safety Net
    ErrorWidget.builder = (FlutterErrorDetails details) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Material(
          child: Container(
            color: AppStyles.darkBackgroundColor,
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.bolt_rounded, color: AppStyles.primaryColor, size: 60),
                const SizedBox(height: 20),
                const Text(
                  'দুঃখিত! একটি সমস্যা হয়েছে।',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                const Text(
                  'আমাদের এআই ইঞ্জিন সমস্যাটি সমাধানের চেষ্টা করছে। অনুগ্রহ করে কিছুক্ষণ পর আবার চেষ্টা করুন।',
                  style: TextStyle(fontSize: 14, color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                Text(details.exception.toString(), style: const TextStyle(color: Colors.grey, fontSize: 10)),
              ],
            ),
          ),
        ),
      );
    };

    // Load Environment Variables
    try { 
      await dotenv.load(fileName: '.env'); 
    } catch (e) {
      try {
        await dotenv.load(fileName: 'assets/.env');
      } catch (e2) {
        debugPrint('Dotenv Load Error: $e2');
      }
    }
    
    // Initialize all services via GetIt (v2.0 Architecture)
    await ServiceInitializer.initialize();

    // Database seeding is now performed server-side via the `runSeed` callable
    // Cloud Function (see functions/src/admin/seedLocations.ts).
    // Admin app must NEVER mutate the database on startup — it is a read/ops UI.

    // DNA ENFORCED
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: false,
    );

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));

    // Sentry initialization
    String dsn = '';
    try {
      dsn = (dotenv.env['SENTRY_DSN'] ?? '').trim();
    } catch (_) {}
    if (dsn.isEmpty) {
      dsn = 'https://08442f2fde59f1f763b3c271df8c11bc@o4510812244869120.ingest.us.sentry.io/4510812374892544';
    }

    await SentryFlutter.init(
      (options) {
        options.dsn = dsn;
        options.tracesSampleRate = 1.0;
      },
      appRunner: () => runApp(
        const ProviderScope(child: AdminApp()),
      ),
    );
    
  }, (error, stack) {
    debugPrint('Fatal Global Error: $error');
    Sentry.captureException(error, stackTrace: stack);
  });
}

class AdminApp extends ConsumerStatefulWidget {
  const AdminApp({super.key});
  @override
  ConsumerState<AdminApp> createState() => _AdminAppState();
}

class _AdminAppState extends ConsumerState<AdminApp> {
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Initialize Update Service
    try {
      await ref
          .read(updateServiceProvider)
          .initialize()
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('Update Service Init Error: $e');
    }

    await ref.read(notificationServiceProvider).init();

    if (mounted) {
      setState(() => _isInitialized = true);
      _checkUpdate();
    }
  }

  void _checkUpdate() async {
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;

    final upd = ref.read(updateServiceProvider);
    final status = await upd.checkForAppUpdate();

    if (status != UpdateStatus.upToDate && mounted) {
      showDialog(
        context: navigatorKey.currentContext!,
        barrierDismissible: status != UpdateStatus.forceUpdate,
        builder: (c) => UpdateDialog(
          message:
              upd.getUpdateMessage(ref.read(languageProvider).languageCode),
          isForceUpdate: status == UpdateStatus.forceUpdate,
          onUpdate: () => upd.launchUpdateUrl(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final appConfig =
        ref.watch(appConfigProvider).value ?? const <String, dynamic>{};
    AppStyles.syncDynamicConfig(appConfig);

    if (!_isInitialized) {
      return const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: AppStyles.darkBackgroundColor,
            body: Center(child: CircularProgressIndicator(color: AppStyles.primaryColor))
          ));
    }

    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      routerConfig: adminRouter,
      theme: AppStyles.getLightTheme(
        GoogleFonts.plusJakartaSansTextTheme(),
        config: appConfig,
      ),
      darkTheme: AppStyles.getDarkTheme(
        GoogleFonts.plusJakartaSansTextTheme(),
        config: appConfig,
      ),
      themeMode: ref.watch(themeProvider) ? ThemeMode.dark : ThemeMode.light,
      locale: ref.watch(languageProvider),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate
      ],
      supportedLocales: const [Locale('en', ''), Locale('bn', '')],
    );
  }
}
