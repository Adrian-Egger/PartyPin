import 'package:flutter/material.dart';
import 'my_bar_screen.dart';

class MyBarTab extends StatelessWidget {
  final String barId;
  final int myIndex;
  final ValueNotifier<int> tabIndex;

  const MyBarTab({
    super.key,
    required this.barId,
    required this.myIndex,
    required this.tabIndex,
  });

  @override
  Widget build(BuildContext context) {
    return MyBarScreen(barId: barId);
  }
}
