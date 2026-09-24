import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import 'styles.dart';

/// Centralized Lottie Asset Management
class AppLottie {
  static const String root = 'assets/lottie';
  
  static const String welcome = '$root/welcome.json';
  static const String emptyCart = '$root/empty cart.json';
  static const String processing = '$root/processing.json';
  static const String emptyOrder = '$root/empty order.json';
  static const String emptyWishlist = '$root/empty wishlist.json';
  static const String emptyOrderList = '$root/empty orderlist.json';
  static const String orderSuccess = '$root/orderSuccessful.json';
  static const String paymentSuccess = '$root/paymentSuccessful.json';
}

/// A robust image widget that handles loading, errors, and caching.
class AppImage extends StatelessWidget {
  final String? imageUrl;
  final String altQuery;
  final double? width;
  final double? height;
  final BoxFit fit;
  final int? memCacheWidth;

  const AppImage({
    super.key,
    required this.imageUrl,
    required this.altQuery,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.memCacheWidth,
  });

  @override
  Widget build(BuildContext context) {
    if (imageUrl == null || imageUrl!.isEmpty) {
      return _errorWidget();
    }

    return CachedNetworkImage(
      imageUrl: imageUrl!,
      width: width,
      height: height,
      fit: fit,
      memCacheWidth: memCacheWidth,
      placeholder: (context, url) => Shimmer.fromColors(
        baseColor: Colors.grey[300]!,
        highlightColor: Colors.grey[100]!,
        child: Container(
          width: width ?? double.infinity,
          height: height ?? double.infinity,
          color: Colors.white,
        ),
      ),
      errorWidget: (context, url, error) => _errorWidget(),
    );
  }

  Widget _errorWidget() {
    return Container(
      width: width,
      height: height,
      color: Colors.grey[100],
      child: Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          color: Colors.grey[400],
          size: (width != null && width! < 50) ? 20 : 30,
        ),
      ),
    );
  }
}

class EmptyStatePlaceholder extends StatelessWidget {
  final String message;
  final String? lottieAsset;
  final IconData? icon;
  final String? subMessage;
  final Widget? action;

  const EmptyStatePlaceholder({
    super.key, 
    required this.message, 
    this.lottieAsset,
    this.icon,
    this.subMessage,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 40),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (lottieAsset != null)
              Lottie.asset(
                lottieAsset!, 
                height: 220,
                repeat: true,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => _fallbackIcon(),
              )
            else
              _fallbackIcon(),
            const SizedBox(height: 32),
            Text(
              message, 
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
              ),
            ),
            if (subMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                subMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isDark ? Colors.white60 : Colors.grey[600],
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 32),
              action!,
            ],
          ],
        ),
      ),
    );
  }

  Widget _fallbackIcon() {
    return Container(
      padding: const EdgeInsets.all(30),
      decoration: BoxDecoration(
        color: AppStyles.primaryColor.withValues(alpha: 0.05),
        shape: BoxShape.circle,
      ),
      child: Icon(
        icon ?? Icons.shopping_basket_outlined, 
        size: 80, 
        color: AppStyles.primaryColor.withValues(alpha: 0.2),
      ),
    );
  }
}

/// A Premium Button with scale animation micro-interaction
class ScaleButton extends StatefulWidget {
  final VoidCallback? onTap;
  final Widget child;
  final Duration duration;

  const ScaleButton({
    super.key,
    required this.onTap,
    required this.child,
    this.duration = const Duration(milliseconds: 150),
  });

  @override
  State<ScaleButton> createState() => _ScaleButtonState();
}

class _ScaleButtonState extends State<ScaleButton> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => widget.onTap != null ? _controller.forward() : null,
      onTapUp: (_) => widget.onTap != null ? _controller.reverse() : null,
      onTapCancel: () => widget.onTap != null ? _controller.reverse() : null,
      onTap: widget.onTap,
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: widget.child,
      ),
    );
  }
}
