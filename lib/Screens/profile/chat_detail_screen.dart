import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../Theme/app_theme.dart';
import '../../Social/friends_model.dart';
import 'user_profile_screen.dart';

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
  bool _hasText = false;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _chatDocSub;
  bool _otherIsTyping = false;
  Timestamp? _otherLastRead;
  Timer? _typingHideTimer;
  Timer? _typingTimer;
  bool _amTyping = false;
  int _prevMsgCount = 0;

  String? _otherAvatarUrl;
  String? _otherBio;
  bool _isFriend = false;

  DocumentReference<Map<String, dynamic>> get _chatRef =>
      FirebaseFirestore.instance.collection('chats').doc(widget.chatId);

  CollectionReference<Map<String, dynamic>> get _msgsRef =>
      _chatRef.collection('messages');

  @override
  void initState() {
    super.initState();
    _markRead();
    _chatDocSub = _chatRef.snapshots().listen(_onChatDocUpdate);
    _loadOtherProfile();
  }

  Future<void> _loadOtherProfile() async {
    try {
      final isFriend = await FriendsModel()
          .areFriends(widget.currentUsername, widget.otherUsername);
      if (!mounted) return;
      setState(() => _isFriend = isFriend);

      final lower = widget.otherUsername.trim().toLowerCase();
      for (final col in ['users', 'bars']) {
        try {
          for (final q in await Future.wait([
            FirebaseFirestore.instance.collection(col).where('username_lower', isEqualTo: lower).limit(1).get(),
            FirebaseFirestore.instance.collection(col).where('username', isEqualTo: widget.otherUsername.trim()).limit(1).get(),
          ], eagerError: false)) {
            if (q.docs.isNotEmpty) {
              final data = q.docs.first.data();
              if (!mounted) return;
              setState(() {
                _otherAvatarUrl = (data['avatarUrl'] ?? '').toString().trim();
                _otherBio = (data['bio'] ?? '').toString().trim();
              });
              return;
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
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
    final lastRead =
        d?['lastRead_${widget.otherUsername}'] as Timestamp?;
    if (lastRead != _otherLastRead) setState(() => _otherLastRead = lastRead);

    final typing =
        d?['typing_${widget.otherUsername}'] as Timestamp?;
    if (typing != null) {
      if (!_otherIsTyping) setState(() => _otherIsTyping = true);
      _typingHideTimer?.cancel();
      _typingHideTimer = Timer(const Duration(seconds: 30), () {
        if (mounted) setState(() => _otherIsTyping = false);
      });
    } else {
      _typingHideTimer?.cancel();
      if (_otherIsTyping) setState(() => _otherIsTyping = false);
    }
  }

  void _onTextChanged(String text) {
    final has = text.isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);

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
        'lastRead_${widget.currentUsername}':
            FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    HapticFeedback.lightImpact();
    _textCtrl.clear();
    _stopTyping();
    setState(() {
      _sending = true;
      _hasText = false;
    });

    try {
      await _chatRef.set({
        'members':
            ([widget.currentUsername, widget.otherUsername]..sort()),
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
        setState(() => _hasText = true);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Fehler: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients &&
          _scrollCtrl.position.minScrollExtent == 0) {
        _scrollCtrl.jumpTo(0);
      }
    });
  }

  DateTime _fromTs(Timestamp ts) =>
      DateTime.fromMicrosecondsSinceEpoch(ts.microsecondsSinceEpoch,
              isUtc: true)
          .toLocal();

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year &&
        dt.month == now.month &&
        dt.day == now.day) return 'Heute';
    final y = now.subtract(const Duration(days: 1));
    if (dt.year == y.year && dt.month == y.month && dt.day == y.day) {
      return 'Gestern';
    }
    return '${dt.day}.${dt.month}.${dt.year}';
  }

  Color _avatarColor(String name) {
    const colors = [
      Color(0xFF5C6BC0), Color(0xFF7B52AB), Color(0xFF00897B),
      Color(0xFF1565C0), Color(0xFF6D4C41), Color(0xFF2E7D32),
      Color(0xFF37474F), Color(0xFF6A1B9A),
    ];
    if (name.isEmpty) return AppColors.panelAlt;
    return colors[name.codeUnitAt(0) % colors.length];
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgTop,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          Expanded(child: _buildMessageArea()),
          _buildInput(context),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
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
        splashRadius: 20,
      ),
      title: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => UserProfileScreen(
              username: widget.otherUsername,
              myUsername: widget.currentUsername,
              initialAvatarUrl: _otherAvatarUrl,
              initialBio: _otherBio,
            ),
          ),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 19,
              backgroundColor: _avatarColor(widget.otherUsername),
              backgroundImage: (_isFriend &&
                      _otherAvatarUrl != null &&
                      _otherAvatarUrl!.isNotEmpty)
                  ? CachedNetworkImageProvider(_otherAvatarUrl!)
                  : null,
              child: (_isFriend &&
                      _otherAvatarUrl != null &&
                      _otherAvatarUrl!.isNotEmpty)
                  ? null
                  : Text(
                      widget.otherUsername.isNotEmpty
                          ? widget.otherUsername[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14),
                    ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.otherUsername,
                    style: const TextStyle(
                      color: AppColors.text,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      letterSpacing: -0.2,
                    ),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: _otherIsTyping
                        ? const Text('schreibt…',
                            key: ValueKey('t'),
                            style: TextStyle(
                                color: AppColors.accent,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w500))
                        : (_isFriend &&
                                _otherBio != null &&
                                _otherBio!.isNotEmpty)
                            ? Text(_otherBio!,
                                key: const ValueKey('b'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: AppColors.subtle, fontSize: 11.5))
                            : const SizedBox.shrink(key: ValueKey('_')),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.subtle, size: 18),
          ],
        ),
      ),
    );
  }

  // ── Message area ─────────────────────────────────────────────────────────

  Widget _buildMessageArea() {
    return Column(
      children: [
        Expanded(child: _buildMessageList()),
        AnimatedSize(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: _otherIsTyping ? _buildTypingRow() : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildTypingRow() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: BoxDecoration(
            color: AppColors.panelAlt,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(4),
              bottomRight: Radius.circular(18),
            ),
            border: Border.all(color: AppColors.accentBorder, width: 1),
          ),
          child: const _TypingDots(),
        ),
      ),
    );
  }

  Widget _buildMessageList() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _msgsRef.orderBy('ts', descending: true).snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting &&
            snap.data == null) {
          return _buildMessageShimmer();
        }

        final docs = snap.data?.docs ?? [];

        if (docs.length > _prevMsgCount) {
          _prevMsgCount = docs.length;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _markRead();
            if (docs.isNotEmpty) {
              final from = docs.first.data()['from'] as String?;
              if (from != null && from != widget.currentUsername) {
                HapticFeedback.mediumImpact();
              }
            }
          });
        }

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: _avatarColor(widget.otherUsername),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      widget.otherUsername.isNotEmpty
                          ? widget.otherUsername[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 28),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  widget.otherUsername,
                  style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 17,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const Text('Schreib die erste Nachricht',
                    style: TextStyle(
                        color: AppColors.subtle, fontSize: 13.5)),
              ],
            ),
          );
        }

        // Find read receipt index
        int lastReadIndex = -1;
        final lr = _otherLastRead;
        if (lr != null) {
          for (int i = 0; i < docs.length; i++) {
            final md = docs[i].data();
            if (md['from'] == widget.currentUsername) {
              final ts = md['ts'] as Timestamp?;
              if (ts != null && ts.compareTo(lr) <= 0) {
                lastReadIndex = i;
                break;
              }
            }
          }
        }

        return ListView.builder(
          controller: _scrollCtrl,
          reverse: true,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          itemCount: docs.length,
          itemBuilder: (context, i) =>
              _buildBubble(docs, i, lastReadIndex),
        );
      },
    );
  }

  Widget _buildMessageShimmer() {
    return ListView(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      children: const [
        _ShimmerBubble(isMe: true, width: 180),
        _ShimmerBubble(isMe: false, width: 220),
        _ShimmerBubble(isMe: true, width: 130),
        _ShimmerBubble(isMe: false, width: 200),
        _ShimmerBubble(isMe: true, width: 160),
        _ShimmerBubble(isMe: false, width: 240),
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

    // Date separator
    final olderTs = (i + 1 < docs.length)
        ? (docs[i + 1].data()['ts'] as Timestamp?)
        : null;
    final olderDate = olderTs == null ? null : _fromTs(olderTs);
    final showDate = date != null &&
        (olderDate == null ||
            date.day != olderDate.day ||
            date.month != olderDate.month ||
            date.year != olderDate.year);

    // Grouping: consecutive same-sender
    final newerFrom = i > 0 ? docs[i - 1].data()['from'] as String? : null;
    final olderFrom =
        i + 1 < docs.length ? docs[i + 1].data()['from'] as String? : null;
    final isLastInGroup =
        newerFrom == null || newerFrom != d['from'];
    final isFirstInGroup =
        olderFrom == null || olderFrom != d['from'] || showDate;

    final timeStr = ts == null
        ? ''
        : () {
            final t = _fromTs(ts);
            return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
          }();

    return Column(
      crossAxisAlignment:
          isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (showDate)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.panel,
                  borderRadius: BorderRadius.circular(999),
                  border:
                      Border.all(color: AppColors.border, width: 1),
                ),
                child: Text(
                  _formatDate(date!),
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
            ),
          ),
        Align(
          alignment:
              isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.74,
            ),
            child: Container(
              margin: EdgeInsets.only(
                bottom: isLastInGroup ? 8 : 2,
              ),
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: isMe ? AppColors.accent : AppColors.panelAlt,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(
                      (!isMe && !isFirstInGroup) ? 6 : 18),
                  topRight: Radius.circular(
                      (isMe && !isFirstInGroup) ? 6 : 18),
                  bottomLeft:
                      Radius.circular(isMe ? 18 : (isLastInGroup ? 4 : 18)),
                  bottomRight:
                      Radius.circular(!isMe ? 18 : (isLastInGroup ? 4 : 18)),
                ),
                border: isMe
                    ? null
                    : Border.all(
                        color: AppColors.accentBorder, width: 1),
              ),
              child: Column(
                crossAxisAlignment: isMe
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  Text(
                    text,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        height: 1.35),
                  ),
                  if (timeStr.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          timeStr,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.45),
                            fontSize: 10.5,
                          ),
                        ),
                        if (isMe && i == lastReadIndex) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.done_all_rounded,
                              size: 12,
                              color: Colors.white.withOpacity(0.75)),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Input ─────────────────────────────────────────────────────────────────

  Widget _buildInput(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bgTop,
        border: Border(
            top: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      padding: EdgeInsets.fromLTRB(
          12, 10, 12, MediaQuery.of(context).padding.bottom + 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(maxHeight: 130),
              decoration: BoxDecoration(
                color: AppColors.panelAlt,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AppColors.border),
              ),
              child: TextField(
                controller: _textCtrl,
                style: const TextStyle(
                    color: AppColors.text, fontSize: 15),
                maxLines: null,
                decoration: const InputDecoration(
                  hintText: 'Nachricht…',
                  hintStyle: TextStyle(
                      color: AppColors.subtle, fontSize: 15),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(
                      horizontal: 18, vertical: 11),
                  isDense: true,
                ),
                textInputAction: TextInputAction.send,
                onChanged: _onTextChanged,
                onSubmitted: (_) => _send(),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            child: _hasText
                ? Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: GestureDetector(
                      onTap: _send,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: const BoxDecoration(
                          color: AppColors.accent,
                          shape: BoxShape.circle,
                        ),
                        child: _sending
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2),
                              )
                            : const Icon(Icons.arrow_upward_rounded,
                                color: Colors.white, size: 22),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

// ── Shimmer bubble ────────────────────────────────────────────────────────────
class _ShimmerBubble extends StatefulWidget {
  final bool isMe;
  final double width;
  const _ShimmerBubble({required this.isMe, required this.width});

  @override
  State<_ShimmerBubble> createState() => _ShimmerBubbleState();
}

class _ShimmerBubbleState extends State<_ShimmerBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final c = Color.lerp(
            const Color(0xFF1A1C22), const Color(0xFF252830), _ctrl.value)!;
        return Align(
          alignment: widget.isMe
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: Container(
            width: widget.width,
            height: 42,
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft:
                    Radius.circular(widget.isMe ? 18 : 4),
                bottomRight:
                    Radius.circular(widget.isMe ? 4 : 18),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── Typing dots ───────────────────────────────────────────────────────────────
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
    _timer = Timer.periodic(
        const Duration(milliseconds: 380),
        (_) {
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
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.symmetric(horizontal: 2.5),
          width: _active == i ? 8 : 6,
          height: _active == i ? 8 : 6,
          decoration: BoxDecoration(
            color: _active == i ? AppColors.muted : AppColors.subtle,
            shape: BoxShape.circle,
          ),
        );
      }),
    );
  }
}
