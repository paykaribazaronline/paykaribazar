import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../di/providers.dart';
import '../../utils/styles.dart';

class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _isBackingUp = false;
  bool _isLocalBackingUp = false;
  bool _isRestoring = false;
  String? _lastBackupTime;

  @override
  void initState() {
    super.initState();
    _loadLastBackupInfo();
  }

  void _loadLastBackupInfo() {
    final userData = ref.read(currentUserDataProvider).value;
    if (userData != null && userData['lastBackup'] != null) {
      final DateTime date = (userData['lastBackup'] as dynamic).toDate();
      setState(() => _lastBackupTime = DateFormat('dd MMM yyyy, hh:mm a').format(date));
    }
  }

  Future<void> _runBackup() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _isBackingUp = true);
    try {
      final backupService = ref.read(backupServiceProvider);
      await backupService.performFullBackup(user.uid);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('আপনার ডাটা সফলভাবে ব্যাকআপ করা হয়েছে।'),
            backgroundColor: Colors.green,
          ),
        );
        _loadLastBackupInfo();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ব্যাকআপ ব্যর্থ হয়েছে: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isBackingUp = false);
    }
  }

  Future<void> _runLocalBackup() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _isLocalBackingUp = true);
    try {
      final backupService = ref.read(backupServiceProvider);
      final file = await backupService.generateBackupFile(user.uid);
      final success = await backupService.uploadBackupToLocalServer(file, user.uid);

      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('আপনার ডাটা সফলভাবে লোকাল সার্ভারে ব্যাকআপ করা হয়েছে। ✅'),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('লোকাল ব্যাকআপ ব্যর্থ হয়েছে! সার্ভারটি চালু আছে কি না পরীক্ষা করুন। ❌'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('লোকাল ব্যাকআপ ব্যর্থ হয়েছে: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLocalBackingUp = false);
    }
  }

  Future<void> _runRestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ডাটা রিস্টোর নিশ্চিত করুন'),
        content: const Text('রিস্টোর করলে আপনার বর্তমান লোকাল ডাটা ক্লাউড ডাটা দিয়ে প্রতিস্থাপিত হবে। আপনি কি নিশ্চিত?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('না')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('হ্যাঁ, রিস্টোর করুন')),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isRestoring = true);
    try {
      final backupService = ref.read(backupServiceProvider);
      final history = await backupService.getBackupHistory().first;
      if (history.isEmpty) throw Exception('কোনো ব্যাকআপ পাওয়া যায়নি');
      final selected = history.first;
      final fileUrl = selected['fileUrl'] as String;
      await backupService.restoreFromBackup(fileUrl);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('আপনার ডাটা সফলভাবে রিস্টোর করা হয়েছে।'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('রিস্টোর ব্যর্থ হয়েছে: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isRestoring = false);
    }
  }

  Future<void> _downloadHistory() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final orders = ref.read(ordersProvider).value?.where((o) => o['customerUid'] == user.uid).toList() ?? [];
    
    final pdf = pw.Document();
    pdf.addPage(
      pw.Page(
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Order History - Paykari Bazar', style: const pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 20),
              pw.TableHelper.fromTextArray(
                headers: ['Order ID', 'Date', 'Amount', 'Status'],
                data: orders.map((o) => [
                  o['id'].toString().substring(0, 8),
                  o['createdAt'] != null ? DateFormat('dd/MM/yyyy').format(o['createdAt'].toDate()) : 'N/A',
                  'Tk ${o['totalAmount']}',
                  o['status'] ?? 'Pending'
                ]).toList(),
              ),
            ],
          );
        },
      ),
    );

    await Printing.layoutPdf(onLayout: (PdfPageFormat format) async => pdf.save());
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? AppStyles.darkBackgroundColor : AppStyles.backgroundColor,
      appBar: AppBar(title: const Text('ডাটা ও হিস্ট্রি (Data & History)')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            _buildActionCard(
              title: 'ক্লাউড ব্যাকআপ',
              subtitle: 'আপনার সকল তথ্য নিরাপদ রাখতে ক্লাউডে ব্যাকআপ করুন।',
              icon: Icons.cloud_upload_rounded,
              color: AppStyles.primaryColor,
              isDark: isDark,
              onTap: _isBackingUp ? null : _runBackup,
              extra: _lastBackupTime != null ? 'সর্বশেষ: $_lastBackupTime' : null,
              isLoading: _isBackingUp,
            ),
            const SizedBox(height: 20),
            _buildActionCard(
              title: 'লোকাল সিঙ্ক ব্যাকআপ',
              subtitle: 'আপনার লোকাল ডেভেলপমেন্ট সিঙ্ক সার্ভারে ব্যাকআপ পাঠান।',
              icon: Icons.computer_rounded,
              color: Colors.purpleAccent,
              isDark: isDark,
              onTap: _isLocalBackingUp ? null : _runLocalBackup,
              isLoading: _isLocalBackingUp,
            ),
            const SizedBox(height: 20),
            _buildActionCard(
              title: 'ডাটা রিস্টোর (Restore)',
              subtitle: 'ক্লাউড থেকে আপনার পুরনো ডাটা ও সেটিংস ফিরিয়ে আনুন।',
              icon: Icons.cloud_download_rounded,
              color: Colors.blueAccent,
              isDark: isDark,
              onTap: _isRestoring ? null : _runRestore,
              isLoading: _isRestoring,
            ),
            const SizedBox(height: 20),
            _buildActionCard(
              title: 'অর্ডার হিস্ট্রি ডাউনলোড',
              subtitle: 'আপনার সকল অর্ডারের তালিকা PDF হিসেবে ডাউনলোড করুন।',
              icon: Icons.picture_as_pdf_rounded,
              color: Colors.redAccent,
              isDark: isDark,
              onTap: _downloadHistory,
            ),
            const Spacer(),
            const Text(
              'তথ্য গোপনীয়তা নীতিমালা মেনে আপনার ডাটা প্রসেস করা হয়।',
              style: TextStyle(color: Colors.grey, fontSize: 10),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildActionCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required bool isDark,
    required VoidCallback? onTap,
    VoidCallback? onLongPress,
    String? extra,
    bool isLoading = false,
  }) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E293B) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10)],
          border: Border.all(color: color.withValues(alpha: 0.1)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
              child: isLoading
                  ? SizedBox(height: 24, width: 24, child: CircularProgressIndicator(color: color, strokeWidth: 2))
                  : Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                  if (extra != null) ...[
                    const SizedBox(height: 8),
                    Text(extra, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
                  ],
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}
