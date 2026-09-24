import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:paykari_bazar/src/di/providers.dart';
import 'package:paykari_bazar/src/services/role_simulator_provider.dart';
import 'package:paykari_bazar/src/core/firebase/firestore_paginator.dart';
import 'package:intl/intl.dart';
import 'package:flutter/foundation.dart';
import '../../utils/styles.dart';
import '../../utils/app_strings.dart';
import 'order_details_screen.dart';

class OrdersScreen extends ConsumerStatefulWidget {
  const OrdersScreen({super.key});

  @override
  ConsumerState<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends ConsumerState<OrdersScreen> {
  String _activeFilter = 'All';
  FirestorePaginator<dynamic>? _paginator;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _initPaginator();
    _scrollController.addListener(_onScroll);
  }

  void _initPaginator() {
    final simulatedUid = ref.read(simulatedUserUidProvider);
    final authState = ref.read(authStateProvider);
    final uid = simulatedUid ?? authState.value?.uid;

    // Properly dispose the previous paginator instance to prevent memory leaks
    _paginator?.dispose();

    final newPaginator = FirestorePaginator<dynamic>(
      collectionPath: 'orders',
      pageSize: 10,
      queryBuilder: (query) {
        // Changed filter key from 'buyerId' to 'customerUid' to match security rules and schema
        var q = query.where('customerUid', isEqualTo: uid);
        if (_activeFilter != 'All') {
          q = q.where('status', isEqualTo: _activeFilter);
        }
        return q;
      },
      fromFirestore: (doc) {
        final data = doc.data() as Map<String, dynamic>;
        data['id'] = doc.id;
        return data;
      },
    );

    _paginator = newPaginator;

    // Initial load
    newPaginator.fetchFirstPage().then((_) {
      if (mounted) setState(() {});
    }).catchError((error) {
      if (kDebugMode) debugPrint('❌ Orders page load failed: $error');
      if (mounted) setState(() {});
    });
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      final paginator = _paginator;
      if (paginator != null && !paginator.isLoading && paginator.hasMore) {
        paginator.fetchNextPage().then((_) {
          if (mounted) setState(() {});
        }).catchError((error) {
          if (kDebugMode) debugPrint('❌ Orders page fetchNextPage failed: $error');
          if (mounted) setState(() {});
        });
      }
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _paginator?.dispose();
    super.dispose();
  }

  String _t(String k) =>
      AppStrings.get(k, ref.watch(languageProvider.select((l) => l.languageCode)));

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final paginator = _paginator;

    return Scaffold(
      backgroundColor:
          isDark ? AppStyles.darkBackgroundColor : AppStyles.backgroundColor,
      appBar: AppBar(
        title: Text(_t('myOrders'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Column(
        children: [
          _buildFilterChips(isDark),
          Expanded(
            child: paginator == null || (paginator.items.isEmpty && paginator.isLoading)
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: () async {
                      await paginator.fetchFirstPage();
                      if (mounted) setState(() {});
                    },
                    child: paginator.items.isEmpty
                        ? Center(child: Text(_t('noOrdersFound')))
                        : ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.all(16),
                            itemCount: paginator.items.length +
                                (paginator.hasMore ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index == paginator.items.length) {
                                return const Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(20),
                                    child: CircularProgressIndicator(),
                                  ),
                                );
                              }
                              return _buildOrderTile(paginator.items[index], isDark);
                            },
                          ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChips(bool isDark) {
    final filters = ['All', 'Pending', 'Processing', 'Delivered', 'Cancelled'];
    return SizedBox(
      height: 50,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: filters.length,
        itemBuilder: (context, index) {
          final isSelected = _activeFilter == filters[index];
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(filters[index]),
              selected: isSelected,
              onSelected: (v) {
                if (v) {
                  setState(() {
                    _activeFilter = filters[index];
                    // Reset scroll position to top when filter changes
                    if (_scrollController.hasClients) {
                      _scrollController.jumpTo(0);
                    }
                    _initPaginator(); // Re-initialize with new filter
                  });
                }
              },
              selectedColor: AppStyles.primaryColor,
              labelStyle:
                  TextStyle(color: isSelected ? Colors.white : (isDark ? Colors.white : Colors.black)),
            ),
          );
        },
      ),
    );
  }

  Widget _buildOrderTile(Map<String, dynamic> order, bool isDark) {
    final status = order['status']?.toString() ?? 'Pending';
    final total = (order['totalAmount'] as num? ?? order['total'] as num? ?? 0.0).toDouble();
    final id = order['id']?.toString() ?? '';
    final createdAtStr = order['createdAt']?.toString();
    
    DateTime? orderDate;
    if (order['createdAt'] is Timestamp) {
      orderDate = (order['createdAt'] as Timestamp).toDate();
    } else if (createdAtStr != null) {
      orderDate = DateTime.tryParse(createdAtStr);
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      child: ListTile(
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (c) => OrderDetailsScreen(orderId: id))),
        title: Text('Order #$id',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        subtitle: Text(
            orderDate != null
                ? 'Placed on ${DateFormat('dd MMM, yyyy • hh:mm a').format(orderDate)}'
                : 'Date N/A',
            style: const TextStyle(fontSize: 11)),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('৳${total.toStringAsFixed(0)}',
                style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: AppStyles.primaryColor)),
            Text(status,
                style: TextStyle(
                    color: _getStatusColor(status),
                    fontWeight: FontWeight.bold,
                    fontSize: 10)),
          ],
        ),
      ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'Pending':
        return Colors.orange;
      case 'Processing':
        return Colors.blue;
      case 'Delivered':
        return Colors.green;
      case 'Cancelled':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }
}
