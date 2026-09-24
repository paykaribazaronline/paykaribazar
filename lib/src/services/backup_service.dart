import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:http/http.dart' as http;
import '../core/constants/paths.dart';
import 'package:flutter/foundation.dart';

class BackupService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  late final encrypt.Encrypter _encrypter;

  /// Initializes BackupService with a 32-byte encryption key.
  /// Key should be provided from a secure source (e.g. Remote Config).
  BackupService(String masterKey) {
    // DNA ENFORCED: Key must be 32 chars for AES-256
    final key = encrypt.Key.fromUtf8(masterKey);
    _encrypter = encrypt.Encrypter(encrypt.AES(key));
  }

  /// Performs a full cloud backup with encryption
  Future<String> performFullBackup(String adminId, {bool isSimulation = false}) async {
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final backupData = <String, dynamic>{
        'timestamp': isSimulation ? 0 : timestamp,
        'adminId': adminId,
        'collections': {},
      };

      // Define target collections for backup
      final collections = [
        HubPaths.users,
        HubPaths.orders,
        HubPaths.products,
        HubPaths.categories,
        'settings',
      ];

      if (isSimulation) {
        // Simulate a delay and return success without touching Firestore
        await Future.delayed(const Duration(seconds: 2));
        return 'Simulation: Backup successful for $adminId';
      }

      for (var collection in collections) {
        final List<Map<String, dynamic>> collectionDocs = [];
        QuerySnapshot? lastSnap;
        bool hasMore = true;

        while (hasMore) {
          var query = _db.collection(collection).orderBy(FieldPath.documentId).limit(500);
          if (lastSnap != null && lastSnap.docs.isNotEmpty) {
            query = query.startAfterDocument(lastSnap.docs.last);
          }

          final snap = await query.get();
          if (snap.docs.isEmpty) {
            hasMore = false;
          } else {
            collectionDocs.addAll(snap.docs.map((doc) => {
              'id': doc.id,
              ...doc.data(),
            }));
            lastSnap = snap;
            if (snap.docs.length < 500) {
              hasMore = false;
            }
          }
        }
        backupData['collections'][collection] = collectionDocs;
      }

      final jsonStr = jsonEncode(backupData);
      final iv = encrypt.IV.fromSecureRandom(16);
      final encrypted = _encrypter.encrypt(jsonStr, iv: iv);

      // Web safety check
      if (kIsWeb) {
        return 'Cloud backup triggered (Web local storage not supported for .enc files)';
      }

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/backup_$timestamp.enc');
      await file.writeAsBytes(Uint8List.fromList(iv.bytes + encrypted.bytes));

      final ref = _storage.ref().child('backups/backup_$timestamp.enc');
      await ref.putFile(file);
      final downloadUrl = await ref.getDownloadURL();

      await _db.collection('backups').add({
        'timestamp': FieldValue.serverTimestamp(),
        'fileUrl': downloadUrl,
        'fileName': 'backup_$timestamp.enc',
        'adminId': adminId,
        'status': 'success',
        'isEncrypted': true,
      });

      return 'Backup successful and encrypted: backup_$timestamp.enc';
    } catch (e) {
      if (kDebugMode) debugPrint('Backup Error: $e');
      return 'Backup failed: $e';
    }
  }

  /// Restores data from an encrypted backup file using Batch Writes
  /// WARNING: This overwrites existing data in the target collections.
  Future<void> restoreFromBackup(String fileUrl) async {
    try {
      // 1. Download the encrypted file
      final response = await http.get(Uri.parse(fileUrl));
      if (response.statusCode != 200) throw Exception('Download failed');

      // 2. Decrypt data
      final bytes = response.bodyBytes;
      final iv = encrypt.IV(bytes.sublist(0, 16));
      final encrypted = encrypt.Encrypted(bytes.sublist(16));
      final decryptedStr = _encrypter.decrypt(encrypted, iv: iv);
      final Map<String, dynamic> backupData = jsonDecode(decryptedStr);
      final collectionsData = backupData['collections'] as Map<String, dynamic>;

      // 3. Restore each collection using Batch Writes
      for (var entry in collectionsData.entries) {
        final collectionName = entry.key;
        final List<dynamic> documents = entry.value;

        await _restoreCollectionInBatches(collectionName, documents);
      }
      
      if (kDebugMode) debugPrint('✅ System Restoration Complete');
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Restore failed: $e');
      rethrow;
    }
  }

  /// Helper to write documents in batches of 100 (Safe limit)
  Future<void> _restoreCollectionInBatches(String collectionName, List<dynamic> docs) async {
    const int batchSize = 100;
    
    for (var i = 0; i < docs.length; i += batchSize) {
      final batch = _db.batch();
      final chunk = docs.skip(i).take(batchSize);

      for (var docData in chunk) {
        final Map<String, dynamic> data = Map<String, dynamic>.from(docData);
        final id = data.remove('id');
        final docRef = _db.collection(collectionName).doc(id);
        batch.set(docRef, data, SetOptions(merge: false)); // Overwrite with backup
      }

      await batch.commit();
      if (kDebugMode) debugPrint('Restored $batchSize docs to $collectionName');
    }
  }

  static Future<void> performBackgroundBackup(String uid) async {
    // Implementation Note: In production, fetch this from SecretService or Remote Config
    // For simulation/testing purposes, we use a fallback.
    const fallbackKey = 'paykari_bazar_secure_master_key_!'; 
    
    // TODO(audit): Integrate with getIt<SecretService>() to get the real 32-char key
    final service = BackupService(fallbackKey.padRight(32).substring(0, 32));
    
    await service.performFullBackup(uid);
  }

  Stream<List<Map<String, dynamic>>> getBackupHistory() {
    return _db.collection('backups')
        .orderBy('timestamp', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList());
  }

  /// Generates the encrypted backup payload and returns the local File object.
  Future<File> generateBackupFile(String adminId) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final backupData = <String, dynamic>{
      'timestamp': timestamp,
      'adminId': adminId,
      'collections': {},
    };

    final collections = [
      HubPaths.users,
      HubPaths.orders,
      HubPaths.products,
      HubPaths.categories,
      'settings',
    ];

    for (var collection in collections) {
      final List<Map<String, dynamic>> collectionDocs = [];
      QuerySnapshot? lastSnap;
      bool hasMore = true;

      while (hasMore) {
        var query = _db.collection(collection).orderBy(FieldPath.documentId).limit(500);
        if (lastSnap != null && lastSnap.docs.isNotEmpty) {
          query = query.startAfterDocument(lastSnap.docs.last);
        }

        final snap = await query.get();
        if (snap.docs.isEmpty) {
          hasMore = false;
        } else {
          collectionDocs.addAll(snap.docs.map((doc) => {
            'id': doc.id,
            ...doc.data(),
          }));
          lastSnap = snap;
          if (snap.docs.length < 500) {
            hasMore = false;
          }
        }
      }
      backupData['collections'][collection] = collectionDocs;
    }

    final jsonStr = jsonEncode(backupData);
    final iv = encrypt.IV.fromSecureRandom(16);
    final encrypted = _encrypter.encrypt(jsonStr, iv: iv);

    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/backup_$timestamp.enc');
    await file.writeAsBytes(Uint8List.fromList(iv.bytes + encrypted.bytes));
    return file;
  }

  /// Uploads a backup file to the local development Express sync server.
  Future<bool> uploadBackupToLocalServer(File file, String uid) async {
    try {
      final uri = Uri.parse(kIsWeb
          ? 'http://localhost:3000/upload-backup'
          : ((!kIsWeb && Platform.isAndroid)
              ? 'http://10.0.2.2:3000/upload-backup'
              : 'http://localhost:3000/upload-backup'));
      final request = http.MultipartRequest('POST', uri)
        ..fields['uid'] = uid
        ..files.add(await http.MultipartFile.fromPath('backupFile', file.path));
      
      final response = await request.send();
      return response.statusCode == 200;
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Local Backup Sync Server upload failed: $e');
      return false;
    }
  }
}
