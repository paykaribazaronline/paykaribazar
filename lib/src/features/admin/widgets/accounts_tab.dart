import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../../../utils/styles.dart';
import '../../../services/language_provider.dart';
import '../../../utils/app_strings.dart';
import '../../../models/user_model.dart';
import '../../../di/providers.dart';

class ConstraintSolver {
  static bool canOpenDialog(WidgetRef ref) {
    final userData = ref.read(currentUserDataProvider).value;
    if (userData == null) return false;
    final user = UserModel.fromMap(userData);
    return user.role == UserRole.admin;
  }

  static String? validateExpense(String title, String amountStr) {
    if (title.trim().isEmpty) return 'Title is required';
    final amount = double.tryParse(amountStr);
    if (amount == null || amount <= 0) return 'Enter a valid amount';
    return null;
  }

  static String? validateStorageLimit(String limitStr) {
    final limit = double.tryParse(limitStr);
    if (limit == null || limit <= 0) return 'Enter a valid limit in MB';
    return null;
  }
}

class AccountsTab extends ConsumerStatefulWidget {
  const AccountsTab({super.key});
  @override
  ConsumerState<AccountsTab> createState() => _AccountsTabState();
}

class _AccountsTabState extends ConsumerState<AccountsTab> with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabCtrl,
          indicatorColor: AppStyles.primaryColor,
          labelColor: AppStyles.primaryColor,
          unselectedLabelColor: Colors.grey,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          tabs: const [
            Tab(text: 'USER ACCOUNTS'),
            Tab(text: 'EXPENSES & REVENUE'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabCtrl,
            children: [
              _AccountsUserSubTab(),
              const _AccountsFinanceSubTab(),
            ],
          ),
        ),
      ],
    );
  }
}

class _AccountsUserSubTab extends ConsumerStatefulWidget {
  @override
  ConsumerState<_AccountsUserSubTab> createState() => _AccountsUserSubTabState();
}

class _AccountsUserSubTabState extends ConsumerState<_AccountsUserSubTab> {
  String _searchQuery = '';
  String _t(String k) => AppStrings.get(k, ref.watch(languageProvider).languageCode);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildUserManagement(isDark),
        const SizedBox(height: 100),
      ],
    );
  }

  Widget _buildUserManagement(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('USER & STORAGE MANAGEMENT', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11, color: Colors.grey, letterSpacing: 1.2)),
            Icon(Icons.manage_accounts_rounded, size: 16, color: Colors.grey),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          onChanged: (v) => setState(() => _searchQuery = v.trim().toLowerCase()),
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: _t('searchUserHint'),
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            filled: true,
            fillColor: isDark ? AppStyles.darkSurfaceColor : Colors.white,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(),
          ),
        ),
        const SizedBox(height: 12),
        StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance.collection('users').snapshots(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const LinearProgressIndicator();
            
            final docs = snapshot.data!.docs.where((doc) {
              final data = doc.data() as Map<String, dynamic>;
              final name = (data['name'] ?? '').toString().toLowerCase();
              final phone = (data['phone'] ?? '').toString().toLowerCase();
              return name.contains(_searchQuery) || phone.contains(_searchQuery);
            }).toList();

            return Container(
              decoration: BoxDecoration(
                color: isDark ? AppStyles.darkSurfaceColor : Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: isDark ? Colors.white10 : Colors.grey[200]!),
              ),
              child: docs.isEmpty 
                ? const Center(child: Padding(padding: EdgeInsets.all(40), child: Text('No users found.')))
                : ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: docs.length > 15 ? 15 : docs.length,
                separatorBuilder: (c, i) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final data = docs[index].data() as Map<String, dynamic>;
                  final double limit = ((data['storageLimit'] ?? (50.0 * 1024 * 1024)).toDouble()) / (1024 * 1024);
                  final double used = ((data['usedStorage'] ?? 0.0).toDouble()) / (1024 * 1024);
                  final String role = data['role'] ?? 'customer';

                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: CircleAvatar(
                      radius: 22,
                      backgroundColor: AppStyles.primaryColor.withValues(alpha: 0.1),
                      child: Text((data['name'] ?? 'U')[0].toUpperCase(), style: const TextStyle(color: AppStyles.primaryColor, fontWeight: FontWeight.bold)),
                    ),
                    title: Row(
                      children: [
                        Expanded(child: Text(data['name'] ?? _t('guest'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                        _roleBadge(role),
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Text(data['phone'] ?? 'No Phone', style: const TextStyle(fontSize: 11, color: Colors.blueGrey, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: LinearProgressIndicator(
                                value: limit > 0 ? (used / limit).clamp(0.0, 1.0) : 0,
                                backgroundColor: isDark ? Colors.white10 : Colors.grey[100],
                                color: (used / limit) > 0.9 ? Colors.red : AppStyles.primaryColor,
                                minHeight: 4,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text('${used.toStringAsFixed(1)}MB', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.settings_suggest_rounded, color: Colors.indigo, size: 22),
                          onPressed: () => _showUserRoleAndSettings(docs[index]),
                          tooltip: 'User Settings',
                        ),
                      ],
                    ),
                  );
                },
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _roleBadge(String role) {
    Color color = Colors.grey;
    if (role == 'admin') {
      color = Colors.purple;
    } else if (role == 'staff') {
      color = Colors.blue;
    } else if (role == 'reseller') {
      color = Colors.teal;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: color.withValues(alpha: 0.2))),
      child: Text(role.toUpperCase(), style: TextStyle(color: color, fontSize: 8, fontWeight: FontWeight.w900)),
    );
  }

  void _showUserRoleAndSettings(DocumentSnapshot doc) {
    if (!ConstraintSolver.canOpenDialog(ref)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Access denied. Admin only.')));
      return;
    }
    final data = doc.data() as Map<String, dynamic>;
    final String currentRole = data['role'] ?? 'customer';
    final double currentLimitBytes = (data['storageLimit'] ?? (50.0 * 1024 * 1024)).toDouble();
    final double currentLimitMB = currentLimitBytes / (1024 * 1024);
    final storageCtrl = TextEditingController(text: currentLimitMB.toInt().toString());

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (c) => StatefulBuilder(builder: (context, setModalState) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, top: 24, left: 24, right: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Edit User Role & Settings', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
            const SizedBox(height: 20),
            
            const Text('Change Account Role', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: UserRole.values.map((role) {
                final isSelected = currentRole == role.name;
                return ChoiceChip(
                  label: Text(role.name.toUpperCase(), style: const TextStyle(fontSize: 10)),
                  selected: isSelected,
                  onSelected: (val) async {
                    if (val) {
                      await FirebaseFirestore.instance.collection('users').doc(doc.id).update({'role': role.name});
                      if (!c.mounted) return;
                      Navigator.pop(c);
                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User role updated!')));
                    }
                  },
                );
              }).toList(),
            ),
            
            const SizedBox(height: 24),
            const Text('Update Cloud Storage Limit', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 10),
            TextField(
              controller: storageCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Limit in MB', border: OutlineInputBorder(), suffixText: 'MB'),
            ),
            
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity, height: 55,
              child: ElevatedButton(
                onPressed: () async {
                  final newLimitMB = double.tryParse(storageCtrl.text);
                  if (newLimitMB != null) {
                    final newLimitBytes = newLimitMB * 1024 * 1024;
                    await FirebaseFirestore.instance.collection('users').doc(doc.id).update({'storageLimit': newLimitBytes});
                    if (!c.mounted) return;
                    Navigator.pop(c);
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: AppStyles.primaryColor, foregroundColor: Colors.white),
                child: const Text('SAVE SETTINGS', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      )),
    );
  }
}

class _AccountsFinanceSubTab extends ConsumerStatefulWidget {
  const _AccountsFinanceSubTab();
  @override
  ConsumerState<_AccountsFinanceSubTab> createState() => _AccountsFinanceSubTabState();
}

class _AccountsFinanceSubTabState extends ConsumerState<_AccountsFinanceSubTab> {
  bool _isAllTime = false;

  String _t(String k) => AppStrings.get(k, ref.watch(languageProvider).languageCode);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildFinancialToggle(isDark),
          const SizedBox(height: 20),
          _buildFinancialSummary(isDark),
          const SizedBox(height: 24),
          _buildAutomatedExpenditure(isDark),
          const SizedBox(height: 24),
          _buildManualExpenseList(isDark),
          const SizedBox(height: 100),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddExpenseDialog(context),
        label: Text(_t('addExpense').toUpperCase()),
        icon: const Icon(Icons.add_card_rounded),
        backgroundColor: Colors.redAccent,
      ),
    );
  }

  Widget _buildFinancialToggle(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: isDark ? Colors.white10 : Colors.grey[200], borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Expanded(child: _toggleBtn('THIS MONTH', !_isAllTime, () => setState(() => _isAllTime = false))),
          Expanded(child: _toggleBtn('ALL TIME', _isAllTime, () => setState(() => _isAllTime = true))),
        ],
      ),
    );
  }

  Widget _toggleBtn(String text, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(color: active ? AppStyles.primaryColor : Colors.transparent, borderRadius: BorderRadius.circular(10)),
        child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: active ? Colors.white : Colors.grey, fontWeight: FontWeight.bold, fontSize: 10)),
      ),
    );
  }

  Widget _buildFinancialSummary(bool isDark) {
    Query ordersQuery = FirebaseFirestore.instance.collection('orders').where('status', isEqualTo: 'Delivered');
    
    if (!_isAllTime) {
      final now = DateTime.now();
      final monthStart = DateTime(now.year, now.month);
      ordersQuery = ordersQuery.where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(monthStart));
    }

    return StreamBuilder<QuerySnapshot>(
      stream: ordersQuery.snapshots(),
      builder: (c, s) {
        double revenue = 0;
        if (s.hasData) {
          for (var doc in s.data!.docs) {
            revenue += ((doc.data() as Map)['totalAmount'] ?? 0).toDouble();
          }
        }
        return GridView.count(
          crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 1.5,
          children: [
            _statCard('GROSS REVENUE', '৳${revenue.toInt()}', Colors.green, Icons.trending_up_rounded, isDark),
            _statCard('TOTAL ORDERS', '${s.hasData ? s.data!.docs.length : 0}', Colors.blue, Icons.shopping_bag_rounded, isDark),
          ],
        );
      },
    );
  }

  Widget _buildAutomatedExpenditure(bool isDark) {
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('AUTOMATED SYSTEM EXPENDITURE', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11, color: Colors.grey, letterSpacing: 1.2)),
        const SizedBox(height: 12),
        
        // Commissions Stream
        StreamBuilder<QuerySnapshot>(
          stream: _isAllTime 
            ? FirebaseFirestore.instance.collection('staff_commissions').snapshots()
            : FirebaseFirestore.instance.collection('staff_commissions').where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(monthStart)).snapshots(),
          builder: (context, snapshot) {
            double totalComm = 0;
            if (snapshot.hasData) {
              for (var doc in snapshot.data!.docs) {
                totalComm += ((doc.data() as Map)['amount'] ?? 0).toDouble();
              }
            }
            return _expandableExpenseCard('Staff Commissions', totalComm, Icons.people_alt_rounded, Colors.orange, isDark, snapshot.data?.docs ?? []);
          }
        ),
        
        const SizedBox(height: 12),
        
        // Discounts (Loyalty & Coupons)
        StreamBuilder<QuerySnapshot>(
          stream: _isAllTime
            ? FirebaseFirestore.instance.collection('orders').where('discountAmount', isGreaterThan: 0).snapshots()
            : FirebaseFirestore.instance.collection('orders').where('discountAmount', isGreaterThan: 0).where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(monthStart)).snapshots(),
          builder: (context, snapshot) {
            double totalDiscount = 0;
            if (snapshot.hasData) {
              for (var doc in snapshot.data!.docs) {
                totalDiscount += ((doc.data() as Map)['discountAmount'] ?? 0).toDouble();
              }
            }
            return _expandableExpenseCard('Campaign Discounts', totalDiscount, Icons.confirmation_number_rounded, Colors.purple, isDark, snapshot.data?.docs ?? []);
          }
        ),
      ],
    );
  }

  Widget _expandableExpenseCard(String title, double amount, IconData icon, Color color, bool isDark, List<DocumentSnapshot> details) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppStyles.darkSurfaceColor : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isDark ? Colors.white10 : Colors.grey[200]!),
      ),
      child: ExpansionTile(
        leading: Icon(icon, color: color, size: 20),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        trailing: Text('৳${amount.toInt()}', style: const TextStyle(fontWeight: FontWeight.w900, color: Colors.redAccent)),
        children: [
          if (details.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No data found.', style: TextStyle(fontSize: 11, color: Colors.grey)))
          else ...details.map((d) {
            final data = d.data() as Map;
            final date = (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
            return ListTile(
              dense: true,
              title: Text(data['staffName'] ?? data['orderId'] ?? 'Entry', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              subtitle: Text(DateFormat('dd MMM, yyyy').format(date), style: const TextStyle(fontSize: 9)),
              trailing: Text('৳${data['amount'] ?? data['discountAmount'] ?? 0}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            );
          }).take(5),
          if (details.length > 5) const Padding(padding: EdgeInsets.all(8), child: Text('Showing last 5 entries', style: TextStyle(fontSize: 8, color: Colors.grey))),
        ],
      ),
    );
  }

  Widget _buildManualExpenseList(bool isDark) {
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month);
    Query expensesQuery = FirebaseFirestore.instance.collection('expenses').orderBy('createdAt', descending: true);
    
    if (!_isAllTime) {
      expensesQuery = expensesQuery.where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(monthStart));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('MANUAL BUSINESS EXPENSES', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11, color: Colors.grey, letterSpacing: 1.2)),
      const SizedBox(height: 12),
      StreamBuilder<QuerySnapshot>(
        stream: expensesQuery.snapshots(),
        builder: (c, s) {
          if (!s.hasData) return const LinearProgressIndicator();
          if (s.data!.docs.isEmpty) return const Center(child: Padding(padding: EdgeInsets.all(20), child: Text('No manual expenses recorded.', style: TextStyle(fontSize: 12, color: Colors.grey))));
          return Column(children: s.data!.docs.map((d) {
            final data = d.data() as Map;
            final date = (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
            return Card(
              child: ListTile(
                leading: const CircleAvatar(backgroundColor: Colors.redAccent, child: Icon(Icons.outbound_rounded, size: 18, color: Colors.white)),
                title: Text(data['title'] ?? 'Expense', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                subtitle: Text(DateFormat('dd MMM, yyyy').format(date), style: const TextStyle(fontSize: 11)),
                trailing: Text('-৳${data['amount'] ?? 0}', style: const TextStyle(fontWeight: FontWeight.w900, color: Colors.red)),
              ),
            );
          }).toList());
        },
      ),
    ]);
  }

  Widget _statCard(String l, String v, Color c, IconData i, bool d) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: d ? AppStyles.darkSurfaceColor : Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: d ? Colors.white10 : Colors.grey[200]!)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(i, color: c, size: 20), const SizedBox(height: 8),
      Text(v, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
      Text(l, style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold)),
    ]),
  );

  void _showAddExpenseDialog(BuildContext context) {
    final titleCtrl = TextEditingController(), amountCtrl = TextEditingController();
    showDialog(context: context, builder: (c) => AlertDialog(
      title: Text(_t('addExpense')),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: titleCtrl, decoration: InputDecoration(labelText: _t('expenseTitle'))),
        TextField(controller: amountCtrl, decoration: InputDecoration(labelText: _t('amount')), keyboardType: TextInputType.number),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(_t('cancel').toUpperCase())),
        ElevatedButton(onPressed: () async {
          await FirebaseFirestore.instance.collection('expenses').add({
            'title': titleCtrl.text.trim(),
            'amount': double.tryParse(amountCtrl.text) ?? 0,
            'createdAt': FieldValue.serverTimestamp(),
          });
          if (!c.mounted) return;
          Navigator.pop(c);
        }, child: Text(_t('save').toUpperCase())),
      ],
    ));
  }
}
