import 'package:flutter/material.dart';
import '../Screens/menu_screen.dart';
import '../Screens/party_map_screen.dart';
import '../Social/notifications.dart';
import '../Screens/new_party.dart';
import '../Screens/chat_screen.dart';

enum PartyType { open, closed }

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  int _currentIndex = 1; // Friends ist Index 1

  final List<String> allFriends = [
    "Max Mustermann",
    "Anna Beispiel",
    "Lukas Schmidt",
    "Maria Müller",
    "Peter Klein",
  ];
  List<String> filteredFriends = [];

  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    filteredFriends = List.from(allFriends);
  }

  void _onSearchChanged(String query) {
    setState(() {
      if (query.isEmpty) {
        filteredFriends = List.from(allFriends);
      } else {
        filteredFriends = allFriends
            .where((friend) =>
            friend.toLowerCase().contains(query.toLowerCase()))
            .toList();
      }
    });
  }

  void _onBottomNavTapped(int index) async {
    if (_currentIndex == index) return;
    setState(() => _currentIndex = index);

    if (index == 0) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const NotificationScreen()),
      );
    } else if (index == 1) {
      // Already on FriendsScreen
    } else if (index == 2) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const PartyMapScreen()),
      );
    } else if (index == 3) {
      final result = await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const NewPartyScreen()),
      );
    }
  }

  void _addFriendDialog() {
    showDialog(
      context: context,
      builder: (context) {
        final TextEditingController _newFriendController =
        TextEditingController();
        List<String> searchResults = List.from(allFriends);

        return StatefulBuilder(
          builder: (context, setStateDialog) {
            void _onDialogSearchChanged(String query) {
              setStateDialog(() {
                if (query.isEmpty) {
                  searchResults = List.from(allFriends);
                } else {
                  searchResults = allFriends
                      .where((friend) =>
                      friend.toLowerCase().contains(query.toLowerCase()))
                      .toList();
                }
              });
            }

            return AlertDialog(
              title: const Text("Freund hinzufügen"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _newFriendController,
                    onChanged: _onDialogSearchChanged,
                    decoration: InputDecoration(
                      hintText: "Name suchen...",
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 150,
                    width: double.maxFinite,
                    child: ListView.builder(
                      itemCount: searchResults.length,
                      itemBuilder: (context, index) {
                        return ListTile(
                          title: Text(searchResults[index]),
                          trailing: IconButton(
                            icon: const Icon(Icons.add, color: Colors.deepPurple),
                            onPressed: () {
                              if (!allFriends.contains(searchResults[index])) {
                                setState(() {
                                  allFriends.add(searchResults[index]);
                                  filteredFriends.add(searchResults[index]);
                                });
                              }
                              Navigator.pop(context);
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Schließen"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Freunde"),
        backgroundColor: Colors.deepPurple,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(70),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black12,
                          blurRadius: 4,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: TextField(
                      controller: _searchController,
                      onChanged: _onSearchChanged,
                      decoration: InputDecoration(
                        hintText: "Freunde suchen...",
                        prefixIcon: const Icon(Icons.search),
                        border: InputBorder.none,
                        contentPadding:
                        const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _addFriendDialog,
                  child: Container(
                    padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.deepPurple,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: const [
                        Icon(Icons.add, color: Colors.white),
                        SizedBox(width: 4),
                        Text(
                          "Freund hinzufügen",
                          style: TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: ListView.builder(
        itemCount: filteredFriends.length,
        itemBuilder: (context, index) {
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: Colors.deepPurple,
                child: Icon(Icons.person, color: Colors.white),
              ),
              title: Text(filteredFriends[index]),
              trailing: IconButton(
                icon: const Icon(Icons.message),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChatScreen(
                        friendName: filteredFriends[index],
                        friendId: '',
                      ),
                    ),
                  );
                },
              ),
            ),
          );
        },
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
