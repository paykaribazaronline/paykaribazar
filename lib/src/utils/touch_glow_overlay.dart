import 'package:flutter/material.dart';
import 'styles.dart';

class TouchGlowOverlay extends StatefulWidget {
  final Widget child;
  const TouchGlowOverlay({super.key, required this.child});

  @override
  State<TouchGlowOverlay> createState() => _TouchGlowOverlayState();
}

class _TouchGlowOverlayState extends State<TouchGlowOverlay> with SingleTickerProviderStateMixin {
  Offset? _tapPosition;
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _animation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() => _tapPosition = null);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap(PointerDownEvent event) {
    setState(() {
      _tapPosition = event.localPosition;
    });
    _controller.reset();
    _controller.forward();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _handleTap,
      behavior: HitTestBehavior.translucent,
      child: Stack(
        children: [
          widget.child,
          if (_tapPosition != null)
            Positioned(
              left: _tapPosition!.dx - 50,
              top: _tapPosition!.dy - 50,
              child: AnimatedBuilder(
                animation: _animation,
                builder: (context, child) {
                  return Opacity(
                    opacity: _animation.value,
                    child: Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            AppStyles.primaryColor.withValues(alpha: 0.4),
                            AppStyles.primaryColor.withValues(alpha: 0.1),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
