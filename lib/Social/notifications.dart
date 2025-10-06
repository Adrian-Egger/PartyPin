import 'package:flutter/material.dart';
import '../Screens/party_map_screen.dart';
import '../Social/friends.dart';
import '../Screens/new_party.dart';

class NotificationScreen extends StatefulWidget {
  const NotificationScreen({super.key});

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen>
    with TickerProviderStateMixin {
  int _currentIndex = 0;

  List<String> _notifications = [
    "Max Mustermann hat dir eine Freundschaftsanfrage gesendet.",
    "Anna Beispiel hat deinen Beitrag geliked.",
    "Lukas Schmidt hat eine Nachricht geschickt.",
  ];

  final Map<String, AnimationController> _controllers = {};

  @override
  void initState() {
    super.initState();
    for (var n in _notifications) {
      _controllers[n] = AnimationController(
          vsync: this, duration: const Duration(milliseconds: 300));
    }
  }

  @override
  void dispose() {
    for (var c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onBottomNavTapped(int index) {
    if (index == _currentIndex) return;

    setState(() {
      _currentIndex = index;
    });

    if (index == 1) {
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const FriendsScreen()));
    }
    if (index == 2) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const PartyMapScreen()),
      );
    }
    if (index == 3) {
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const NewPartyScreen()));
    }
  }

  void _removeNotification(int index) async {
    final notification = _notifications[index];
    final controller = _controllers[notification]!;

    await controller.forward(); // Slide nach links
    controller.dispose();
    _controllers.remove(notification);

    if (!mounted) return;
    setState(() {
      _notifications.removeAt(index);
    });
  }

  void _clearAllNotifications() async {
    for (int i = _notifications.length - 1; i >= 0; i--) {
      _removeNotification(i);
      await Future.delayed(const Duration(milliseconds: 150));
    }
  }

  Widget _buildItem(String notification, int index) {
    final controller = _controllers[notification]!;
    final animation = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(-1, 0),
    ).animate(CurvedAnimation(parent: controller, curve: Curves.easeOut));

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOutCubic,
      child: SlideTransition(
        position: animation,
        child: Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            leading: const Icon(Icons.notifications, color: Colors.deepPurple),
            title: Text(notification),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => _removeNotification(index),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Benachrichtigungen"),
        backgroundColor: Colors.deepPurple,
      ),
      body: Column(
        children: [
          Expanded(
            child: _notifications.isEmpty
                ? const Center(
              child: Text(
                "Keine Benachrichtigungen",
                style: TextStyle(fontSize: 16),
              ),
            )
                : ListView.builder(
              itemCount: _notifications.length,
              itemBuilder: (context, index) =>
                  _buildItem(_notifications[index], index),
            ),
          ),
          if (_notifications.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _clearAllNotifications,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text(
                    "Alle löschen",
                    style: TextStyle(fontSize: 16),
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: _onBottomNavTapped,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.notifications), label: "Nachrichten"),
          BottomNavigationBarItem(icon: Icon(Icons.people), label: "Freunde"),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: "Map"),
          BottomNavigationBarItem(icon: Icon(Icons.add), label: "Neue Party"),
        ],
      ),
    );
  }
}
