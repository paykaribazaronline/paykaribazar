import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../di/providers.dart';
import '../../utils/styles.dart';

class PrivateChatScreen extends ConsumerStatefulWidget {
  final String chatId;
  final String receiverName;
  final String? receiverId;
  final bool isStaffChat;
  
  const PrivateChatScreen({
    super.key,
    required this.chatId,
    required this.receiverName,
    this.receiverId,
    required this.isStaffChat,
  });

  @override
  ConsumerState<PrivateChatScreen> createState() => _PrivateChatScreenState();
}

class _PrivateChatScreenState extends ConsumerState<PrivateChatScreen> {
  final _msgCtrl = TextEditingController();
  final _scroll = ScrollController();
  List<String> _quickReplies = [];
  bool _isLoadingReplies = false;
  bool _isUploading = false;

  @override
  void initState() {
    super.initState();
    ref.read(chatServiceProvider).markAsRead(widget.chatId, FirebaseAuth.instance.currentUser?.uid ?? '');
  }

  void _send({String? text, String? imageUrl}) async {
    final txt = text ?? _msgCtrl.text.trim();
    if (txt.isEmpty && imageUrl == null) return;
    
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return;

    if (text == null) _msgCtrl.clear();
    setState(() => _quickReplies = []);
    
    if (_scroll.hasClients) {
      _scroll.animateTo(0.0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
    
    await ref.read(chatServiceProvider).sendMessage(
      chatId: widget.chatId,
      senderId: u.uid,
      text: txt,
      receiverName: widget.receiverName,
      isStaffChat: widget.isStaffChat,
      receiverId: widget.receiverId,
      imageUrl: imageUrl,
    );
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
    if (image == null) return;

    setState(() => _isUploading = true);
    try {
      final refStorage = FirebaseStorage.instance.ref().child('chats/${widget.chatId}/${DateTime.now().millisecondsSinceEpoch}.jpg');
      await refStorage.putFile(File(image.path));
      final url = await refStorage.getDownloadURL();
      _send(imageUrl: url, text: '');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    } finally {
      setState(() => _isUploading = false);
    }
  }

  void _loadReplies(String lastMsg) async {
    if (_isLoadingReplies) return;
    setState(() => _isLoadingReplies = true);
    final replies = await ref.read(chatServiceProvider).getSmartReplies(lastMsg, widget.isStaffChat);
    if (mounted) {
      setState(() {
        _quickReplies = replies;
        _isLoadingReplies = false;
      });
    }
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final u = FirebaseAuth.instance.currentUser;
    final isD = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isD ? AppStyles.darkBackgroundColor : const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.receiverName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            Text(widget.isStaffChat ? 'Official Support' : 'Member', style: TextStyle(fontSize: 10, color: Colors.indigo.shade200)),
          ],
        ),
        elevation: 0,
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: ref.watch(chatServiceProvider).getMessages(widget.chatId),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
                final messages = snapshot.data ?? [];
                
                if (messages.isNotEmpty && messages.first['senderId'] != u?.uid && _quickReplies.isEmpty && !_isLoadingReplies) {
                   Future.microtask(() => _loadReplies(messages.first['text'] ?? ''));
                }

                return ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final m = messages[index];
                    final bool isMe = m['senderId'] == u?.uid;
                    return _chatBubble(m, isMe, isD);
                  },
                );
              },
            ),
          ),
          if (_quickReplies.isNotEmpty) _buildQuickReplies(isD),
          if (_isUploading) const LinearProgressIndicator(minHeight: 2),
          _inputArea(isD),
        ],
      ),
    );
  }

  Widget _buildQuickReplies(bool d) {
    return Container(
      height: 45,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _quickReplies.length,
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ActionChip(
            label: Text(_quickReplies[i], style: const TextStyle(fontSize: 12)),
            onPressed: () => _send(text: _quickReplies[i]),
            backgroundColor: d ? Colors.indigo.withValues(alpha: 0.2) : Colors.indigo.shade50,
          ),
        ),
      ),
    );
  }

  Widget _chatBubble(Map<String, dynamic> m, bool isMe, bool d) {
    final hasImage = m['imageUrl'] != null && m['imageUrl'].toString().isNotEmpty;
    
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 2),
            padding: EdgeInsets.all(hasImage ? 4 : 12),
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
            decoration: BoxDecoration(
              color: isMe ? AppStyles.primaryColor : (d ? AppStyles.darkSurfaceColor : Colors.white),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isMe ? 16 : 4),
                bottomRight: Radius.circular(isMe ? 4 : 16),
              ),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 5)],
            ),
            child: Column(
              crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (hasImage) 
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: CachedNetworkImage(
                      imageUrl: m['imageUrl'],
                      placeholder: (context, url) => const SizedBox(height: 150, width: 200, child: Center(child: CircularProgressIndicator())),
                      errorWidget: (context, url, error) => const Icon(Icons.broken_image),
                    ),
                  ),
                if (m['text'] != null && m['text'].toString().isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: hasImage ? 8 : 0, left: 4, right: 4),
                    child: Text(
                      m['text'] ?? '',
                      style: TextStyle(color: isMe ? Colors.white : (d ? Colors.white : Colors.black87), fontSize: 14),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 4, right: 4),
            child: Text(
              m['timestamp'] != null 
                  ? DateFormat('hh:mm a').format((m['timestamp'] as Timestamp).toDate()) 
                  : 'Sending...',
              style: const TextStyle(color: Colors.grey, fontSize: 9),
            ),
          ),
        ],
      ),
    );
  }

  Widget _inputArea(bool d) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      decoration: BoxDecoration(
        color: d ? AppStyles.darkSurfaceColor : Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, -5))],
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline, color: AppStyles.primaryColor),
            onPressed: _pickImage,
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: d ? AppStyles.darkBackgroundColor : const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: _msgCtrl,
                style: TextStyle(color: d ? Colors.white : Colors.black87),
                decoration: const InputDecoration(
                  hintText: 'Type a message...',
                  border: InputBorder.none,
                  hintStyle: TextStyle(fontSize: 14),
                ),
                maxLines: null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          CircleAvatar(
            backgroundColor: AppStyles.primaryColor,
            child: IconButton(
              icon: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
              onPressed: () => _send(),
            ),
          ),
        ],
      ),
    );
  }
}
