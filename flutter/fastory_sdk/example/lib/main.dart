import 'dart:async';

import 'package:fastory_sdk/fastory_sdk.dart';
import 'package:flutter/material.dart';

const String kBuildLabel = 'fastory_sdk 0.1.2';

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fastory SDK Example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.orange,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const int _gamesIndex = 2;

  int _currentIndex = 0;
  StreamSubscription<FastoryEvent>? _eventsSubscription;

  @override
  void initState() {
    super.initState();
    Fastory.configure(const FastoryConfig(fanzoneSlug: 'your-fanzone'));
    _eventsSubscription = Fastory.events.listen(
      (FastoryEvent event) => debugPrint('Fastory event: $event'),
    );
  }

  @override
  void dispose() {
    _eventsSubscription?.cancel();
    super.dispose();
  }

  void _onItemTapped(int index) {
    if (index == _gamesIndex) {
      Fastory.openGames();
      return;
    }
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(kBuildLabel, style: TextStyle(fontSize: 13)),
        centerTitle: true,
        toolbarHeight: 34,
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: const <Widget>[
          _PlaceholderPage(title: 'Home', icon: Icons.home),
          _PlaceholderPage(title: 'Matches', icon: Icons.sports_soccer),
          SizedBox.shrink(),
          _PlaceholderPage(title: 'Profile', icon: Icons.person),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: _onItemTapped,
        type: BottomNavigationBarType.fixed,
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(
            icon: Icon(Icons.sports_soccer),
            label: 'Matches',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.sports_esports),
            label: 'Games',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}

class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 56),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
          ],
        ),
      ),
    );
  }
}
