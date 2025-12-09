import 'package:flutter/material.dart';

class ExcludeFriendsScreen extends StatefulWidget {
  final List<String> friends;
  final List<String> initialExcluded;

  final Color cardColor;
  final Color borderColor;
  final Color accent;
  final Color textPrimary;
  final Color textSecondary;
  final Color panel;

  const ExcludeFriendsScreen({
    super.key,
    required this.friends,
    required this.initialExcluded,
    required this.cardColor,
    required this.borderColor,
    required this.accent,
    required this.textPrimary,
    required this.textSecondary,
    required this.panel,
  });

  @override
  State<ExcludeFriendsScreen> createState() => _ExcludeFriendsScreenState();
}

class _ExcludeFriendsScreenState extends State<ExcludeFriendsScreen> {
  late Set<String> tempExcluded;
  String query = "";

  @override
  void initState() {
    super.initState();
    tempExcluded = widget.initialExcluded.toSet();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.friends
        .where((f) => f.toLowerCase().contains(query.toLowerCase()))
        .toList();

    final allSelected =
        widget.friends.isNotEmpty && tempExcluded.length == widget.friends.length;

    return Scaffold(
      backgroundColor: widget.panel,
      appBar: AppBar(
        backgroundColor: widget.panel,
        elevation: 0,
        centerTitle: true, // mittig
        title: Text(
          "Freunde ausschließen",
          style: TextStyle(
            color: widget.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w800, // fetter
          ),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: widget.textPrimary),
          onPressed: () => Navigator.pop(context, null),
        ),
      ),

      body: Column(
        children: [
          // Suchfeld
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              style: TextStyle(color: widget.textPrimary),
              decoration: InputDecoration(
                hintText: "Freund suchen…",
                hintStyle: TextStyle(color: widget.textSecondary),
                prefixIcon: Icon(Icons.search, color: widget.textSecondary),
                filled: true,
                fillColor: widget.cardColor,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: widget.borderColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: widget.accent, width: 1.2),
                ),
              ),
              onChanged: (v) => setState(() => query = v),
            ),
          ),

          // EIN Button: Toggle alle auswählen/abwählen
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: widget.borderColor),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  foregroundColor:
                  allSelected ? widget.textSecondary : widget.accent,
                ),
                icon: Icon(
                  allSelected ? Icons.remove_done : Icons.done_all,
                  size: 18,
                ),
                label: Text(
                  allSelected ? "Alle abwählen" : "Alle auswählen",
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                onPressed: () {
                  setState(() {
                    if (allSelected) {
                      tempExcluded.clear();
                    } else {
                      tempExcluded
                        ..clear()
                        ..addAll(widget.friends);
                    }
                  });
                },
              ),
            ),
          ),

          Divider(color: widget.borderColor),

          // Liste
          Expanded(
            child: filtered.isEmpty
                ? Center(
              child: Text(
                "Keine Freunde gefunden.",
                style: TextStyle(color: widget.textSecondary),
              ),
            )
                : ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (_, i) {
                final f = filtered[i];
                final checked = tempExcluded.contains(f);

                return CheckboxListTile(
                  title: Text(
                    f,
                    style: TextStyle(color: widget.textPrimary),
                  ),
                  value: checked,
                  activeColor: widget.accent,
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        tempExcluded.add(f);
                      } else {
                        tempExcluded.remove(f);
                      }
                    });
                  },
                );
              },
            ),
          ),

          // Info
          Padding(
            padding: const EdgeInsets.only(bottom: 80, top: 6),
            child: Text(
              allSelected
                  ? "Alle Freunde ausgeschlossen"
                  : "${tempExcluded.length} ausgeschlossen",
              style: TextStyle(color: widget.textSecondary, fontSize: 13),
            ),
          ),
        ],
      ),

      // speichern Button unten fixiert
      bottomSheet: Container(
        color: widget.panel,
        padding: const EdgeInsets.all(16),
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: widget.accent,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: () {
            Navigator.pop(context, tempExcluded.toList());
          },
          child: const Text("Speichern"),
        ),
      ),
    );
  }
}
