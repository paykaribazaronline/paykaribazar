import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lottie/lottie.dart';
import 'package:image_picker/image_picker.dart';
import '../../di/providers.dart';
import '../../utils/styles.dart';
import '../../models/product_model.dart';
import '../home/widgets/home_widgets.dart';
import 'services/voice_search_service.dart';

class SearchScreen extends ConsumerStatefulWidget {
  final String? initialQuery;
  final String? initialAction;
  const SearchScreen({super.key, this.initialQuery, this.initialAction});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final TextEditingController _controller;
  final VoiceSearchService _voiceService = VoiceSearchService();
  final ImagePicker _picker = ImagePicker();
  String _query = '';
  bool _isListening = false;
  bool _isAnalyzingImage = false;

  @override
  void initState() {
    super.initState();
    _query = widget.initialQuery?.toLowerCase() ?? '';
    _controller = TextEditingController(text: widget.initialQuery);
    _voiceService.initSpeech();
    
    // Auto-trigger voice or image search if action parameter is provided
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.initialAction == 'voice') {
        _toggleListening();
      } else if (widget.initialAction == 'image') {
        _showImagePickerOptions();
      }
    });
  }

  void _onVoiceResult(String words) {
    setState(() {
      _query = words.toLowerCase();
      _controller.text = words;
      _isListening = false;
    });
  }

  void _toggleListening() {
    if (_isListening) {
      _voiceService.stopListening();
      setState(() => _isListening = false);
    } else {
      setState(() => _isListening = true);
      _voiceService.startListening(_onVoiceResult);
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(source: source);
      if (image == null) return;

      setState(() => _isAnalyzingImage = true);

      final aiService = ref.read(aiServiceProvider);
      final result = await aiService.analyzeImageForSearch(image);

      if (mounted) {
        setState(() {
          _query = result.toLowerCase();
          _controller.text = result;
          _isAnalyzingImage = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isAnalyzingImage = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ইমেজ অ্যানালাইসিস ব্যর্থ হয়েছে: $e')),
        );
      }
    }
  }

  void _showImagePickerOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt, color: AppStyles.primaryColor),
              title: const Text('ক্যামেরা থেকে ছবি তুলুন'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: AppStyles.primaryColor),
              title: const Text('গ্যালারি থেকে সিলেক্ট করুন'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final productsAsync = ref.watch(productsProvider);
    final featureFlags = ref.watch(featureFlagsProvider).value ?? const <String, dynamic>{};
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final voiceSearchFlag = featureFlags['voice_search'] as Map<String, dynamic>?;
    final imageSearchFlag = featureFlags['image_search'] as Map<String, dynamic>?;
    final voiceSearchEnabled = (voiceSearchFlag?['enabled'] ?? false) == true;
    final imageSearchEnabled = (imageSearchFlag?['enabled'] ?? false) == true;

    return Scaffold(
      backgroundColor: isDark ? AppStyles.darkBackgroundColor : AppStyles.backgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: TextField(
          controller: _controller,
          autofocus: widget.initialQuery == null,
          onChanged: (v) => setState(() => _query = v.toLowerCase()),
          style: TextStyle(color: isDark ? Colors.white : Colors.black87),
          decoration: InputDecoration(
            hintText: 'Search products...',
            hintStyle: const TextStyle(color: Colors.grey),
            border: InputBorder.none,
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_query.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _controller.clear();
                      setState(() => _query = '');
                    },
                  ),
                if (voiceSearchEnabled)
                  IconButton(
                    icon: Icon(_isListening ? Icons.mic : Icons.mic_none,
                        color: _isListening ? Colors.red : AppStyles.primaryColor),
                    onPressed: _toggleListening,
                  ),
                if (imageSearchEnabled)
                  IconButton(
                    icon: const Icon(Icons.camera_alt_outlined, color: AppStyles.primaryColor),
                    onPressed: _showImagePickerOptions,
                  ),
              ],
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          productsAsync.when(
            data: (productsMap) {
              final List<Product> allProducts = productsMap
                  .map((m) => Product.fromMap(m, m['id'] ?? ''))
                  .toList();

              final filtered = allProducts.where((p) {
                final name = p.name.toLowerCase();
                final nameBn = p.nameBn.toLowerCase();
                final desc = p.description.toLowerCase();
                final tags = p.tags.join(' ').toLowerCase();
                return name.contains(_query) ||
                    nameBn.contains(_query) ||
                    desc.contains(_query) ||
                    tags.contains(_query);
              }).toList();

              if (_query.isEmpty && widget.initialAction == null) {
                return _buildSuggestions();
              }
              if (filtered.isEmpty) return _buildNoResults();

              return GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: 0.7,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final product = filtered[index];
                  return ProductCard(product: product);
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
          ),
          if (_isListening && voiceSearchEnabled) _buildVoiceOverlay(),
          if (_isAnalyzingImage && imageSearchEnabled) _buildImageAnalysisOverlay(),
        ],
      ),
    );
  }

  Widget _buildVoiceOverlay() {
    return Container(
      color: Colors.black.withValues(alpha: 0.8),
      width: double.infinity,
      height: double.infinity,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Lottie.asset(
            'assets/lottie/voice_waves.json',
            width: 200,
            height: 200,
          ),
          const SizedBox(height: 20),
          const Text(
            'আমি শুনছি... বলুন',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
              fontFamily: 'HindSiliguri',
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'যেমন: "ভালো মানের চাল" বা "মোবাইল ফোন"',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 50),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white, size: 40),
            onPressed: _toggleListening,
          ),
        ],
      ),
    );
  }

  Widget _buildImageAnalysisOverlay() {
    return Container(
      color: Colors.black.withValues(alpha: 0.8),
      width: double.infinity,
      height: double.infinity,
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: AppStyles.primaryColor),
          SizedBox(height: 20),
          Text(
            'AI ছবি বিশ্লেষণ করছে...',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
              fontFamily: 'HindSiliguri',
            ),
          ),
          SizedBox(height: 10),
          Text(
            'দয়া করে অপেক্ষা করুন',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestions() =>
      const Center(child: Text('Type, use Voice or Image to search products'));
  Widget _buildNoResults() => const Center(child: Text('No products found'));
}

