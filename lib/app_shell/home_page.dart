import 'package:flutter/material.dart';
import 'package:venera_plus/features/favorites/favorites.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, this.onOpenHistory});

  final VoidCallback? onOpenHistory;

  @override
  Widget build(BuildContext context) {
    return ReadingFavoritesView(onOpenHistory: onOpenHistory);
  }
}
