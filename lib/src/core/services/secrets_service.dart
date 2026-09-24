// TODO(audit): remove this class entirely once AI features are 100%
// backend-routed. All image-upload + prescription-analysis flows now go
// through the `analyzePrescription` / image-upload callables (Task ID 9);
// the only remaining uses of this class are legacy dev-environment paths
// that should be migrated before the next release.

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../di/service_locator.dart';

final secretsServiceProvider = Provider((ref) => getIt<SecretsService>());

class SecretsService {
  final Map<String, dynamic> _dbSecrets;
  SecretsService(this._dbSecrets);

  String getSecret(String key, {String fallback = ''}) {
    if (_dbSecrets.containsKey(key) && _dbSecrets[key].toString().isNotEmpty) {
      return _dbSecrets[key].toString().trim();
    }
    try {
      return dotenv.get(key, fallback: fallback).trim();
    } catch (_) {
      return fallback;
    }
  }

  List<String> getKeysByPrefix(String prefix) {
    final Set<String> allKeys = {};
    _dbSecrets.forEach((k, v) {
      if (k.startsWith(prefix) && v.toString().isNotEmpty) {
        allKeys.add(v.toString().trim());
      }
    });
    dotenv.env.forEach((k, v) {
      if (k.startsWith(prefix) && v.isNotEmpty) {
        allKeys.add(v.trim());
      }
    });
    return allKeys.toList();
  }

  /// DeepSeek API keys. Retained for the dev environment only — production
  /// AI requests MUST go through the backend `analyzePrescription` and
  /// related callables, which read the keys from Secret Manager rather than
  /// the client binary.
  @Deprecated('Use the backend analyzePrescription / AI callables. '
      'Secrets must never live in the client binary.')
  List<String> get deepSeekKeys => getKeysByPrefix('DEEPSEEK_API_KEY');

  /// Generic (Gemini) API keys. Same treatment as [deepSeekKeys].
  @Deprecated('Use the backend analyzePrescription / AI callables. '
      'Secrets must never live in the client binary.')
  List<String> get genericKeys => getKeysByPrefix('GEMINI_API_KEY');

  /// Cloudinary cloud name. Used by the legacy image-upload path; new code
  /// should use the backend image-upload callable instead.
  @Deprecated('Use the backend image-upload callable. Secrets must never '
      'live in the client binary.')
  String get cloudinaryCloudName => getSecret('CLOUDINARY_CLOUD_NAME');

  /// Cloudinary API key. Same treatment as [cloudinaryCloudName].
  @Deprecated('Use the backend image-upload callable. Secrets must never '
      'live in the client binary.')
  String get cloudinaryApiKey => getSecret('CLOUDINARY_API_KEY');
}
