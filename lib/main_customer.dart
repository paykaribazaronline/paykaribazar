// Trigger build: Secret updated
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'src/di/service_initializer.dart';
import 'src/di/service_locator.dart';
import 'src/di/providers.dart';
import 'src/services/database_seeder.dart';
import 'src/services/background_task_service.dart';
import 'src/shared/services/update_service.dart';
import 'src/utils/router_customer.dart';
import 'src/utils/styles.dart';
import 'src/utils/globals.dart';
import 'src/utils/update_dialog.dart';
import 'src/utils/touch_glow_overlay.dart';


void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    
    final container = ProviderContainer();

    // Visual Safety Net
    ErrorWidget.builder = (FlutterErrorDetails details) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Material(
          child: Container(
            color: AppStyles.backgroundColor,
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.bolt_rounded,
                    color: AppStyles.primaryColor, size: 60),
                const SizedBox(height: 20),
                const Text(
                  'দুঃখিত! একটি সমস্যা হয়েছে।',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                const Text(
                  'আমাদের এআই ইঞ্জিন সমস্যাটি সমাধানের চেষ্টা করছে। অনুগ্রহ করে কিছুক্ষণ পর আবার চেষ্টা করুন।',
                  style: TextStyle(fontSize: 14),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                Text(details.exception.toString(),
                    style: const TextStyle(color: Colors.grey, fontSize: 10)),
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
        if (kDebugMode) debugPrint('Dotenv Load Error: $e2');
      }
    }

    // Initialize all services
    await ServiceInitializer.initialize();

    // Auto seed/sync locations if database is empty or has no districts
    try {
      final snap = await FirebaseFirestore.instance.collection(HubPaths.locations)
          .where('type', isEqualTo: 'district')
          .limit(1)
          .get()
          .timeout(const Duration(seconds: 4));
      if (snap.docs.isEmpty) {
        await DatabaseSeeder.seedAll().timeout(const Duration(seconds: 8));
        if (kDebugMode) debugPrint('✅ Auto-seeded all default database collections at startup');
      }

      // Auto-seed mock products if empty
      final prodSnap = await FirebaseFirestore.instance.collection(HubPaths.products).limit(1).get().timeout(const Duration(seconds: 4));
      if (prodSnap.docs.isEmpty) {
        await DatabaseSeeder.seedProducts().timeout(const Duration(seconds: 8));
        if (kDebugMode) debugPrint('✅ Auto-seeded mock products at startup');
      }

      // Auto-seed mock banners if empty
      final promoSnap = await FirebaseFirestore.instance.collection('promos').limit(1).get().timeout(const Duration(seconds: 4));
      if (promoSnap.docs.isEmpty) {
        await DatabaseSeeder.seedPromos().timeout(const Duration(seconds: 8));
        if (kDebugMode) debugPrint('✅ Auto-seeded mock banners at startup');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Auto-seed check skipped/failed: $e');
    }

    // Initialize and schedule background tasks (Auto-Backup, AI Audit)
    try {
      await BackgroundTaskService.initialize();
      await BackgroundTaskService.scheduleAll();
    } catch (e) {
      if (kDebugMode) debugPrint('BackgroundTaskService Init Error: $e');
    }

    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
    );

    // Sentry initialization — DSN from .env only, no hardcoded fallback
    String dsn = '';
    try {
      dsn = (dotenv.env['SENTRY_DSN'] ?? '').trim();
    } catch (_) {}

    await SentryFlutter.init(
      (options) {
        options.dsn = dsn;
        options.tracesSampleRate = 0.2;
      },
      appRunner: () async {
        if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
          await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true);
          FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
          PlatformDispatcher.instance.onError = (error, stack) {
            FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
            return true;
          };
        }
        runApp(
          UncontrolledProviderScope(container: container, child: const CustomerApp()),
        );
      },
    );
  }, (error, stack) {
    if (kDebugMode) debugPrint('Fatal Global Error: $error');
    Sentry.captureException(error, stackTrace: stack);
  });
}

class CustomerApp extends ConsumerStatefulWidget {
  const CustomerApp({super.key});
  @override
  ConsumerState<CustomerApp> createState() => _CustomerAppState();
}

class _CustomerAppState extends ConsumerState<CustomerApp> {
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      // Issue #6: Properly schedule sync without unawaited Future
      Future.delayed(const Duration(minutes: 2), () {
        if (mounted) {
          ref.read(syncServiceProvider).syncData();
        }
      });
    } catch (e) {
      if (kDebugMode) debugPrint('Init Error: $e');
    }

    if (mounted) {
      setState(() => _isInitialized = true);
      _checkUpdate();
    }
  }

  void _checkUpdate() async {
    if (!mounted) return;
    final upd = getIt<UpdateService>();
    final status = await upd.checkForAppUpdate();

    if (status != UpdateStatus.upToDate && mounted) {
      showDialog(
        context: navigatorKey.currentContext ?? context,
        barrierDismissible: status != UpdateStatus.forceUpdate,
        builder: (c) => UpdateDialog(
          message:
              'A new version is available. Please update for the best experience.',
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
              body: Center(
                  child: CircularProgressIndicator(
                      color: AppStyles.primaryColor))));
    }

    return MaterialApp.router(
      title: 'পাইকারী বাজার',
      debugShowCheckedModeBanner: false,
      routerConfig: customerRouter,
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
      builder: (context, child) => TouchGlowOverlay(child: child!),
    );
  }
}
