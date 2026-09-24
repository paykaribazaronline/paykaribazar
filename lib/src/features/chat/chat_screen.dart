import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart'; // Keep this import
import 'package:paykari_bazar/src/di/providers.dart'; // MASTER HUB
import '../../utils/styles.dart';
import '../../utils/app_strings.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});
  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _msgCtrl = TextEditingController(), _scroll = ScrollController();
  bool _isTyping = false;
  @override
  void dispose() {
    _msgCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String _t(String k) =>
      AppStrings.get(k, ref.watch(languageProvider).languageCode);

  bool _containsSensitiveInfo(String text) {
    final phoneRegex = RegExp(r'(?:\+?88)?01[3-9]\d{8}');
    final emailRegex =
        RegExp(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}');
    final spamLinks = [
      't.me/',
      'wa.me/',
      'facebook.com/',
      'fb.me/',
      'bit.ly',
      'tinyurl'
    ];

    if (phoneRegex.hasMatch(text)) return true;
    if (emailRegex.hasMatch(text)) return true;
    for (var link in spamLinks) {
      if (text.toLowerCase().contains(link)) return true;
    }
    return false;
  }

  void _send() async {
    final txt = _msgCtrl.text.trim();
    if (txt.isEmpty) return;
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return;

    if (_containsSensitiveInfo(txt)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(_t('chatModerationWarning')),
            backgroundColor: Colors.red),
      );
      return;
    }

    _msgCtrl.clear();
    final lang = ref.read(languageProvider).languageCode;

    await FirebaseFirestore.instance
        .collection('chats')
        .doc(u.uid)
        .collection('messages')
        .add({
      'text': txt,
      'senderId': u.uid,
      'timestamp': FieldValue.serverTimestamp()
    });

    await FirebaseFirestore.instance.collection('chats').doc(u.uid).set({
      'lastMessage': txt,
      'lastUpdate': FieldValue.serverTimestamp(),
      'userName': u.displayName ?? 'Customer',
      'userId': u.uid
    }, SetOptions(merge: true));

    _scrollBtm();

    final chatSnap =
        await FirebaseFirestore.instance.collection('chats').doc(u.uid).get();
    final bool isAiDisabled = chatSnap.data()?['isAiDisabled'] ?? false;

    if (!isAiDisabled) {
      Future.delayed(const Duration(milliseconds: 500), () {
        _genAi(u.uid, txt, lang == 'bn', u.displayName);
      });
    }
  }

  Future<void> _genAi(String uid, String msg, bool isBn, String? name) async {
    if (!mounted) return;
    setState(() => _isTyping = true);

    try {
      final greeting = name ?? 'Customer';
      final prompt = isBn
          ? 'তুমি পাইকারীবাজার অ্যাপের AI সহকারী। বর্তমান ইউজার: $greeting। কথোপকথন: "$msg"। সংক্ষিপ্ত ও বন্ধুত্বপূর্ণভাবে বাংলায় উত্তর দাও। পণ্য, অর্ডার, ডেলিভারি, পেমেন্ট বা অ্যাপ ব্যবহারের কোনো প্রশ্নের উত্তর দাও।'
          : 'You are the AI assistant of Paykari Bazar app. Current user: $greeting. User said: "$msg". Reply briefly and helpfully in English. Help with products, orders, delivery, payments, or app usage questions.';
      
      final res = await ref
          .read(aiServiceProvider)
          .generateResponse(prompt, type: AiWorkType.text);

      if (res.isNotEmpty && mounted) {
        final chatSnap =
            await FirebaseFirestore.instance.collection('chats').doc(uid).get();
        if (chatSnap.data()?['isAiDisabled'] == true) return;

        await FirebaseFirestore.instance
            .collection('chats')
            .doc(uid)
            .collection('messages')
            .add({
          'text': res,
          'senderId': 'ai_assistant',
          'timestamp': FieldValue.serverTimestamp()
        });

        await FirebaseFirestore.instance.collection('chats').doc(uid).update(
            {'lastMessage': res, 'lastUpdate': FieldValue.serverTimestamp()});
      }
    } catch (e) {
      debugPrint('AI Auto-reply failed: $e');
    } finally {
      if (mounted) setState(() => _isTyping = false);
      _scrollBtm();
    }
  }

  void _scrollBtm() {
    if (_scroll.hasClients) {
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = FirebaseAuth.instance.currentUser;
    final isD = Theme.of(context).brightness == Brightness.dark;
    if (u == null) {
      return Scaffold(
          appBar: AppBar(title: Text(_t('liveChat'))),
          body: Center(child: Text(_t('unauthorized'))));
    }

    return Scaffold(
      backgroundColor:
          isD ? AppStyles.darkBackgroundColor : const Color(0xFFF8F9FA),
      appBar: AppBar(
          backgroundColor: isD ? AppStyles.darkSurfaceColor : Colors.white,
          elevation: 1,
          title: StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('chats')
                  .doc(u.uid)
                  .snapshots(),
              builder: (context, snapshot) {
                final bool isAiDisabled =
                    (snapshot.data?.data() as Map?)?['isAiDisabled'] ?? false;
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_t('liveChat'),
                          style: const TextStyle(
                              fontWeight: FontWeight.w900, fontSize: 17)),
                      Text(
                          isAiDisabled
                              ? _t('supportAgentOnline')
                              : _t('aiAssistantOnline'),
                          style: TextStyle(
                              fontSize: 10,
                              color:
                                  isAiDisabled ? Colors.orange : Colors.green,
                              fontWeight: FontWeight.bold))
                    ]);
              })),
      body: Column(children: [
        Expanded(
            child: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('chats')
              .doc(u.uid)
              .collection('messages')
              .orderBy('timestamp', descending: false)
              .snapshots(),
          builder: (c, s) {
            if (s.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (!s.hasData || s.data!.docs.isEmpty) {
              return Center(
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                    Icon(Icons.chat_bubble_outline_rounded,
                        size: 64,
                        color: isD ? Colors.white24 : Colors.grey[300]),
                    const SizedBox(height: 16),
                    Text(_t('noActiveChats'),
                        style: TextStyle(
                            color: isD ? Colors.white38 : Colors.grey,
                            fontWeight: FontWeight.bold))
                  ]));
            }
            WidgetsBinding.instance.addPostFrameCallback((_) => _scrollBtm());
            return ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(16),
                itemCount: s.data!.docs.length,
                itemBuilder: (c, i) => _bubble(
                    s.data!.docs[i].data() as Map<String, dynamic>,
                    s.data!.docs[i]['senderId'] == u.uid,
                    isD));
          },
        )),
        if (_isTyping)
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_t('pleaseWait'),
                      style: const TextStyle(
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          color: Colors.grey)))),
        _input(isD),
      ]),
    );
  }

  Widget _bubble(Map<String, dynamic> m, bool me, bool d) {
    final bool isAi = m['senderId'] == 'ai_assistant';
    final bool isAdmin = m['senderId'] == 'admin';

    return Align(
        alignment: me ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75),
          decoration: BoxDecoration(
            color: me
                ? AppStyles.primaryColor
                : (isAdmin
                    ? Colors.orange.withValues(alpha: 0.1)
                    : (d ? AppStyles.darkSurfaceColor : Colors.white)),
            borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(me ? 16 : 0),
                bottomRight: Radius.circular(me ? 0 : 16)),
            border: isAdmin
                ? Border.all(color: Colors.orange.withValues(alpha: 0.3))
                : (isAi
                    ? Border.all(color: Colors.blueGrey.withValues(alpha: 0.1))
                    : null),
          ),
          child: Column(
              crossAxisAlignment:
                  me ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (!me)
                  Text(
                      isAdmin
                          ? _t('support')
                          : (isAi ? _t('appName') : _t('guest')),
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: isAdmin ? Colors.orange : Colors.grey)),
                const SizedBox(height: 2),
                Text(m['text'] ?? '',
                    style: TextStyle(
                        color: me
                            ? Colors.white
                            : (d ? Colors.white : AppStyles.textPrimary),
                        fontWeight: FontWeight.w600,
                        fontSize: 14)),
                const SizedBox(height: 4),
                Text(
                    m['timestamp'] != null
                        ? DateFormat('hh:mm a')
                            .format((m['timestamp'] as Timestamp).toDate())
                        : '',
                    style: TextStyle(
                        color: me ? Colors.white70 : Colors.grey, fontSize: 9))
              ]),
        ));
  }

  Widget _input(bool d) => Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      decoration:
          BoxDecoration(color: d ? AppStyles.darkSurfaceColor : Colors.white),
      child: Row(children: [
        Expanded(
            child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                    color: d
                        ? AppStyles.darkBackgroundColor
                        : const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(24)),
                child: TextField(
                    controller: _msgCtrl,
                    style: TextStyle(color: d ? Colors.white : Colors.black87),
                    decoration: InputDecoration(
                        hintText: _t('feedbackHint'),
                        hintStyle: const TextStyle(fontSize: 14),
                        border: InputBorder.none),
                    maxLines: null))),
        const SizedBox(width: 12),
        GestureDetector(
            onTap: _send,
            child: const CircleAvatar(
                radius: 24,
                backgroundColor: AppStyles.primaryColor,
                child:
                    Icon(Icons.send_rounded, color: Colors.white, size: 20))),
      ],
    ),
  );
}
