import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../di/providers.dart';
import '../../../utils/styles.dart';

class ResellerApplicationsTab extends ConsumerStatefulWidget {
  const ResellerApplicationsTab({super.key});
  @override
  ConsumerState<ResellerApplicationsTab> createState() =>
      _ResellerApplicationsTabState();
}

class _ResellerApplicationsTabState
    extends ConsumerState<ResellerApplicationsTab> with AutomaticKeepAliveClientMixin {
  
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DefaultTabController(
      length: 2,
      child: Column(children: [
        TabBar(
          labelColor:
              isDark ? AppStyles.darkPrimaryColor : AppStyles.primaryColor,
          unselectedLabelColor: Colors.grey,
          indicatorColor:
              isDark ? AppStyles.darkPrimaryColor : AppStyles.primaryColor,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
          tabs: const [
            Tab(text: 'PENDING APPS'),
            Tab(text: 'ACTIVE RESELLERS')
          ],
        ),
        const Expanded(
            child: TabBarView(
                children: [_ApplicationsView(), _ActiveResellersView()])),
      ]),
    );
  }
}

class _ApplicationsView extends ConsumerWidget {
  const _ApplicationsView();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('reseller_applications')
          .where('status', isEqualTo: 'Pending')
          .snapshots(),
      builder: (c, s) {
        if (s.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
        if (!s.hasData) return const Center(child: Text('No Data'));
        
        final apps = s.data!.docs;
        if (apps.isEmpty) {
          return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.assignment_turned_in_outlined, size: 48, color: isDark ? Colors.white10 : Colors.grey[200]),
                  const SizedBox(height: 12),
                  Text('No pending applications',
                      style: TextStyle(color: isDark ? Colors.white24 : Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ));
        }
        return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: apps.length,
            itemBuilder: (c, i) {
              final data = apps[i].data() as Map<String, dynamic>;
              return Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: isDark ? Colors.white10 : Colors.grey[200]!)
                ),
                child: ExpansionTile(
                  leading: const CircleAvatar(backgroundColor: Colors.orange, child: Icon(Icons.person, color: Colors.white, size: 20)),
                  title: Text(data['customerName'] ?? 'N/A',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  subtitle: Text('Shop: ${data['shopName']}', style: const TextStyle(fontSize: 12)),
                  children: [
                    Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _infoRow(Icons.inventory_2_outlined, 'Product Type', data['productType']),
                              _infoRow(Icons.history_outlined, 'Experience', data['experience']),
                              const SizedBox(height: 16),
                              Row(children: [
                                Expanded(
                                    child: ElevatedButton(
                                        onPressed: () => _update(
                                            ref, apps[i].id, 'Approved', data),
                                        style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.green,
                                            foregroundColor: Colors.white,
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                                        child: const Text('APPROVE', style: TextStyle(fontWeight: FontWeight.bold)))),
                                const SizedBox(width: 12),
                                Expanded(
                                    child: OutlinedButton(
                                        onPressed: () => _update(
                                            ref, apps[i].id, 'Rejected', data),
                                        style: OutlinedButton.styleFrom(
                                          side: const BorderSide(color: Colors.red),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))
                                        ),
                                        child: const Text('REJECT',
                                            style:
                                                TextStyle(color: Colors.red, fontWeight: FontWeight.bold)))),
                              ]),
                            ])),
                  ],
                ),
              );
            });
      },
    );
  }

  Widget _infoRow(IconData icon, String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 14, color: Colors.grey),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(color: Colors.grey, fontSize: 12)),
          Text(value?.toString() ?? 'N/A', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
        ],
      ),
    );
  }

  void _update(WidgetRef ref, String id, String status, Map data) =>
      ref.read(firestoreServiceProvider).updateResellerAppStatus(id, status,
          uid: data['uid'], shopName: data['shopName']);
}

class _ActiveResellersView extends ConsumerWidget {
  const _ActiveResellersView();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .where('role', isEqualTo: 'reseller')
          .snapshots(),
      builder: (c, s) {
        if (s.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
        if (!s.hasData) return const Center(child: Text('No Data'));
        final users = s.data!.docs;
        return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: users.length,
            itemBuilder: (c, i) {
              final u = users[i].data() as Map<String, dynamic>;
              return Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: isDark ? Colors.white10 : Colors.grey[200]!)
                ),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.teal.withValues(alpha: 0.1),
                    child: const Icon(Icons.store, color: Colors.teal, size: 20)
                  ),
                  title: Text(u['name'] ?? 'N/A',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  subtitle: Text('Shop: ${u['shopName'] ?? 'N/A'}', style: const TextStyle(fontSize: 12)),
                  trailing: IconButton(
                      icon: const Icon(Icons.remove_circle_outline,
                          color: Colors.red, size: 20),
                      onPressed: () => _remove(users[i].id)),
                ),
              );
            });
      },
    );
  }

  void _remove(String uid) => FirebaseFirestore.instance
      .collection('users')
      .doc(uid)
      .update({'role': 'customer'});
}
