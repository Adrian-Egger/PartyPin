import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../Theme/app_theme.dart';
import 'chat_detail_screen.dart';

class ChatListScreen extends StatefulWidget {
  final String currentUsername;
  const ChatListScreen({super.key, required this.currentUsername});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  String get _me => widget.currentUsername;

  String _chatId(String a, String b) {
    final s = [a, b]..sort();
    return '${s[0]}__${s[1]}';
  }

  void _openChat(BuildContext context, String other, {String? existingChatId}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatDetailScreen(
          chatId: existingChatId ?? _chatId(_me, other),
          currentUsername: _me,
          otherUsername: other,
        ),
      ),
    );
  }

  Future<void> _startNewChat(BuildContext context) async {
    final ctrl = TextEditingController();
    String? target;

    await showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            20, 16, 20, MediaQuery.of(ctx).viewInsets.bottom + 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Neue Nachricht',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Mit wem möchtest du schreiben?',
              style: TextStyle(color: AppColors.subtle, fontSize: 13),
            ),
            const SizedBox(height: 20),
            Container(
              decoration: BoxDecoration(
                color: AppColors.panelAlt,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: TextField(
                controller: ctrl,
                style:
                    const TextStyle(color: AppColors.text, fontSize: 15),
                decoration: const InputDecoration(
                  hintText: 'Username eingeben…',
                  hintStyle: TextStyle(color: AppColors.subtle),
                  border: InputBorder.none,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  prefixIcon: Icon(Icons.person_search_rounded,
                      color: AppColors.subtle, size: 20),
                ),
                autofocus: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (v) {
                  target = v.trim();
                  Navigator.pop(ctx);
                },
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                onPressed: () {
                  target = ctrl.text.trim();
                  Navigator.pop(ctx);
                },
                child: const Text('Chat öffnen',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
              ),
            ),
          ],
        ),
      ),
    );

    if (!mounted) return;
    if (target != null && target!.isNotEmpty && target != _me) {
      final query = await FirebaseFirestore.instance
          .collection('chats')
          .where('members', arrayContains: _me)
          .get();
      String? existingId;
      for (final doc in query.docs) {
        final mems = List<String>.from(doc.data()['members'] ?? []);
        if (mems.contains(target)) {
          existingId = doc.id;
          break;
        }
      }
      if (!mounted) return;
      // ignore: use_build_context_synchronously
      _openChat(context, target!, existingChatId: existingId);
    }
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays < 2) {
      return 'Gestern';
    } else if (diff.inDays < 7) {
      const days = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
      return days[dt.weekday - 1];
    }
    return '${dt.day}.${dt.month}.';
  }

  DateTime _fromTs(Timestamp ts) =>
      DateTime.fromMicrosecondsSinceEpoch(ts.microsecondsSinceEpoch,
              isUtc: true)
          .toLocal();

  Color _avatarColor(String name) {
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
    return Scaffold(
      backgroundColor: AppColors.bgTop,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context),
            Expanded(child: _buildList()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 22, 16, 12),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Chats',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.8,
              ),
            ),
          ),
          GestureDetector(
            onTap: () => _startNewChat(context),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppColors.panel,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.border),
              ),
              child: const Icon(Icons.edit_rounded,
                  color: AppColors.accent, size: 17),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('chats')
          .where('members', arrayContains: _me)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting &&
            snap.data == null) {
          return _buildShimmer();
        }

        var docs = snap.data?.docs ?? [];
        docs = [...docs]..sort((a, b) {
            final ta = a.data()['lastTs'] as Timestamp?;
            final tb = b.data()['lastTs'] as Timestamp?;
            if (ta == null && tb == null) return 0;
            if (ta == null) return 1;
            if (tb == null) return -1;
            return tb.compareTo(ta);
          });

        if (docs.isEmpty) return _buildEmpty(context);

        return ListView.separated(
          padding: const EdgeInsets.only(top: 4, bottom: 24),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const Divider(
            height: 1,
            indent: 82,
            endIndent: 0,
            color: Color(0xFF1E2028),
          ),
          itemBuilder: (context, i) => _buildTile(context, docs[i]),
        );
      },
    );
  }

  Widget _buildShimmer() {
    return ListView.separated(
      padding: const EdgeInsets.only(top: 4),
      itemCount: 6,
      separatorBuilder: (_, __) => const Divider(
          height: 1, indent: 82, color: Color(0xFF1E2028)),
      itemBuilder: (_, __) => const _ShimmerTile(),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              color: AppColors.panel,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.border, width: 1.5),
            ),
            child: const Icon(Icons.forum_rounded,
                color: AppColors.subtle, size: 32),
          ),
          const SizedBox(height: 18),
          const Text(
            'Keine Chats',
            style: TextStyle(
              color: AppColors.text,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Starte deine erste Unterhaltung',
            style: TextStyle(color: AppColors.subtle, fontSize: 13.5),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => _startNewChat(context),
            icon: const Icon(Icons.edit_rounded, size: 15),
            label: const Text('Neue Nachricht',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTile(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data();
    final members = List<String>.from(d['members'] ?? []);
    final other = members.firstWhere((m) => m != _me, orElse: () => '?');
    final lastMessage = (d['lastMessage'] ?? '').toString();
    final lastFrom = (d['lastFrom'] ?? '').toString();
    final lastTs = d['lastTs'] as Timestamp?;
    final unread = (d['unread_$_me'] ?? 0) as int;
    final preview = lastFrom == _me ? 'Du: $lastMessage' : lastMessage;
    final hasUnread = unread > 0;

    return InkWell(
      onTap: () => _openChat(context, other, existingChatId: doc.id),
      splashColor: AppColors.accent.withOpacity(0.05),
      highlightColor: AppColors.accent.withOpacity(0.03),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: _avatarColor(other),
                shape: BoxShape.circle,
                border: hasUnread
                    ? Border.all(color: AppColors.accent, width: 2.5)
                    : null,
              ),
              child: Center(
                child: Text(
                  other.isNotEmpty ? other[0].toUpperCase() : '?',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 19,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          other,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.text,
                            fontWeight: hasUnread
                                ? FontWeight.w700
                                : FontWeight.w600,
                            fontSize: 15,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      if (lastTs != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          _formatTime(_fromTs(lastTs)),
                          style: TextStyle(
                            color: hasUnread
                                ? AppColors.accent
                                : AppColors.subtle,
                            fontSize: 11.5,
                            fontWeight: hasUnread
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          preview.isEmpty ? ' ' : preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: hasUnread
                                ? AppColors.muted
                                : AppColors.subtle,
                            fontSize: 13,
                            fontWeight: hasUnread
                                ? FontWeight.w500
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (hasUnread) ...[
                        const SizedBox(width: 8),
                        Container(
                          constraints:
                              const BoxConstraints(minWidth: 20),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.accent,
                            borderRadius:
                                BorderRadius.circular(999),
                          ),
                          child: Text(
                            '$unread',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Shimmer tile ─────────────────────────────────────────────────────────────
class _ShimmerTile extends StatefulWidget {
  const _ShimmerTile();

  @override
  State<_ShimmerTile> createState() => _ShimmerTileState();
}

class _ShimmerTileState extends State<_ShimmerTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
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
        return Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            children: [
              Container(
                  width: 50,
                  height: 50,
                  decoration:
                      BoxDecoration(color: c, shape: BoxShape.circle)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                            height: 13,
                            width: 100,
                            decoration: BoxDecoration(
                                color: c,
                                borderRadius: BorderRadius.circular(6))),
                        const Spacer(),
                        Container(
                            height: 11,
                            width: 28,
                            decoration: BoxDecoration(
                                color: c,
                                borderRadius: BorderRadius.circular(5))),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                        height: 11,
                        decoration: BoxDecoration(
                            color: Color.lerp(c, Colors.transparent, 0.4),
                            borderRadius: BorderRadius.circular(5))),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
