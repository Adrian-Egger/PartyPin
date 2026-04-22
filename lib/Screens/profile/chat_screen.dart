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

  void _openChat(BuildContext context, String other) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatDetailScreen(
          chatId: _chatId(_me, other),
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Neue Nachricht',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: AppColors.panelAlt,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              child: TextField(
                controller: ctrl,
                style: const TextStyle(color: AppColors.text, fontSize: 15),
                decoration: const InputDecoration(
                  hintText: 'Username eingeben…',
                  hintStyle: TextStyle(color: AppColors.subtle),
                  border: InputBorder.none,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  prefixIcon: Icon(
                    Icons.person_search_rounded,
                    color: AppColors.subtle,
                    size: 20,
                  ),
                ),
                autofocus: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (v) {
                  target = v.trim();
                  Navigator.pop(ctx);
                },
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                onPressed: () {
                  target = ctrl.text.trim();
                  Navigator.pop(ctx);
                },
                child: const Text(
                  'Chat öffnen',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (!mounted) return;
    if (target != null && target!.isNotEmpty && target != _me) {
      // ignore: use_build_context_synchronously
      _openChat(context, target!);
    }
  }

  DateTime _fromTs(Timestamp ts) =>
      DateTime.fromMicrosecondsSinceEpoch(ts.microsecondsSinceEpoch,
              isUtc: true)
          .toLocal();

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays < 2) {
      return 'gestern';
    } else if (diff.inDays < 7) {
      const days = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
      return days[dt.weekday - 1];
    }
    return '${dt.day}.${dt.month}.';
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
      floatingActionButton: FloatingActionButton(
        onPressed: () => _startNewChat(context),
        backgroundColor: AppColors.accent,
        elevation: 0,
        shape: const CircleBorder(),
        child: const Icon(Icons.edit_rounded, color: Colors.white),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              child: const Text(
                'Nachrichten',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: AppColors.text,
                  letterSpacing: -0.6,
                ),
              ),
            ),
            Expanded(child: _buildList()),
          ],
        ),
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
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(
              color: AppColors.accent,
              strokeWidth: 2,
            ),
          );
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

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: AppColors.panelAlt,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(
                    Icons.chat_bubble_outline_rounded,
                    color: AppColors.subtle,
                    size: 32,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Noch keine Nachrichten',
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Tippe auf ✏️ um einen Chat zu starten.',
                  style: TextStyle(color: AppColors.subtle, fontSize: 13),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          itemCount: docs.length,
          itemBuilder: (context, i) => _buildTile(context, docs[i]),
        );
      },
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

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openChat(context, other),
        borderRadius: BorderRadius.circular(16),
        splashColor: AppColors.accent.withOpacity(0.08),
        highlightColor: AppColors.accent.withOpacity(0.04),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: [
              Stack(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: _avatarColor(other),
                    child: Text(
                      other.isNotEmpty ? other[0].toUpperCase() : '?',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  if (hasUnread)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: AppColors.accent,
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.bgTop, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      other,
                      style: TextStyle(
                        color: AppColors.text,
                        fontWeight:
                            hasUnread ? FontWeight.w700 : FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: hasUnread ? AppColors.muted : AppColors.subtle,
                        fontSize: 13,
                        fontWeight: hasUnread
                            ? FontWeight.w500
                            : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (lastTs != null)
                    Text(
                      _formatTime(_fromTs(lastTs)),
                      style: TextStyle(
                        color: hasUnread ? AppColors.accent : AppColors.subtle,
                        fontSize: 11,
                        fontWeight: hasUnread
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  if (hasUnread) ...[
                    const SizedBox(height: 4),
                    Container(
                      constraints: const BoxConstraints(minWidth: 20),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(999),
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
      ),
    );
  }
}
