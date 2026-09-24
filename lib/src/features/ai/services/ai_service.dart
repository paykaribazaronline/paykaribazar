import 'dart:async';
import 'dart:convert';
import 'package:image_picker/image_picker.dart';

import '../../../core/firebase/firestore_service.dart';
import '../../../core/services/secrets_service.dart';
import '../../../di/service_locator.dart';
import '../domain/ai_work_type.dart';

import '../../../shared/services/notification_service.dart';
import '../config/ai_config.dart';
import 'ai_cache_service.dart';
import 'ai_provider.dart';
import 'gemini_provider.dart';
import 'fallback_provider.dart';
import 'ai_provider_manager.dart';
import 'api_quota_service.dart';

import 'package:flutter/material.dart';

class AIService {
  final SecretsService _secrets;
  late final AICacheService _cache;
  late AIProviderManager _providerManager;
  late final ApiQuotaService _quotaService;

  String? _currentUserId;
  final List<AIProvider> _providers = [];
  final Map<String, AIProvider> _providerRegistry = {};

  AIService({
    required FirestoreService firestore,
    required SecretsService secrets,
    List<AIProvider>? mockProviders,
    ApiQuotaService? apiQuotaService,
  }) : _secrets = secrets {
    _cache = AICacheService();
    _quotaService = apiQuotaService ??
        (getIt.isRegistered<ApiQuotaService>()
            ? getIt<ApiQuotaService>()
            : ApiQuotaService());
    if (mockProviders != null) {
      _providers.addAll(mockProviders);
    } else {
      _setupProviders();
    }
    _initializeProviderManager();
  }

  /// Returns true if at least one AI provider is configured
  bool get isReady => _providers.isNotEmpty;

  Future<void> initialize({String? userId}) async {
    _currentUserId = userId;
    
    await _cache.initialize();
    
    // Auto-Initialize Quota Tracking in Firestore
    await _initializeQuotaTracking();
  }

  Future<void> _initializeQuotaTracking() async {
    try {
      final providers = ['kimi', 'deepseek', 'gemini'];
      for (var p in providers) {
        // This will create the document if it doesn't exist via incrementUsage logic
        // but let's check hasQuota to trigger the fail-safe
        await _quotaService.hasQuota(p);
      }
      debugPrint('✅ [AIService] Quota tracking initialized in Firestore');
    } catch (e) {
      debugPrint('⚠️ [AIService] Quota init failed: $e');
    }
  }

  void _setupProviders() {
    _providers.clear();
    _providerRegistry.clear();

    // Kimi & DeepSeek disabled from root as no active keys are available
    /*
    final kimiKey = _secrets.getSecret('NVIDIA_API_KEY');
    if (kimiKey.isNotEmpty) {
      final provider = KimiProvider(apiKey: kimiKey);
      _providers.add(provider);
      _providerRegistry['kimi'] = provider;
    }

    final deepSeekKeys = _secrets.deepSeekKeys;
    if (deepSeekKeys.isNotEmpty) {
      final provider = DeepSeekProvider(apiKey: deepSeekKeys.first);
      _providers.add(provider);
      _providerRegistry['deepseek'] = provider;
    }
    */

    final geminiKeys = [
      ..._secrets.getKeysByPrefix('GEMINI_MASTER_KEY'),
      ..._secrets.getKeysByPrefix('GEMINI_SUPPORT_KEY'),
      ..._secrets.getKeysByPrefix('GEMINI_API_KEY'),
    ].where((k) => k.isNotEmpty).toList();

    for (var key in geminiKeys) {
      final provider =
          GeminiProvider(apiKey: key, modelName: AIConfig.primaryModel);
      _providers.add(provider);
    }
    if (geminiKeys.isNotEmpty) {
      _providerRegistry['gemini'] = GeminiProvider(
        apiKey: geminiKeys.first,
        modelName: AIConfig.primaryModel,
      );
    }
    
    if (_providers.isEmpty) {
      debugPrint('⚠️ [AIService] No AI providers could be configured. Check .env and API keys.');
    }
  }

  List<String> _fallbackProviderOrder() {
    final ordered = ['gemini', 'deepseek', 'kimi']
        .where(_providerRegistry.containsKey)
        .toList();
    if (ordered.isEmpty && _providers.isNotEmpty) {
      return [_quotaService.normalizeProviderKey(_providers.first.name)];
    }
    return ordered;
  }

  bool _isValidProviderResponse(String response) {
    return response.isNotEmpty && !response.toLowerCase().contains(' error:');
  }

  Future<String?> _generateWithTrackedProviders(
    String prompt, {
    AiWorkType? type,
  }) async {
    final preferredOrder = _fallbackProviderOrder();
    
    for (final providerKey in preferredOrder) {
      final provider = _providerRegistry[providerKey];
      if (provider == null) continue;

      final hasQuota = await _quotaService.hasQuota(providerKey);
      if (!hasQuota) {
        debugPrint('⛔ [AIService] Skipping $providerKey because quota is exhausted');
        continue;
      }

      try {
        debugPrint('🚀 [AIService] Attempting provider: $providerKey');
        final response =
            await provider.generate(prompt, type: type).timeout(const Duration(seconds: 30));
        
        if (_isValidProviderResponse(response)) {
          await _quotaService.incrementUsage(providerKey);
          return response;
        }
      } catch (e) {
        debugPrint('⚠️ [AIService] Provider $providerKey failed: $e');
        if (e.toString().contains('429') || e.toString().contains('quota')) {
          await _quotaService.markExhausted(providerKey);
        }
      }
    }

    return null;
  }

  void _initializeProviderManager() {
    final primaryProvider = _providers.isNotEmpty 
        ? _providers.first 
        : GeminiProvider(apiKey: 'test', modelName: AIConfig.primaryModel);
    
    final fallbackProvider = FallbackProvider();
    
    _providerManager = AIProviderManager(
      primaryProvider: primaryProvider,
      fallbackProvider: fallbackProvider,
    );
  }

  Future<String> generate(String prompt, {AiWorkType? type}) =>
      generateResponse(prompt, type: type);

  Future<String> generateResponse(String prompt,
      {AiWorkType? type, bool useCache = true, String? userId}) async {
    
    if (_providers.isEmpty) {
      debugPrint('⚠️ [AIService] No providers configured');
      return 'Welcome to Paykari Bazar! 👋';
    }

    userId ??= _currentUserId;

    // Feature: System Prompt - Ensuring AI knows its identity
    final enhancedPrompt = "You are the Paykari Bazar AI Assistant, a helpful expert in the Bangladesh B2B wholesale market. "
        "Respond naturally in Bengali or English as requested. Context: $prompt";

    try {
      if (useCache) {
        final cached = _cache.get(prompt, params: {'type': type?.toString()});
        if (cached != null) return cached;
      }

      final trackedResult =
          await _generateWithTrackedProviders(enhancedPrompt, type: type);
      
      if (trackedResult != null && trackedResult.isNotEmpty) {
        if (useCache) {
          await _cache.set(prompt, trackedResult, params: {'type': type?.toString()});
        }
        return trackedResult;
      }

      // Last resort fallback
      final result = await _providerManager.generate(enhancedPrompt, type: type);
      
      if (useCache && result.isNotEmpty) {
        await _cache.set(prompt, result, params: {'type': type?.toString()});
      }
      
      return result.isNotEmpty ? result : 'Welcome to Paykari Bazar! শুভ কেনাকাটা! 🛒';
    } catch (e) {
      debugPrint('❌ [AIService] Generate response error: $e');
      return 'শুভ দিন! পাইকারী বাজারে আপনাকে স্বাগতম।';
    }
  }

  Future<String> analyzeAndReplicate(String url) async {
    return generateResponse('Analyze and replicate product patterns from: $url', type: AiWorkType.vision);
  }

  Future<Map<String, dynamic>> processCommand(String command) async {
    final res = await generateResponse("Process command: '$command'. Return JSON.");
    try {
      return jsonDecode(res.replaceAll('```json', '').replaceAll('```', '').trim());
    } catch (_) {
      return {'action': 'navigate', 'target': 'dashboard'};
    }
  }

  Future<Map<String, dynamic>> getSystemDiagnostics({String? userId}) async {
    final stats = await performGlobalSystemCheck();
    return {'system': stats, 'generated_at': DateTime.now().toIso8601String()};
  }

  Future<Map<String, dynamic>> performGlobalSystemCheck() async {
    final stopwatch = Stopwatch()..start();
    final providerStats = _providerManager.getStats();

    // Check health of all providers in parallel with a timeout to identify actually active keys
    final healthChecks = await Future.wait(
      _providers.map((p) => p.healthCheck().timeout(
        const Duration(seconds: 4),
        onTimeout: () => false,
      )),
    );
    final activeCount = healthChecks.where((status) => status == true).length;

    stopwatch.stop();
    final latencyMs = '${stopwatch.elapsedMilliseconds}ms';

    return {
      'status': activeCount > 0 ? 'healthy' : 'offline',
      'providers_active': activeCount,
      'primary_available': providerStats['primaryAvailable'],
      'using_fallback': providerStats['usingFallback'],
      'active_provider': providerStats['activeProvider'],
      'latency': latencyMs,
    };
  }

  Future<void> sendAiGreetingNotification(String userId, String userName) async {
    try {
      final res = await generateResponse('Generate greeting for $userName.');
      await getIt<NotificationService>().sendDirectNotification(
          userId: userId, title: 'শুভ দিন! ✨', body: res);
    } catch (_) {}
  }

  Future<String> analyzeImageForSearch(XFile image) async {
    final gemini = _providers.whereType<GeminiProvider>().firstOrNull;
    if (gemini == null) return 'Vision support unavailable';
    try {
      final bytes = await image.readAsBytes();
      return await gemini.generateMultimodal('Identify product.', bytes, 'image/jpeg');
    } catch (_) {
      return '';
    }
  }

  /// NEW: AI Order Status Summary
  Future<String> generateOrderStatusSummary(Map<String, dynamic> orderData) async {
    final status = orderData['status'] ?? 'Pending';
    final items = (orderData['items'] as List?)?.length ?? 0;
    
    final prompt = """
    Summarize this order status for the customer in a friendly, professional Bengali tone:
    Order Status: $status
    Total Items: $items
    Estimated Delivery: ${orderData['estimatedDelivery'] ?? 'Updating'}
    Include a branded closing like 'পাইকারী বাজার আপনার সাথেই আছে।'
    """;
    
    return generateResponse(prompt, useCache: false);
  }

  /// NEW: AI-based Review Summarizer
  Future<String> summarizeProductReviews(List<String> reviews) async {
    if (reviews.isEmpty) return 'কোন রিভিউ পাওয়া যায়নি।';
    
    final prompt = """
    Act as a Product Analyst. Summarize the following customer reviews for this product. 
    Highlight the pros, cons, and overall sentiment in Bengali.
    Reviews:
    ${reviews.join('\n- ')}
    
    Format:
    - সামগ্রিক সারাংশ: ...
    - ইতিবাচক দিক: ...
    - নেতিবাচক দিক: ...
    """;
    
    return generateResponse(prompt, type: AiWorkType.dashboardInsight);
  }

  /// NEW: Smart Prescription Analysis (Bengali OCR + AI)
  Future<String> analyzePrescription(XFile image) async {
    final gemini = _providers.whereType<GeminiProvider>().firstOrNull;
    if (gemini == null) return 'দুঃখিত, আমাদের এআই ফার্মাসিস্ট এই মুহূর্তে অফলাইনে আছে।';
    
    try {
      final bytes = await image.readAsBytes();
      const prompt = """
      Persona: You are the Lead Pharmacist at Paykari Bazar.
      Language: Bengali (Primary) and English (Medical Terms).

      Instruction:
      1. Extract all Medicine Names, Strengths (mg/ml), and Dosage instructions (e.g., 1+0+1).
      2. Format the response with a professional greeting.
      3. Structure the output as:
         - [Medicine Name] | [Dosage] | [Duration]
      4. If the handwriting is illegible, politely ask for a clearer photo.
      5. End with: "পরামর্শ: এই তালিকাটি শুধুমাত্র আপনার সহায়তার জন্য। ঔষধ ক্রয়ের পূর্বে অবশ্যই নিবন্ধিত ফার্মাসিস্টের সাথে পুনরায় যাচাই করুন।"

      Tone: Professional Medical. Language: Bengali.
      """;
      
      final result = await gemini.generateMultimodal(prompt, bytes, 'image/jpeg');
      return result.trim();
    } catch (e) {
      debugPrint('❌ [AIService] Prescription analysis error: $e');
      return 'দুঃখিত, প্রেসক্রিপশনটি পড়া সম্ভব হয়নি। অনুগ্রহ করে একটি উজ্জ্বল আলোতে তোলা ছবি দিন।';
    }
  }

  /// NEW: Contextual Chat for Prescription Support
  Future<String> chatWithPharmacist(String userQuery, String? prescriptionData, {Map<String, dynamic>? userMetadata}) async {
    final userName = userMetadata?['name'] ?? 'User';
    final loyalty = userMetadata?['loyaltyTier'] ?? 'Regular';
    
    final context = prescriptionData != null 
        ? "User ($userName, $loyalty Tier) uploaded a prescription: $prescriptionData." 
        : "User has no recent prescription.";
    
    final prompt = """
    System: You are the Paykari Bazar AI Pharmacist. 
    Context: $context. 
    Query: '$userQuery'. 
    Guideline: Be empathetic, use the user's name if known, and prioritize medical safety.
    """;
    
    return generateResponse(prompt, useCache: false);
  }

  Stream<String> generateStreamedResponse(String prompt, {AiWorkType? type}) async* {
    try {
      final preferredOrder = _fallbackProviderOrder();

      for (final providerKey in preferredOrder) {
        final provider = _providerRegistry[providerKey];
        if (provider == null) continue;
        if (!await _quotaService.hasQuota(providerKey)) continue;

        try {
          await for (final chunk in provider.generateStream(prompt, type: type)
              .timeout(const Duration(seconds: 30))) {
            yield chunk;
          }
          await _quotaService.incrementUsage(providerKey);
          return;
        } catch (e) {
          debugPrint('⚠️ [AIService] Stream provider $providerKey failed: $e');
        }
      }

      await _providerManager.healthCheck();
      yield* _providerManager.generateStream(prompt, type: type);
    } catch (e) {
      debugPrint('❌ [AIService] Stream error: $e');
      yield 'AI service temporarily unavailable. Please try again.';
    }
  }

  String getBrandedGreeting() => 'Welcome to Paykari Bazar.';

  Future<Map<String, dynamic>> synthesizeCrossData(
      {required String sourceCollection,
      required String intent,
      required List<Map<String, dynamic>> rawData}) async {
    final res = await generateResponse('Analyze ${rawData.length} records. Return JSON.');
    try {
      return jsonDecode(res.replaceAll('```json', '').replaceAll('```', '').trim());
    } catch (_) {
      return {};
    }
  }
  
  Map<String, dynamic> getProviderStatus() {
    return _providerManager.getStats();
  }

  /// Public accessor for the first registered Gemini provider. Used by
  /// `AiAutomationService.smartEnrichProduct` to perform multimodal (image +
  /// text) generation without exposing the private `_providers` list. Returns
  /// `null` when no Gemini key is configured.
  ///
  /// This is dev-only — production AI must run via the backend
  /// `analyzePrescription`-style callable so the Gemini API key never ships
  /// in the client binary.
  GeminiProvider? lookupGeminiProvider() =>
      _providers.whereType<GeminiProvider>().firstOrNull;
}
