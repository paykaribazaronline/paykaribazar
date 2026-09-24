import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../di/providers.dart';
import '../../utils/styles.dart';
import '../../models/product_model.dart';
import '../home/widgets/home_widgets.dart';
import 'providers/wishlist_provider.dart';

class WishlistScreen extends ConsumerWidget {
  const WishlistScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wishlistIds = ref.watch(wishlistProvider);
    final productsAsync = ref.watch(productsProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? AppStyles.darkBackgroundColor : AppStyles.backgroundColor,
      appBar: AppBar(
        title: const Text('পছন্দের তালিকা (Wishlist)', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: wishlistIds.isEmpty 
        ? const Center(child: Text('আপনার পছন্দের তালিকায় কিছু নেই'))
        : productsAsync.when(
            data: (allProductsMap) {
              final allProducts = allProductsMap.map((m) => Product.fromMap(m, m['id'] ?? '')).toList();
              final wishlistProducts = allProducts.where((p) => wishlistIds.contains(p.id)).toList();
              
              if (wishlistProducts.isEmpty) {
                return const Center(child: Text('পছন্দ করা পণ্যগুলো খুঁজে পাওয়া যায়নি'));
              }

              return GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: 0.75,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: wishlistProducts.length,
                itemBuilder: (context, index) => ProductCard(product: wishlistProducts[index]),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
          ),
    );
  }
}
