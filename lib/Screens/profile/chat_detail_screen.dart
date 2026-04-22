import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import '../../Theme/app_theme.dart';

class ChatDetailScreen extends StatefulWidget {
  final String chatId;
  final String currentUsername;
  final String otherUsername;

  const ChatDetailScreen({
    super.key,
    required this.chatId,
    required this.currentUsername,
    required this.otherUsername,
  });

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _sending = false;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _chatDocSub;
  bool _otherIsTyping = false;
  Timestamp? _otherLastRead;
  Timer? _typingHideTimer;
  Timer? _typingTimer;
  bool _amTyping = false;

  DocumentReference<Map<String, dynamic>> get _chatRef =>
      FirebaseFirestore.instance.collection('chats').doc(widget.chatId);

  CollectionReference<Map<String, dynamic>> get _msgsRef =>
      _chatRef.collection('messages');

  @override
  void initState() {
    super.initState();
    _markRead();
    _chatDocSub = _chatRef.snapshots().listen(_onChatDocUpdate);
  }

  @override
  void dispose() {
    _stopTyping();
    _chatDocSub?.cancel();
    _typingHideTimer?.cancel();
    _typingTimer?.cancel();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onChatDocUpdate(DocumentSnapshot<Map<String, dynamic>> snap) {
    if (!mounted) return;
    final d = snap.data();

    final lastRead = d?['lastRead_${widget.otherUsername}'] as Timestamp?;
    if (lastRead != _otherLastRead) {
      setState(() => _otherLastRead = lastRead);
    }

    final typing = d?['typing_${widget.otherUsername}'] as Timestamp?;
    if (typing != null) {
      final age = DateTime.now().difference(
        DateTime.fromMicrosecondsSinceEpoch(
            typing.microsecondsSinceEpoch, isUtc: true),
      );
      if (age.inSeconds <= 5) {
        if (!_otherIsTyping) setState(() => _otherIsTyping = true);
        _typingHideTimer?.cancel();
        _typingHideTimer = Timer(const Duration(seconds: 5), () {
          if (mounted) setState(() => _otherIsTyping = false);
        });
        return;
      }
    }
    if (_otherIsTyping) setState(() => _otherIsTyping = false);
  }

  void _onTextChanged(String text) {
    if (text.isEmpty) {
      _stopTyping();
      return;
    }
    if (!_amTyping) {
      _amTyping = true;
      _chatRef.set(
        {'typing_${widget.currentUsername}': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      ).catchError((_) {});
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 3), _stopTyping);
  }

  void _stopTyping() {
    if (!_amTyping) return;
    _amTyping = false;
    _typingTimer?.cancel();
    _chatRef
        .update({'typing_${widget.currentUsername}': FieldValue.delete()})
        .catchError((_) {});
  }

  Future<void> _markRead() async {
    try {
      await _chatRef.set({
        'unread_${widget.currentUsername}': 0,
        'lastRead_${widget.currentUsername}': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    _textCtrl.clear();
    _stopTyping();
    setState(() => _sending = true);

    try {
      await _chatRef.set({
        'members': ([widget.currentUsername, widget.otherUsername]..sort()),
        'lastMessage': text,
        'lastTs': FieldValue.serverTimestamp(),
        'lastFrom': widget.currentUsername,
        'unread_${widget.otherUsername}': FieldValue.increment(1),
        'unread_${widget.currentUsername}': 0,
      }, SetOptions(merge: true));

      await _msgsRef.add({
        'from': widget.currentUsername,
        'text': text,
        'ts': FieldValue.serverTimestamp(),
      });

      try {
        await FirebaseFunctions.instanceFor(region: 'europe-west1')
            .httpsCallable('sendPushNotification')
            .call({
          'toUsername': widget.otherUsername,
          'title': widget.currentUsername,
          'body': text,
          'data': {'type': 'chat', 'chatId': widget.chatId},
        });
      } catch (_) {}

      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        _textCtrl.text = text;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Fehler: $e'),
          backgroundColor: AppColors.accent,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  DateTime _fromTs(Timestamp ts) =>
      DateTime.fromMicrosecondsSinceEpoch(ts.microsecondsSinceEpoch,
              isUtc: true)
          .toLocal();

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return 'Heute';
    }
    final y = now.subtract(const Duration(days: 1));
    if (dt.year == y.year && dt.month == y.month && dt.day == y.day) {
      return 'Gestern';
    }
    return '${dt.day}.${dt.month}.${dt.year}';
  }

  Color _avatarColor(String name) {
    const colors = [
      Color(0xFF5C6BC0),
      Color(0xFF9C3587),
      Color(0xFF00897B),
      Color(0xFF1565C0),
      Color(0xFF6D4C41),
      Color(0xFF2E7D32),
      Color(0xFF37474F),
      Color(0xFF6A1B9A),
    ];
    if (name.isEmpty) return AppColors.panelAlt;
    return colors[name.codeUnitAt(0) % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgTop,
      appBar: AppBar(
        backgroundColor: AppColors.bgTop,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Container(height: 0.5, color: AppColors.border),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppColors.text),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: _avatarColor(widget.otherUsername),
              child: Text(
                widget.otherUsername.isNotEmpty
                    ? widget.otherUsername[0].toUpperCase()
                    : '?',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.otherUsername,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _otherIsTyping
                      ? Text(
                          'schreibt…',
                          key: const ValueKey('typing'),
                          style: const TextStyle(
                            color: AppColors.accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        )
                      : const SizedBox.shrink(key: ValueKey('idle')),
                ),
              ],
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(child: _buildMessages()),
          _buildInput(context),
        ],
      ),
    );
  }

  Widget _buildMessages() {
    return Column(
      children: [
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _msgsRef.orderBy('ts').snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: CircularProgressIndicator(
                    color: AppColors.accent,
                    strokeWidth: 2,
                  ),
                );
              }
              final docs = snap.data?.docs ?? [];

              WidgetsBinding.instance.addPostFrameCallback((_) {
                _markRead();
                _scrollToBottom();
              });

              if (docs.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.panelAlt,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Icon(
                          Icons.waving_hand_rounded,
                          color: AppColors.subtle,
                          size: 28,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Schreib eine Nachricht!',
                        style: TextStyle(
                          color: AppColors.muted,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                );
              }

              int lastReadIndex = -1;
              final lr = _otherLastRead;
              if (lr != null) {
                for (int i = docs.length - 1; i >= 0; i--) {
                  final msgData = docs[i].data();
                  if (msgData['from'] == widget.currentUsername) {
                    final ts = msgData['ts'] as Timestamp?;
                    if (ts != null && ts.compareTo(lr) <= 0) {
                      lastReadIndex = i;
                      break;
                    }
                  }
                }
              }

              return ListView.builder(
                controller: _scrollCtrl,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                itemCount: docs.length,
                itemBuilder: (context, i) =>
                    _buildBubble(docs, i, lastReadIndex),
              );
            },
          ),
        ),
        if (_otherIsTyping)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                decoration: BoxDecoration(
                  color: AppColors.panelAlt,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                    bottomLeft: Radius.circular(4),
                    bottomRight: Radius.circular(16),
                  ),
                  border: Border.all(color: AppColors.accentBorder, width: 1),
                ),
                child: const _TypingDots(),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBubble(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    int i,
    int lastReadIndex,
  ) {
    final d = docs[i].data();
    final isMe = d['from'] == widget.currentUsername;
    final text = (d['text'] ?? '').toString();
    final ts = d['ts'] as Timestamp?;
    final date = ts == null ? null : _fromTs(ts);
    final prevTs = i > 0 ? (docs[i - 1].data()['ts'] as Timestamp?) : null;
    final prevDate = prevTs == null ? null : _fromTs(prevTs);
    final showDate = date != null &&
        (prevDate == null ||
            date.day != prevDate.day ||
            date.month != prevDate.month ||
            date.year != prevDate.year);

    return Column(
      crossAxisAlignment:
          isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (showDate)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.panelAlt,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _formatDate(date!),
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.72,
            ),
            child: Container(
              margin: const EdgeInsets.only(bottom: 2),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isMe ? AppColors.accent : AppColors.panelAlt,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMe ? 16 : 4),
                  bottomRight: Radius.circular(isMe ? 4 : 16),
                ),
                border: isMe
                    ? null
                    : Border.all(color: AppColors.accentBorder, width: 1),
              ),
              child: Column(
                crossAxisAlignment: isMe
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  Text(
                    text,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  if (ts != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      () {
                        final t = _fromTs(ts);
                        return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
                      }(),
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        if (isMe && i == lastReadIndex) ...[
          const SizedBox(height: 1),
          Padding(
            padding: const EdgeInsets.only(right: 4, bottom: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: const [
                Icon(Icons.done_all_rounded, size: 13, color: AppColors.accent),
                SizedBox(width: 3),
                Text(
                  'Gelesen',
                  style: TextStyle(color: AppColors.muted, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildInput(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: const Border(
          top: BorderSide(color: AppColors.border, width: 0.5),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        12,
        10,
        12,
        MediaQuery.of(context).padding.bottom + 10,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.panelAlt,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AppColors.accentBorder),
              ),
              child: TextField(
                controller: _textCtrl,
                style: const TextStyle(color: AppColors.text, fontSize: 14),
                maxLines: 5,
                minLines: 1,
                decoration: const InputDecoration(
                  hintText: 'Nachricht…',
                  hintStyle: TextStyle(color: AppColors.subtle),
                  border: InputBorder.none,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  isDense: true,
                ),
                textInputAction: TextInputAction.send,
                onChanged: _onTextChanged,
                onSubmitted: (_) => _send(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _send,
            child: Container(
              width: 42,
              height: 42,
              decoration: const BoxDecoration(
                color: AppColors.accent,
                shape: BoxShape.circle,
              ),
              child: _sending
                  ? const Padding(
                      padding: EdgeInsets.all(11),
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded,
                      color: Colors.white, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> {
  int _active = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (mounted) setState(() => _active = (_active + 1) % 3);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 2),
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: _active == i ? AppColors.muted : AppColors.subtle,
            shape: BoxShape.circle,
          ),
        );
      }),
    );
  }
}
