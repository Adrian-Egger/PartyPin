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

class _ChatDetailScreenState extends State<ChatDetailScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const _reactionEmojis = ['😂', '❤️', '🔥', '👍', '😮', '😢'];

  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _inputFocus = FocusNode();

  bool _sending = false;
  bool _hasText = false;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _chatDocSub;
  bool _otherIsTyping = false;
  Timestamp? _otherLastRead;
  AppLifecycleState _appLifecycle = AppLifecycleState.resumed;
  Timer? _typingHideTimer;
  Timer? _typingTimer;
  bool _amTyping = false;
  int _prevMsgCount = 0;
  String? _animateMsgId; // most recently added msgId — for slide-in

  String? _otherAvatarUrl;
  String? _otherBio;
  bool _isFriend = false;

  // Reply state
  _ReplyDraft? _replyDraft;

  // Highlight a message briefly when jumping to it (reply tap)
  String? _highlightMsgId;
  Timer? _highlightTimer;

  // Map from msgId -> GlobalKey, used to scroll to a message when tapping a reply preview
  final Map<String, GlobalKey> _msgKeys = {};

  DocumentReference<Map<String, dynamic>> get _chatRef =>
      FirebaseFirestore.instance.collection('chats').doc(widget.chatId);

  CollectionReference<Map<String, dynamic>> get _msgsRef =>
      _chatRef.collection('messages');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _markRead();
    _chatDocSub = _chatRef.snapshots().listen(_onChatDocUpdate);
    _loadOtherProfile();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasResumed = _appLifecycle == AppLifecycleState.resumed;
    _appLifecycle = state;
    // Wenn der User wieder in die App zurückkehrt UND der Chat-Screen
    // sichtbar war, jetzt erst die offenen Nachrichten als gelesen markieren.
    if (!wasResumed && state == AppLifecycleState.resumed && mounted) {
      _markRead();
    }
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
            FirebaseFirestore.instance
                .collection(col)
                .where('username_lower', isEqualTo: lower)
                .limit(1)
                .get(),
            FirebaseFirestore.instance
                .collection(col)
                .where('username', isEqualTo: widget.otherUsername.trim())
                .limit(1)
                .get(),
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
    WidgetsBinding.instance.removeObserver(this);
    _stopTyping();
    _chatDocSub?.cancel();
    _typingHideTimer?.cancel();
    _typingTimer?.cancel();
    _highlightTimer?.cancel();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _onChatDocUpdate(DocumentSnapshot<Map<String, dynamic>> snap) {
    if (!mounted) return;
    final d = snap.data();
    final lastRead = d?['lastRead_${widget.otherUsername}'] as Timestamp?;
    if (lastRead != _otherLastRead) setState(() => _otherLastRead = lastRead);

    final typing = d?['typing_${widget.otherUsername}'] as Timestamp?;
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
    // Nicht markieren, wenn die App im Hintergrund/Inactive ist —
    // sonst sieht der Sender "Gelesen", obwohl der User nie hingeschaut hat.
    if (!mounted || _appLifecycle != AppLifecycleState.resumed) return;
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
    final replyDraft = _replyDraft;
    _textCtrl.clear();
    _stopTyping();
    setState(() {
      _sending = true;
      _hasText = false;
      _replyDraft = null;
    });

    try {
      await _chatRef.set({
        'members': ([widget.currentUsername, widget.otherUsername]..sort()),
        'lastMessage': text,
        'lastTs': FieldValue.serverTimestamp(),
        'lastFrom': widget.currentUsername,
        'unread_${widget.otherUsername}': FieldValue.increment(1),
        'unread_${widget.currentUsername}': 0,
      }, SetOptions(merge: true));

      final payload = <String, dynamic>{
        'from': widget.currentUsername,
        'text': text,
        'ts': FieldValue.serverTimestamp(),
      };
      if (replyDraft != null) {
        payload['replyTo'] = {
          'id': replyDraft.id,
          'from': replyDraft.from,
          'text': replyDraft.text.length > 140
              ? '${replyDraft.text.substring(0, 140)}…'
              : replyDraft.text,
        };
      }
      await _msgsRef.add(payload);

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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
          0,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  // ── Reply / scroll-to-message ──────────────────────────────────────────────

  void _setReply(_ReplyDraft draft) {
    HapticFeedback.selectionClick();
    setState(() => _replyDraft = draft);
    _inputFocus.requestFocus();
  }

  void _clearReply() => setState(() => _replyDraft = null);

  GlobalKey _keyFor(String msgId) =>
      _msgKeys.putIfAbsent(msgId, () => GlobalKey());

  Future<void> _scrollToMessage(String msgId) async {
    final ctx = _msgKeys[msgId]?.currentContext;
    if (ctx == null) {
      // The message may be off-screen and unmounted — just nudge user.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Original-Nachricht nicht mehr im Verlauf.'),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      return;
    }
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
      alignment: 0.4,
    );
    setState(() => _highlightMsgId = msgId);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _highlightMsgId = null);
    });
  }

  // ── Reactions ──────────────────────────────────────────────────────────────

  Future<void> _toggleReaction(String msgId, String emoji,
      Map<String, dynamic>? current) async {
    HapticFeedback.lightImpact();
    final reactions = Map<String, dynamic>.from(current ?? {});
    final mine = reactions[widget.currentUsername];
    if (mine == emoji) {
      reactions.remove(widget.currentUsername);
    } else {
      reactions[widget.currentUsername] = emoji;
    }
    try {
      await _msgsRef.doc(msgId).set(
            {'reactions': reactions},
            SetOptions(merge: true),
          );
    } catch (_) {}
  }

  void _showReactionPicker(String msgId, Map<String, dynamic>? reactions) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).padding.bottom + 16,
            top: 6,
          ),
          child: Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.7, end: 1.0),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutBack,
              builder: (_, v, child) =>
                  Transform.scale(scale: v, child: child),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.panel,
                  borderRadius: AppRadius.fullBr,
                  border: Border.all(color: AppColors.border),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.45),
                      blurRadius: 22,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: _reactionEmojis.map((e) {
                    final isMine =
                        (reactions ?? {})[widget.currentUsername] == e;
                    return GestureDetector(
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _toggleReaction(msgId, e, reactions);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: isMine
                              ? AppColors.accent.withOpacity(0.18)
                              : Colors.transparent,
                          borderRadius: AppRadius.fullBr,
                        ),
                        child: Text(e, style: const TextStyle(fontSize: 28)),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Emoji-only detection ──────────────────────────────────────────────────

  /// Liefert > 0 wenn der Text NUR aus Emojis (max. 8 Cluster) besteht,
  /// sonst 0. Reine Punktuation gilt nicht als Emoji-Only.
  int _emojiOnlyClusterCount(String text) {
    final t = text.trim();
    if (t.isEmpty) return 0;
    if (RegExp(r'\p{L}|\p{N}', unicode: true).hasMatch(t)) return 0;
    if (!t.runes.any((r) => r > 127)) return 0;
    final n = t.characters.length;
    if (n == 0 || n > 8) return 0;
    return n;
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgTop,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          Expanded(child: _buildMessageArea()),
          _ReplyPreviewBar(draft: _replyDraft, onClose: _clearReply),
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
            _Avatar(
              size: 38,
              username: widget.otherUsername,
              showImage: _isFriend,
              imageUrl: _otherAvatarUrl,
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
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.subtle, size: 18),
          ],
        ),
      ),
    );
  }

  // ── Message area ──────────────────────────────────────────────────────────

  Widget _buildMessageArea() {
    return Column(
      children: [
        Expanded(child: _buildMessageList()),
        AnimatedSize(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: _otherIsTyping
              ? _TypingBubble(
                  username: widget.otherUsername,
                  imageUrl: _isFriend ? _otherAvatarUrl : null,
                )
              : const SizedBox.shrink(),
        ),
      ],
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
          if (docs.isNotEmpty) _animateMsgId = docs.first.id;
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
                _Avatar(
                    size: 72,
                    username: widget.otherUsername,
                    showImage: _isFriend,
                    imageUrl: _otherAvatarUrl,
                    fontSize: 28),
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
                    style:
                        TextStyle(color: AppColors.subtle, fontSize: 13.5)),
              ],
            ),
          );
        }

        // last read receipt — index of the most recent OWN message that
        // the other person has already seen.
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
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
          itemCount: docs.length,
          itemBuilder: (context, i) => _buildBubble(docs, i, lastReadIndex),
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
    final doc = docs[i];
    final d = doc.data();
    final msgId = doc.id;
    final isMe = d['from'] == widget.currentUsername;
    final text = (d['text'] ?? '').toString();
    final ts = d['ts'] as Timestamp?;
    final date = ts == null ? null : _fromTs(ts);
    final reactions = (d['reactions'] as Map?)?.cast<String, dynamic>();
    final replyTo = (d['replyTo'] as Map?)?.cast<String, dynamic>();

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

    // Grouping (consecutive same-sender)
    final newerFrom = i > 0 ? docs[i - 1].data()['from'] as String? : null;
    final olderFrom =
        i + 1 < docs.length ? docs[i + 1].data()['from'] as String? : null;
    final isLastInGroup = newerFrom == null || newerFrom != d['from'];
    final isFirstInGroup =
        olderFrom == null || olderFrom != d['from'] || showDate;

    final timeStr = ts == null
        ? ''
        : () {
            final t = _fromTs(ts);
            return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
          }();

    // Read-Status (Instagram-Stil): "Gelesen" erscheint AUSSCHLIESSLICH
    // unter der jeweils letzten eigenen Nachricht, die der Empfänger
    // tatsächlich gesehen hat. Ältere oder neuere Nachrichten zeigen kein
    // Indicator-Label.
    _ReadState readState;
    if (!isMe) {
      readState = _ReadState.none;
    } else if (ts == null) {
      readState = _ReadState.pending;
    } else if (i == lastReadIndex) {
      readState = _ReadState.read;
    } else {
      readState = _ReadState.none;
    }

    final emojiClusters = _emojiOnlyClusterCount(text);
    final isEmojiOnly = emojiClusters > 0;

    final bubbleContent = _bubbleContent(
      isMe: isMe,
      text: text,
      timeStr: timeStr,
      readState: readState,
      isFirstInGroup: isFirstInGroup,
      isLastInGroup: isLastInGroup,
      isEmojiOnly: isEmojiOnly,
      emojiClusters: emojiClusters,
      replyTo: replyTo,
      msgId: msgId,
    );

    final bubble = _DoubleTapHeart(
      onDoubleTap: () => _toggleReaction(msgId, '❤️', reactions),
      child: GestureDetector(
        onLongPress: () => _showReactionPicker(msgId, reactions),
        child: bubbleContent,
      ),
    );

    // Swipe-to-reply (rechts wischen)
    final swipeable = Dismissible(
      key: ValueKey('swipe-$msgId'),
      direction: DismissDirection.startToEnd,
      dismissThresholds: const {DismissDirection.startToEnd: 0.18},
      movementDuration: const Duration(milliseconds: 220),
      confirmDismiss: (_) async {
        _setReply(_ReplyDraft(
          id: msgId,
          from: (d['from'] ?? '').toString(),
          text: text,
        ));
        return false;
      },
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 22),
        child: const Icon(Icons.reply_rounded,
            color: AppColors.accent, size: 22),
      ),
      child: bubble,
    );

    // Avatar (only for "other" messages, only on the bottom-most of a group)
    Widget row = Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment:
          isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (!isMe)
          Padding(
            padding: const EdgeInsets.only(right: 6, bottom: 4),
            child: SizedBox(
              width: 28,
              child: isLastInGroup
                  ? _Avatar(
                      size: 28,
                      username: widget.otherUsername,
                      showImage: _isFriend,
                      imageUrl: _otherAvatarUrl,
                      fontSize: 11,
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.74,
            ),
            child: Column(
              crossAxisAlignment:
                  isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                swipeable,
                if (reactions != null && reactions.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(
                      top: 4,
                      bottom: isLastInGroup ? 0 : 0,
                      left: isMe ? 0 : 4,
                      right: isMe ? 4 : 0,
                    ),
                    child: _ReactionsRow(
                      reactions: reactions,
                      currentUser: widget.currentUsername,
                      onTap: (emoji) =>
                          _toggleReaction(msgId, emoji, reactions),
                    ),
                  ),
                // "Gelesen" nur unter der letzten eigenen, gesehenen Nachricht.
                if (isMe && readState == _ReadState.read) const _SeenLabel(),
              ],
            ),
          ),
        ),
      ],
    );

    // Slide-in animation for newly added messages
    if (msgId == _animateMsgId) {
      row = TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        builder: (_, v, child) {
          return Opacity(
            opacity: v,
            child: Transform.translate(
              offset: Offset(0, (1 - v) * 16),
              child: child,
            ),
          );
        },
        child: row,
      );
    }

    return Column(
      crossAxisAlignment:
          isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (showDate && date != null)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                _formatDate(date),
                style: const TextStyle(
                  color: AppColors.subtle,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.only(
            top: isFirstInGroup ? 6 : 1,
            bottom: isLastInGroup ? 6 : 1,
            left: 4,
            right: 4,
          ),
          child: row,
        ),
      ],
    );
  }

  Widget _bubbleContent({
    required bool isMe,
    required String text,
    required String timeStr,
    required _ReadState readState,
    required bool isFirstInGroup,
    required bool isLastInGroup,
    required bool isEmojiOnly,
    required int emojiClusters,
    required Map<String, dynamic>? replyTo,
    required String msgId,
  }) {
    final highlight = _highlightMsgId == msgId;

    // Modern corner pattern: 18px overall, 4px on the corner pointing to sender
    final radius = BorderRadius.only(
      topLeft: Radius.circular((!isMe && !isFirstInGroup) ? 6 : 18),
      topRight: Radius.circular((isMe && !isFirstInGroup) ? 6 : 18),
      bottomLeft:
          Radius.circular(isMe ? 18 : (isLastInGroup ? 4 : 18)),
      bottomRight:
          Radius.circular(!isMe ? 18 : (isLastInGroup ? 4 : 18)),
    );

    // Emoji-only: kein Hintergrund — direkt Text rendern
    if (isEmojiOnly) {
      final size = emojiClusters == 1 ? 56.0 : (emojiClusters <= 3 ? 40.0 : 28.0);
      return Container(
        key: _keyFor(msgId),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (replyTo != null) _replyChip(replyTo, isMe, dim: true),
            Text(
              text,
              style: TextStyle(fontSize: size, height: 1.1),
            ),
            const SizedBox(height: 3),
            _MetaRow(
                isMe: isMe, timeStr: timeStr, readState: readState),
          ],
        ),
      );
    }

    final decoration = BoxDecoration(
      gradient: isMe
          ? const LinearGradient(
              colors: [
                Color(0xFFFF3B30),
                Color(0xFFFF6B81), // soft pink
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            )
          : null,
      color: isMe ? null : AppColors.panelAlt,
      borderRadius: radius,
      boxShadow: highlight
          ? [
              BoxShadow(
                color: AppColors.accent.withOpacity(0.55),
                blurRadius: 18,
                spreadRadius: 1,
              ),
            ]
          : isMe
              ? [
                  BoxShadow(
                    color: AppColors.accent.withOpacity(0.18),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
    );

    return AnimatedContainer(
      key: _keyFor(msgId),
      duration: const Duration(milliseconds: 240),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: decoration,
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (replyTo != null) _replyChip(replyTo, isMe),
          Text(
            text,
            style: const TextStyle(
                color: Colors.white, fontSize: 14.5, height: 1.35),
          ),
          const SizedBox(height: 3),
          _MetaRow(
              isMe: isMe, timeStr: timeStr, readState: readState),
        ],
      ),
    );
  }

  Widget _replyChip(Map<String, dynamic> replyTo, bool isMe,
      {bool dim = false}) {
    final repliedFrom = (replyTo['from'] ?? '').toString();
    final repliedText = (replyTo['text'] ?? '').toString();
    final repliedId = (replyTo['id'] ?? '').toString();
    final color = isMe ? Colors.white : AppColors.text;
    return GestureDetector(
      onTap: repliedId.isEmpty ? null : () => _scrollToMessage(repliedId),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: dim
              ? AppColors.panelAlt.withOpacity(0.6)
              : (isMe
                  ? Colors.white.withOpacity(0.18)
                  : AppColors.bgTop.withOpacity(0.5)),
          borderRadius: BorderRadius.circular(10),
          border: Border(
            left: BorderSide(
              color: isMe ? Colors.white : AppColors.accent,
              width: 3,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              repliedFrom,
              style: TextStyle(
                color: color.withOpacity(0.9),
                fontWeight: FontWeight.w700,
                fontSize: 11.5,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              repliedText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color.withOpacity(0.75),
                fontSize: 12,
                height: 1.25,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Input ──────────────────────────────────────────────────────────────────

  Widget _buildInput(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bgTop,
        border:
            Border(top: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      padding: EdgeInsets.fromLTRB(
          10, 8, 10, MediaQuery.of(context).padding.bottom + 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Pill-shaped input
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              constraints: const BoxConstraints(maxHeight: 130),
              decoration: BoxDecoration(
                color: AppColors.panelAlt,
                borderRadius: AppRadius.fullBr,
                boxShadow: _hasText
                    ? [
                        BoxShadow(
                          color: AppColors.accent.withOpacity(0.10),
                          blurRadius: 10,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      focusNode: _inputFocus,
                      style: const TextStyle(
                          color: AppColors.text, fontSize: 15),
                      maxLines: null,
                      decoration: const InputDecoration(
                        hintText: 'Nachricht…',
                        hintStyle:
                            TextStyle(color: AppColors.subtle, fontSize: 15),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 6, vertical: 12),
                        isDense: true,
                      ),
                      textInputAction: TextInputAction.send,
                      onChanged: _onTextChanged,
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
          // Send button — always visible
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: GestureDetector(
              onTap: _hasText && !_sending ? _send : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: _hasText
                        ? const [
                            Color(0xFFFF3B30),
                            Color(0xFFFF6B81),
                          ]
                        : [
                            AppColors.panelAlt,
                            AppColors.panelAlt,
                          ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                  boxShadow: _hasText
                      ? [
                          BoxShadow(
                            color: AppColors.accent.withOpacity(0.35),
                            blurRadius: 12,
                            offset: const Offset(0, 3),
                          ),
                        ]
                      : null,
                ),
                child: _sending
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2),
                      )
                    : Icon(Icons.send_rounded,
                        color: _hasText ? Colors.white : AppColors.muted,
                        size: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

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
}

// ─── Reply draft ──────────────────────────────────────────────────────────────

class _ReplyDraft {
  const _ReplyDraft({
    required this.id,
    required this.from,
    required this.text,
  });
  final String id;
  final String from;
  final String text;
}

// ─── Reply preview bar (above input) ─────────────────────────────────────────

class _ReplyPreviewBar extends StatelessWidget {
  const _ReplyPreviewBar({required this.draft, required this.onClose});
  final _ReplyDraft? draft;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      transitionBuilder: (child, anim) => SizeTransition(
        sizeFactor: anim,
        axisAlignment: -1,
        child: FadeTransition(opacity: anim, child: child),
      ),
      child: draft == null
          ? const SizedBox.shrink(key: ValueKey('none'))
          : Container(
              key: ValueKey(draft!.id),
              padding:
                  const EdgeInsets.fromLTRB(12, 8, 8, 8),
              decoration: const BoxDecoration(
                color: AppColors.bgTop,
                border: Border(
                  top: BorderSide(color: AppColors.border, width: 0.5),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Antwort an ${draft!.from}',
                          style: const TextStyle(
                            color: AppColors.accent,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          draft!.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.muted, fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        color: AppColors.muted, size: 20),
                    onPressed: onClose,
                    splashRadius: 18,
                  ),
                ],
              ),
            ),
    );
  }
}

// ─── Read state ──────────────────────────────────────────────────────────────

enum _ReadState { none, pending, delivered, read }

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.isMe,
    required this.timeStr,
    required this.readState,
  });
  final bool isMe;
  final String timeStr;
  final _ReadState readState;

  @override
  Widget build(BuildContext context) {
    if (timeStr.isEmpty && readState == _ReadState.none) {
      return const SizedBox.shrink();
    }
    final timeColor = isMe
        ? Colors.white.withOpacity(0.6)
        : AppColors.subtle;

    // Inline-Indicator innerhalb der Bubble: nur Sendezustand ("Senden…").
    // Das "Gelesen"-Label wird bewusst NICHT hier, sondern als eigene Zeile
    // unterhalb der Bubble gerendert (siehe unten in der Bubble-Spalte).
    Widget? inlineHint;
    if (isMe && readState == _ReadState.pending) {
      inlineHint = Text(
        'Senden…',
        style: TextStyle(
          color: Colors.white.withOpacity(0.7),
          fontSize: 10.5,
          fontStyle: FontStyle.italic,
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (timeStr.isNotEmpty)
          Text(
            timeStr,
            style: TextStyle(color: timeColor, fontSize: 10.5),
          ),
        if (inlineHint != null) ...[
          const SizedBox(width: 6),
          inlineHint,
        ],
      ],
    );
  }
}

/// "Gelesen"-Label im Instagram-Stil — wird NUR unter der letzten
/// eigenen, vom Empfänger gesehenen Nachricht angezeigt.
class _SeenLabel extends StatelessWidget {
  const _SeenLabel();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 4, right: 6),
      child: Text(
        'Gelesen',
        style: TextStyle(
          color: AppColors.subtle,
          fontSize: 11,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}

// ─── Reactions row ───────────────────────────────────────────────────────────

class _ReactionsRow extends StatelessWidget {
  const _ReactionsRow({
    required this.reactions,
    required this.currentUser,
    required this.onTap,
  });
  final Map<String, dynamic> reactions;
  final String currentUser;
  final void Function(String emoji) onTap;

  @override
  Widget build(BuildContext context) {
    // Group by emoji → count
    final counts = <String, int>{};
    String? mine;
    reactions.forEach((user, emoji) {
      final e = (emoji ?? '').toString();
      if (e.isEmpty) return;
      counts[e] = (counts[e] ?? 0) + 1;
      if (user == currentUser) mine = e;
    });
    if (counts.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: counts.entries.map((e) {
        final isMine = mine == e.key;
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.5, end: 1.0),
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutBack,
          builder: (_, v, child) =>
              Transform.scale(scale: v, child: child),
          child: GestureDetector(
            onTap: () => onTap(e.key),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: isMine
                    ? AppColors.accent.withOpacity(0.18)
                    : AppColors.panel,
                borderRadius: AppRadius.fullBr,
                border: Border.all(
                  color: isMine
                      ? AppColors.accentBorder3
                      : AppColors.border,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(e.key, style: const TextStyle(fontSize: 13)),
                  if (e.value > 1) ...[
                    const SizedBox(width: 4),
                    Text(
                      '${e.value}',
                      style: TextStyle(
                        color: isMine
                            ? AppColors.text
                            : AppColors.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ─── Avatar ──────────────────────────────────────────────────────────────────

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.size,
    required this.username,
    this.imageUrl,
    this.showImage = true,
    this.fontSize,
  });

  final double size;
  final String username;
  final String? imageUrl;
  final bool showImage;
  final double? fontSize;

  static Color _color(String name) {
    const colors = [
      Color(0xFF5C6BC0), Color(0xFF7B52AB), Color(0xFF00897B),
      Color(0xFF1565C0), Color(0xFF6D4C41), Color(0xFF2E7D32),
      Color(0xFF37474F), Color(0xFF6A1B9A),
    ];
    if (name.isEmpty) return AppColors.panelAlt;
    return colors[name.codeUnitAt(0) % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    final hasImage =
        showImage && imageUrl != null && imageUrl!.isNotEmpty;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _color(username),
        shape: BoxShape.circle,
        image: hasImage
            ? DecorationImage(
                // memCache auf 2× DPR-Größe begrenzen — Avatar ist <80 px,
                // ohne Limit landet ein 1080-px-Original im RAM.
                image: ResizeImage(
                  CachedNetworkImageProvider(imageUrl!),
                  width: (size * 2).round(),
                ),
                fit: BoxFit.cover,
              )
            : null,
      ),
      alignment: Alignment.center,
      child: hasImage
          ? null
          : Text(
              username.isNotEmpty ? username[0].toUpperCase() : '?',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: fontSize ?? (size * 0.4),
              ),
            ),
    );
  }
}

// ─── Typing bubble ───────────────────────────────────────────────────────────

class _TypingBubble extends StatelessWidget {
  const _TypingBubble({required this.username, this.imageUrl});
  final String username;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 14, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _Avatar(
            size: 28,
            username: username,
            imageUrl: imageUrl,
            showImage: imageUrl != null && imageUrl!.isNotEmpty,
            fontSize: 11,
          ),
          const SizedBox(width: 6),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            decoration: const BoxDecoration(
              color: AppColors.panelAlt,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomLeft: Radius.circular(4),
                bottomRight: Radius.circular(18),
              ),
            ),
            child: const _TypingDots(),
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
    _timer = Timer.periodic(const Duration(milliseconds: 380), (_) {
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
          duration: const Duration(milliseconds: 220),
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

// ─── Shimmer placeholder ─────────────────────────────────────────────────────

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
          alignment:
              widget.isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: widget.width,
            height: 42,
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(widget.isMe ? 18 : 4),
                bottomRight: Radius.circular(widget.isMe ? 4 : 18),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─── Double-tap heart overlay ────────────────────────────────────────────────
// Wraps a child and, on double-tap, runs the supplied callback (toggle ❤️
// reaction) AND shows a quick popping heart animation over the bubble.

class _DoubleTapHeart extends StatefulWidget {
  const _DoubleTapHeart({required this.child, required this.onDoubleTap});

  final Widget child;
  final VoidCallback onDoubleTap;

  @override
  State<_DoubleTapHeart> createState() => _DoubleTapHeartState();
}

class _DoubleTapHeartState extends State<_DoubleTapHeart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _trigger() {
    HapticFeedback.mediumImpact();
    widget.onDoubleTap();
    _ctrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTap: _trigger,
      // wichtig: behavior=opaque, sonst werden DoubleTaps am Rand verschluckt
      behavior: HitTestBehavior.opaque,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          widget.child,
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) {
                if (_ctrl.value == 0) return const SizedBox.shrink();
                final t = _ctrl.value;
                final scale = t < 0.4
                    ? Curves.easeOutBack.transform(t / 0.4) * 1.0
                    : 1.0 + (t - 0.4) * 0.4;
                final opacity = t < 0.7 ? 1.0 : (1.0 - (t - 0.7) / 0.3);
                return Opacity(
                  opacity: opacity.clamp(0.0, 1.0),
                  child: Transform.translate(
                    offset: Offset(0, -10 * t),
                    child: Transform.scale(
                      scale: scale,
                      child: const Text(
                        '❤️',
                        style: TextStyle(
                          fontSize: 56,
                          shadows: [
                            Shadow(
                              color: Colors.black54,
                              blurRadius: 12,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
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
