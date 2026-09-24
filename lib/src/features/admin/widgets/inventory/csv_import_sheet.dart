import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../di/providers.dart';
import '../../../../utils/styles.dart';

class CsvImportSheet extends ConsumerStatefulWidget {
  const CsvImportSheet({super.key});

  @override
  ConsumerState<CsvImportSheet> createState() => _CsvImportSheetState();
}

class _CsvImportSheetState extends ConsumerState<CsvImportSheet> {
  bool _isProcessing = false;
  String? _statusMessage;
  double _progress = 0;
  int _totalRows = 0;
  int _processedRows = 0;

  Future<void> _pickAndProcessCsv() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );

    if (result != null && result.files.single.path != null) {
      setState(() {
        _isProcessing = true;
        _statusMessage = 'Reading CSV file...';
        _progress = 0;
      });

      try {
        final file = File(result.files.single.path!);
        final input = file.openRead();
        final fields = await input
            .transform(utf8.decoder)
            .transform(const CsvToListConverter())
            .toList();


        if (fields.isEmpty) throw 'CSV file is empty';

        final headers =
            fields[0].map((e) => e.toString().toLowerCase().trim()).toList();
        final dataRows = fields.sublist(1);
        _totalRows = dataRows.length;

        setState(() => _statusMessage =
            'Found $_totalRows products. Starting AI-enhanced import...');

        for (var i = 0; i < dataRows.length; i++) {
          final row = dataRows[i];
          final Map<String, dynamic> productData = {};

          for (var j = 0; j < headers.length; j++) {
            if (j < row.length) {
              productData[headers[j]] = row[j];
            }
          }

          // AI ENHANCEMENT: If required fields are empty, ask AI to fill them
          await _enhanceWithAi(productData);

          // Upload to Firestore
          await _uploadProduct(productData);

          setState(() {
            _processedRows = i + 1;
            _progress = _processedRows / _totalRows;
            _statusMessage =
                'Processing $_processedRows/$_totalRows: ${productData['name'] ?? 'Unknown'}';
          });
        }

        setState(() {
          _isProcessing = false;
          _statusMessage = 'Successfully imported $_totalRows products!';
        });
      } catch (e) {
        setState(() {
          _isProcessing = false;
          _statusMessage = 'Error: $e';
        });
      }
    }
  }

  Future<void> _enhanceWithAi(Map<String, dynamic> data) async {
    final name = data['name']?.toString() ?? '';
    final category = data['categoryname']?.toString() ?? '';

    bool needsAi = false;
    if (data['description'] == null || data['description'].toString().isEmpty) {
      needsAi = true;
    }
    if (data['namebn'] == null || data['namebn'].toString().isEmpty) {
      needsAi = true;
    }
    if (data['unit'] == null || data['unit'].toString().isEmpty) needsAi = true;
    if (data['price'] == null ||
        data['price'].toString() == '0' ||
        data['price'].toString().isEmpty) {
      needsAi = true;
    }

    if (needsAi && name.isNotEmpty) {
      final ai = ref.read(aiServiceProvider);
      final prompt = '''
      Act as a professional e-commerce catalog manager. 
      I have a product named "$name" in the category "$category".
      Some fields are missing. Please provide the missing details in JSON format.
      Fields: nameBn (Bengali name), description (English), descriptionBn (Bengali), unit (e.g., pcs, kg, pack), unitBn (Bengali unit), estimatedPrice (numeric), tags (comma separated).
      Return ONLY valid JSON.
      ''';

      try {
        final response = await ai.generateResponse(prompt);
        final startIndex = response.indexOf('{');
        final endIndex = response.lastIndexOf('}');
        if (startIndex != -1 && endIndex != -1) {
          final cleanJson = response.substring(startIndex, endIndex + 1);
          final aiData = jsonDecode(cleanJson);

          if (data['namebn'] == null || data['namebn'].toString().isEmpty) {
            data['namebn'] = aiData['nameBn'] ?? '';
          }
          if (data['description'] == null ||
              data['description'].toString().isEmpty) {
            data['description'] = aiData['description'] ?? '';
          }
          if (data['descriptionbn'] == null ||
              data['descriptionbn'].toString().isEmpty) {
            data['descriptionbn'] = aiData['descriptionBn'] ?? '';
          }
          if (data['unit'] == null || data['unit'].toString().isEmpty) {
            data['unit'] = aiData['unit'] ?? 'pcs';
          }
          if (data['unitbn'] == null || data['unitbn'].toString().isEmpty) {
            data['unitbn'] = aiData['unitBn'] ?? 'পিস';
          }
          if (data['price'] == null ||
              data['price'].toString() == '0' ||
              data['price'].toString().isEmpty) {
            data['price'] = aiData['estimatedPrice'] ?? 0;
          }
          if (data['tags'] == null || data['tags'].toString().isEmpty) {
            data['tags'] = aiData['tags'] ?? '';
          }

          data['aiOptimized'] = true;
        }
      } catch (e) {
        debugPrint('AI Enhancement Error: $e');
      }
    }
  }

  Future<void> _uploadProduct(Map<String, dynamic> data) async {
    final fs = FirebaseFirestore.instance;
    final id =
        data['id']?.toString() ?? fs.collection(HubPaths.products).doc().id;

    final Map<String, dynamic> finalData = {
      'sku': data['sku']?.toString() ??
          'SKU-${DateTime.now().millisecondsSinceEpoch}',
      'name': data['name']?.toString() ?? 'Unnamed Product',
      'nameBn': data['namebn']?.toString() ?? '',
      'description': data['description']?.toString() ?? '',
      'descriptionBn': data['descriptionbn']?.toString() ?? '',
      'price': double.tryParse(data['price']?.toString() ?? '0') ?? 0.0,
      'oldPrice': double.tryParse(data['oldprice']?.toString() ?? '0') ?? 0.0,
      'stock': int.tryParse(data['stock']?.toString() ?? '0') ?? 0,
      'unit': data['unit']?.toString() ?? 'pcs',
      'unitBn': data['unitbn']?.toString() ?? 'পিস',
      'imageUrl': data['imageurl']?.toString() ?? '',
      'categoryId': data['categoryid']?.toString() ?? 'general',
      'categoryName': data['categoryname']?.toString() ?? 'General',
      'categoryNameBn': data['categorynamebn']?.toString() ?? 'সাধারণ',
      'brand': data['brand']?.toString() ?? '',
      'tags':
          data['tags']?.toString().split(',').map((e) => e.trim()).toList() ??
              [],
      'aiOptimized': data['aiOptimized'] ?? false,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    await fs
        .collection(HubPaths.products)
        .doc(id)
        .set(finalData, SetOptions(merge: true));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(10))),
          const SizedBox(height: 24),
          const Text('CSV BULK IMPORT',
              style: TextStyle(
                  fontWeight: FontWeight.w900, fontSize: 18, letterSpacing: 1)),
          const SizedBox(height: 8),
          const Text(
              'Upload product list with AI-assisted missing data filling.',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 32),
          if (_isProcessing) ...[
            LinearProgressIndicator(
                value: _progress,
                backgroundColor: Colors.grey[200],
                valueColor:
                    const AlwaysStoppedAnimation(AppStyles.primaryColor)),
            const SizedBox(height: 16),
            Text(_statusMessage ?? 'Processing...',
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: AppStyles.primaryColor)),
          ] else ...[
            if (_statusMessage != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12)),
                child: Text(_statusMessage!,
                    style: const TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                        fontSize: 12)),
              ),
            ElevatedButton.icon(
              onPressed: _pickAndProcessCsv,
              icon: const Icon(Icons.upload_file_rounded),
              label: const Text('SELECT CSV FILE'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppStyles.primaryColor,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 55),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15)),
              ),
            ),
            const SizedBox(height: 16),
            _buildFormatGuide(isDark),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildFormatGuide(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: isDark ? Colors.white10 : Colors.grey[100],
          borderRadius: BorderRadius.circular(15)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('REQUIRED HEADERS:',
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 10, letterSpacing: 1)),
          const SizedBox(height: 8),
          Text('name, price, stock, categoryName',
              style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white70 : Colors.black87)),
          const SizedBox(height: 12),
          const Text('OPTIONAL (AI WILL FILL):',
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 10,
                  letterSpacing: 1,
                  color: Colors.blue)),
          const SizedBox(height: 8),
          Text('nameBn, description, unit, tags',
              style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white70 : Colors.black87)),
        ],
      ),
    );
  }
}
