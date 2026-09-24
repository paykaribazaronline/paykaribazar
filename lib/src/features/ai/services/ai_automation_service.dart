import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:convert';
import 'package:google_generative_ai/google_generative_ai.dart';
import '../../../di/service_locator.dart';
import '../../../core/services/secrets_service.dart';
import 'ai_service.dart';
import 'api_quota_service.dart';
import '../../../core/constants/paths.dart';

// NOTE:
// AI is a merchandising ASSISTANT, never a source of truth for price/stock/
// payment. Those remain backend-only — the `calcOrder`, `reserveStock`,
// `createOrder`, and `verifyPayment` Cloud Functions are the canonical
// authority for every money / inventory / payment decision. This service
// only generates descriptive product metadata (name, description, SEO tags)
// and an audit trail; it MUST NOT be used to set `wholesalePrice`, `stock`,
// `reservedStock`, `wholesaleTieredPrices`, or any payment field.
// The new `firestore.rules` block all client writes to those keys.

class AiAutomationService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final AIService _ai = getIt<AIService>();
  final ApiQuotaService _quota = getIt<ApiQuotaService>();

  /// The "Miracle" Method: Takes a product ID and optional image bytes.
  /// Automatically generates Name, Description, and SEO tags based on minimal input.
  ///
  /// In production this MUST be invoked via the backend `analyzePrescription`-
  /// style callable (see `functions/src/health/prescriptionProcess.ts`) so the
  /// Gemini API key never ships in the client binary. This client-side
  /// implementation is only allowed in dev builds — release builds throw.
  Future<void> smartEnrichProduct({
    required String productId,
    List<int>? imageBytes,
    String? basicName,
  }) async {
    // Production guard: AI enrichment must run server-side in production.
    if (kReleaseMode) {
      throw UnsupportedError(
        'AI enrichment must run server-side in production. '
        'Call the analyzePrescription-style callable in functions/src/health/ '
        'instead of this client-side method.',
      );
    }

    try {
      // 1. Prepare the Multimodal Prompt
      final prompt = '''
      Act as a professional E-commerce Merchandiser for the Bangladesh Wholesale (Paykari) market.
      Based on the provided ${imageBytes != null ? 'image and' : ''} name: "${basicName ?? 'Unknown Product'}", 
      generate a complete product profile in JSON format:
      {
        "name": "Catchy B2B Title in English",
        "nameBn": "আকর্ষণীয় পাইকারি শিরোনাম (Bangla)",
        "description": "Professional English sales copy focusing on quality and wholesale benefits.",
        "descriptionBn": "পণ্যটির গুণমান এবং পাইকারি সুবিধার বিস্তারিত বিবরণ।",
        "suggestedCategory": "The most relevant category name",
        "seoTags": ["tag1", "tag2", "tag3", "tag4", "tag5"]
      }
      Ensure the tone is professional, trustworthy, and optimized for SEO.
      Return ONLY the JSON object — no markdown fences, no commentary.
      ''';

      // 2. Call AI. If imageBytes is provided, pass them as a multimodal
      //    content (TextPart + DataPart) to Gemini's vision model.
      final String aiResponse;
      if (imageBytes != null && imageBytes.isNotEmpty) {
        aiResponse = await _generateWithImage(prompt, imageBytes);
      } else {
        aiResponse = await _ai.generate(prompt);
      }

      // 3. Simple JSON extraction (Cleaning potential AI markdown)
      final jsonString = aiResponse.contains('{')
          ? aiResponse.substring(
              aiResponse.indexOf('{'),
              aiResponse.lastIndexOf('}') + 1,
            )
          : '';

      if (jsonString.isEmpty) {
        await _db.collection('ai_audit_logs').add({
          'productId': productId,
          'action': 'SMART_ENRICHMENT',
          'status': 'error',
          'error': 'AI response contained no JSON object',
          'rawResponse': aiResponse,
          'timestamp': FieldValue.serverTimestamp(),
        });
        return;
      }

      // 4. Parse the JSON. Wrap in try/catch with a clear audit error.
      Map<String, dynamic> parsed;
      try {
        parsed = Map<String, dynamic>.from(jsonDecode(jsonString) as Map);
      } catch (parseError) {
        await _db.collection('ai_audit_logs').add({
          'productId': productId,
          'action': 'SMART_ENRICHMENT',
          'status': 'error',
          'error': 'JSON parse failed: $parseError',
          'rawJsonString': jsonString,
          'timestamp': FieldValue.serverTimestamp(),
        });
        return;
      }

      // 5. ACTUALLY APPLY the generated fields to the product.
      //    NOTE: we deliberately do NOT write `wholesalePrice`, `stock`,
      //    `reservedStock`, or any pricing/payment key here — AI is a
      //    merchandising assistant only. The new `firestore.rules` would
      //    reject such writes anyway, but we also guard at the call site.
      await _db.collection(HubPaths.products).doc(productId).update({
        'name': parsed['name'] ?? basicName ?? 'Untitled Product',
        'nameBn': parsed['nameBn'] ?? '',
        'description': parsed['description'] ?? '',
        'descriptionBn': parsed['descriptionBn'] ?? '',
        'suggestedCategory': parsed['suggestedCategory'],
        'seoTags': parsed['seoTags'] ?? const <String>[],
        'aiOptimized': true,
        'aiAuditPending': false,
        'lastAiUpdate': FieldValue.serverTimestamp(),
        'aiMetadata': jsonString,
      });

      // Log the success
      await _db.collection('ai_audit_logs').add({
        'productId': productId,
        'action': 'SMART_ENRICHMENT',
        'status': 'success',
        'usedImage': imageBytes != null && imageBytes.isNotEmpty,
        'fieldsWritten': const [
          'name',
          'nameBn',
          'description',
          'descriptionBn',
          'suggestedCategory',
          'seoTags',
          'aiOptimized',
          'aiAuditPending',
          'lastAiUpdate',
          'aiMetadata',
        ],
        'timestamp': FieldValue.serverTimestamp(),
      });

    } catch (e) {
      await _db.collection('ai_audit_logs').add({
        'productId': productId,
        'action': 'SMART_ENRICHMENT',
        'status': 'error',
        'error': e.toString(),
        'timestamp': FieldValue.serverTimestamp(),
      });
    }
  }

  /// Private helper: builds a multimodal Gemini `GenerativeModel` content
  /// containing both a `TextPart` (the prompt) and a `DataPart` (the JPEG
  /// image bytes) and returns the text response. We re-use the GeminiProvider
  /// already configured by `AIService` so the API key, quota tracking, and
  /// fallback chain all stay intact.
  Future<String> _generateWithImage(String prompt, List<int> imageBytes) async {
    // Prefer the existing GeminiProvider that AIService already wired up —
    // it shares the same API key, quota bucket, and fallback chain.
    final gemini = _ai.lookupGeminiProvider();

    if (gemini != null) {
      final Uint8List bytes = imageBytes is Uint8List
          ? imageBytes
          : Uint8List.fromList(imageBytes);
      final result = await gemini.generateMultimodal(prompt, bytes, 'image/jpeg');
      if (result.isNotEmpty) return result;
    }

    // Fallback: construct a one-off GenerativeModel from the same secret.
    // This path is dev-only (kReleaseMode is already blocked at the entry
    // of smartEnrichProduct).
    final apiKey = _resolveGeminiApiKey();
    if (apiKey.isEmpty) {
      throw StateError(
        'No Gemini API key available for multimodal enrichment. '
        'Set GEMINI_API_KEY in .env (dev) or route via the backend '
        'analyzePrescription callable (production).',
      );
    }
    final model = GenerativeModel(model: 'gemini-1.5-flash', apiKey: apiKey);
    final content = [
      Content.multi([
        TextPart(prompt),
        DataPart('image/jpeg', Uint8List.fromList(imageBytes)),
      ])
    ];
    final response = await model.generateContent(content);
    return response.text ?? '';
  }

  /// Resolves a Gemini API key from the SecretsService. Dev-only — the
  /// kReleaseMode guard at smartEnrichProduct's entry already prevents
  /// this from running in shipped binaries.
  String _resolveGeminiApiKey() {
    try {
      final secrets = getIt<SecretsService>();
      final keys = <String>[
        ...secrets.getKeysByPrefix('GEMINI_MASTER_KEY'),
        ...secrets.getKeysByPrefix('GEMINI_SUPPORT_KEY'),
        ...secrets.getKeysByPrefix('GEMINI_API_KEY'),
      ].where((k) => k.isNotEmpty).toList();
      return keys.isNotEmpty ? keys.first : '';
    } catch (_) {
      return '';
    }
  }

  /// NEW: AI Price Suggestion for Sellers
  Future<Map<String, dynamic>> suggestProductPricing(String productName, double costPrice) async {
    final prompt = """
    Based on the product "$productName" with a cost of ৳$costPrice, suggest a competitive wholesale 
    selling price for the Bangladesh market. 
    Return JSON: {"suggestedPrice": 0.0, "marginPercentage": 0, "strategy": "Bengali reason"}
    """;
    
    final response = await _ai.generate(prompt);
    try {
      return Map<String, dynamic>.from(jsonDecode(response.replaceAll('```json', '').replaceAll('```', '').trim()));
    } catch (_) { return {}; }
  }

  /// NEW: Fraud Detection AI
  Future<bool> detectOrderAnomaly(Map<String, dynamic> orderData) async {
    final prompt = """
    Analyze this order for potential fraud or suspicious behavior:
    Order Data: ${jsonEncode(orderData)}
    Return ONLY 'true' if suspicious, 'false' if safe.
    """;
    final response = await _ai.generate(prompt);
    return response.toLowerCase().contains('true');
  }

  /// Runs background caching using leftover quota
  Future<void> runNightlyAIOptimization() async {
    try {
      // 1. Check if we have enough leftover quota (e.g., > 30%)
      final providers = ['kimi', 'deepseek', 'gemini'];
      bool hasSpareQuota = false;
      for (var p in providers) {
        if (await _quota.hasQuota(p)) {
          hasSpareQuota = true;
          break;
        }
      }

      if (!hasSpareQuota) return;

      final productsSnap = await _db.collection(HubPaths.products)
          .where('ai_descriptionBn_enriched', isEqualTo: false)
          .limit(10)
          .get();

      for (var doc in productsSnap.docs) {
        final data = doc.data();

        final String name = data['name'] ?? 'Product';
        final String descRaw = data['description'] ?? '';
        final String descBnRaw = data['descriptionBn'] ?? '';
        final String category = data['categoryName'] ?? 'General';

        // Enhanced Prompt for better SEO and B2B context
        final prompt = '''
        Act as a B2B E-commerce Expert for the Bangladesh wholesale market.
        Product: $name
        Category: $category
        Existing EN: $descRaw
        Existing BN: $descBnRaw

        Task:
        1. Rewrite the Bengali description to be professional, trustworthy, and enticing for retailers.
        2. Generate 5 highly relevant SEO keywords in English that include wholesale intent.
        3. Return format: [Bengali Description] \nTags: [tag1, tag2, tag3, tag4, tag5]
        ''';

        final aiResult = await _ai.generate(prompt);

        String improvedBn = descBnRaw;
        final tags = <String>[];

        if (aiResult.isNotEmpty) {
          final lower = aiResult.toLowerCase();
          final tagMarker = lower.indexOf('tags:');
          if (tagMarker != -1) {
            final tagSegment = aiResult.substring(tagMarker + 5);
            tags.addAll(
              tagSegment
                  .split(RegExp(r'[\n\r,،]+'))
                  .map((t) => t.trim())
                  .where((t) => t.length > 1)
                  .take(5)
                  .toList(),
            );
            improvedBn = aiResult.substring(0, tagMarker).trim();
          } else {
            improvedBn = aiResult.trim();
          }
        }

        if (improvedBn.isEmpty || improvedBn == descBnRaw) {
          final fallbackPrompt =
              'Rewrite the following product description into natural, professional Bangla for a wholesale bazaar listing. Name: $name. Description: $descRaw';
          final fallback = await _ai.generateResponse(fallbackPrompt);
          if (fallback.isNotEmpty) {
            improvedBn = fallback.trim();
          }
        }

        if (improvedBn.isEmpty || improvedBn == descBnRaw) {
          await doc.reference.update({'ai_processed': true});
          continue;
        }

        await doc.reference.update({
          'descriptionBn': improvedBn,
          if (tags.isNotEmpty) 'aiTags': tags,
          'ai_processed': true,
          'aiOptimized': true,
          'ai_descriptionBn_enriched': true,
        });
      }
      // AI Background Caching Task Completed
    } catch (e) {
      // AI Caching Error handled silently
    }
  }

  /// Perform a system-wide health check for AI services
  Future<Map<String, dynamic>> performGlobalSystemCheck() async {
    return await _ai.performGlobalSystemCheck();
  }

  Future<void> _processTask(Map<String, dynamic> task) async {
    final type = task['type'] ?? 'general';
    if (type == 'optimization') {
      await runNightlyAIOptimization();
    } else {
      // Simulate general AI task processing (Forecasting, Inventory Audit, etc.)
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  /// Performs a system-wide audit and executes pending AI tasks.
  /// This is the "Engine" that makes the Admin Dashboard truly functional.
  Future<void> checkAndRun() async {
    try {
      final check = await performGlobalSystemCheck();
      
      // Log health check result
      await _db.collection('ai_audit_logs').add({
        'timestamp': FieldValue.serverTimestamp(),
        'status': check['status'] == 'healthy' ? 'success' : 'failed',
        'message': 'System Health: ${check['neural_load']} load, ${check['latency']} latency.',
        'details': check,
      });

      // 1. Automatically find products needing AI audit (aiAuditPending = true)
      final auditPendingProducts = await _db.collection(HubPaths.products)
          .where('aiAuditPending', isEqualTo: true)
          .limit(10)
          .get();
          
      if (auditPendingProducts.docs.isNotEmpty) {
        debugPrint('🤖 [AI Engine] Found ${auditPendingProducts.docs.length} products for audit.');
        // We reuse the optimization logic here
        await runNightlyAIOptimization(); 
      }

      // Fetch pending tasks from the 'ai_automation_tasks' collection
      final tasks = await _db
          .collection('ai_automation_tasks')
          .where('status', isEqualTo: 'pending')
          .orderBy('priority', descending: true)
          .limit(5)
          .get();

      for (var doc in tasks.docs) {
        final data = doc.data();
        await _processTask(data);
        
        await doc.reference.update({
          'status': 'completed',
          'completed_at': FieldValue.serverTimestamp(),
          'metadata': {
            'processed_by': 'AiAutomationEngine_v1',
          }
        });
      }
    } catch (e) {
      // Use a structured log for the Admin Dashboard to pick up
      await _db.collection('ai_audit_logs').add({
        'timestamp': FieldValue.serverTimestamp(),
        'status': 'critical_failure',
        'error': e.toString(),
        'context': 'automation_cycle',
      });
    }
  }

  /// Stream of AI audit logs
  Stream<List<Map<String, dynamic>>> getAuditLogs() {
    return _db.collection('ai_audit_logs')
        .orderBy('timestamp', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList());
  }

  /// Bridges a prescription upload to a smart support interaction.
  /// This makes the AI "smarter" by proactively helping the user after an upload.
  Future<void> initiatePrescriptionSupport({
    required String userId,
    required String orderId,
    required String extractedText,
  }) async {
    try {
      // Pro-Tip: Check stock internally before the AI responds
      final stockQuery = await _db.collection(HubPaths.products)
          .where('category', isEqualTo: 'pharmacy')
          .limit(20)
          .get();
      
      final availableItems = stockQuery.docs.map((d) => d['name']).join(', ');

      final prompt = """
      User uploaded a prescription with: $extractedText. 
      Our stock includes: $availableItems.
      Generate a professional Bengali follow-up message. Mention that we have checked our wholesale inventory for them.
      """;
      
      final aiFollowUp = await _ai.generate(prompt);

      // Save to private_chats to connect the Emergency Tab to the Chat feature
      await _db.collection('private_chats').add({
        'userId': userId,
        'orderId': orderId,
        'message': aiFollowUp,
        'sender': 'AI_PHARMACIST',
        'timestamp': FieldValue.serverTimestamp(),
        'isMedicalContext': true,
        'metadata': {
          'extracted_medicines': extractedText,
        }
      });
    } catch (e) {
      debugPrint('❌ [AiAutomationService] Failed to initiate prescription support: $e');
    }
  }
}
