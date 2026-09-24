import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/constants/paths.dart';
import '../../../core/services/cloud_functions_client.dart';
import '../../../models/product_model.dart';

class ProductService {
  ProductService({CloudFunctionsClient? cf, FirebaseFirestore? firestore})
      : _cf = cf ?? cloudFunctionsClient,
        _firestore = firestore ?? FirebaseFirestore.instance;

  final CloudFunctionsClient _cf;
  final FirebaseFirestore _firestore;

  Stream<List<Product>> getProducts() {
    return _firestore.collection(HubPaths.products).snapshots().map(
      (snap) => snap.docs.map((doc) => Product.fromMap(doc.data(), doc.id)).toList());
  }

  /// DNA ENFORCED: Paginated fetching to optimize performance and reduce Firestore reads
  /// বাংলা: ডাটাবেস রিড কমাতে এবং পারফরম্যান্স বাড়াতে প্যাগিনেশন ব্যবহার করা হয়েছে
  Future<QuerySnapshot<Map<String, dynamic>>> getProductsPaginated({
    DocumentSnapshot? lastDocument,
    int limit = 10,
    String? categoryId,
  }) async {
    Query<Map<String, dynamic>> query = _firestore.collection(HubPaths.products)
        .orderBy('createdAt', descending: true);

    if (categoryId != null) {
      query = query.where('categoryId', isEqualTo: categoryId);
    }

    if (lastDocument != null) {
      query = query.startAfterDocument(lastDocument);
    }

    return query.limit(limit).get();
  }

  Future<Product?> getProductById(String id) async {
    final doc = await _firestore.collection(HubPaths.products).doc(id).get();
    if (doc.exists) {
      return Product.fromMap(doc.data()!, doc.id);
    }
    return null;
  }

  /// Client-side filter stream — kept for backwards compatibility but the
  /// authoritative search now runs on the backend `searchProducts` callable
  /// (see [searchProductsServer]). The old implementation fetches every
  /// product doc and filters in memory, which does not scale beyond ~500
  /// SKUs and was identified as a P1 in the security audit.
  @Deprecated('Use searchProductsServer() — backend synonym-aware search. '
      'This stream fetches all products and filters client-side.')
  Stream<List<Product>> searchProducts(String query) {
    // Basic implementation, usually filtered in UI or via Algolia/Elasticsearch for scale
    return getProducts().map((products) => 
      products.where((p) => p.matchesSearch(query)).toList());
  }

  /// Server-side search via the `searchProducts` callable (see
  /// `functions/src/search/productSearch.ts`). Returns a list of hits with
  /// `{id, name, nameBn, sku, brand, category, imageUrl, price, stock, score}`
  /// — the consumer typically fetches the full `Product` doc by id via
  /// [getProductById] for display. The backend applies a synonym map and
  /// caps the scan at 500 docs.
  Future<List<Product>> searchProductsServer(String query,
      {int limit = 50, String? category, String? brand, int? minStock}) async {
    final hits = await _cf.searchProducts(query,
        limit: limit, category: category, brand: brand, minStock: minStock);
    final out = <Product>[];
    for (final h in hits) {
      final id = h['id'] as String?;
      if (id == null) continue;
      // Construct a minimal Product from the hit. Callers wanting the full
      // doc (description, variants, etc.) should follow up with
      // [getProductById].
      out.add(Product.fromMap({
        'id': id,
        'name': h['name'] ?? '',
        'nameBn': h['nameBn'] ?? '',
        'sku': h['sku'] ?? '',
        'brand': h['brand'] ?? '',
        'categoryName': h['category'] ?? '',
        'imageUrl': h['imageUrl'] ?? '',
        'price': h['price'] ?? 0,
        'stock': h['stock'] ?? 0,
        'createdAt': Timestamp.now(),
        'updatedAt': Timestamp.now(),
      }, id));
    }
    return out;
  }

  /// Live stream of the `reservedStock` field on `products/{productId}`.
  /// The new `firestore.rules` (Task ID 7-8) allow public reads on products
  /// — including `reservedStock` — so the client can show a real-time
  /// "X reserved" badge in the cart / PDP without polling.
  Stream<int> watchReservedStock(String productId) {
    return _firestore
        .collection(HubPaths.products)
        .doc(productId)
        .snapshots()
        .map((snap) {
      if (!snap.exists) return 0;
      final data = snap.data() ?? const <String, dynamic>{};
      return (data['reservedStock'] as num?)?.toInt() ?? 0;
    });
  }

  Stream<List<Product>> filterByCategory(String categoryId) {
    return _firestore.collection(HubPaths.products)
        .where('categoryId', isEqualTo: categoryId)
        .snapshots()
        .map((snap) => snap.docs.map((doc) => Product.fromMap(doc.data(), doc.id)).toList());
  }

  // `updateProductStock` was removed — stock, reservedStock and soldStock
  // are now server-only fields per the new `firestore.rules` (Task ID 7-8).
  // Inventory mutations happen exclusively through the `reserveStock`,
  // `releaseReservation`, and `commitReservation` Cloud Functions (Task ID 9).
}
