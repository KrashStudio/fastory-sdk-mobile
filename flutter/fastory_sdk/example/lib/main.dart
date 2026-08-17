import 'dart:async';
import 'dart:io' show Platform;

import 'package:fastory_sdk/fastory_sdk.dart';
import 'package:flutter/material.dart';

// Shared look across the three demo apps (iOS native, Android native, Flutter):
// same palette, same four tabs, same screens, same platform badge. Keep them in
// step — an integrator comparing two of them should see one product.
const Color kClubNavy = Color(0xFF0D2147);
const Color kClubGreen = Color(0xFF29C770);
const Color kClubBar = Color(0xFF091834);

String get kClubPlatform => Platform.isIOS ? 'Flutter · iOS' : 'Flutter · Android';

// Pointing the demo at a real fanzone needs a real publishable key, and a key must
// never reach a commit. Run with `--dart-define-from-file=fastory.local.json` (that
// file is gitignored; copy `fastory.local.example.json`). Without it the demo still
// runs, on the placeholder slug — the pre-key behaviour.
const String kPlaceholderFanzoneSlug = 'your-fanzone';
const String kPublishableKey = String.fromEnvironment('FASTORY_PUBLISHABLE_KEY');
const String kEnvironmentName =
    String.fromEnvironment('FASTORY_ENVIRONMENT', defaultValue: 'staging');

FastoryEnvironment get kEnvironment {
  switch (kEnvironmentName.toLowerCase()) {
    case 'production':
      return FastoryEnvironment.production;
    case 'staging':
      return FastoryEnvironment.staging;
    // Failing here beats silently running against the wrong platform: a typo would
    // otherwise look like "the key is rejected" hours later.
    default:
      throw ArgumentError.value(
        kEnvironmentName,
        'FASTORY_ENVIRONMENT',
        "must be 'staging' or 'production'",
      );
  }
}

// `configure` takes exactly one identifier and rejects both-or-neither, so the key and
// the placeholder slug are alternatives, never a pair.
FastoryConfig get kDemoConfig => kPublishableKey.isEmpty
    // ignore: deprecated_member_use
    ? FastoryConfig(
        fanzoneSlug: kPlaceholderFanzoneSlug,
        environment: kEnvironment,
      )
    : FastoryConfig(
        publishableKey: kPublishableKey,
        environment: kEnvironment,
      );

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Demo Club',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: kClubGreen,
          brightness: Brightness.dark,
        ).copyWith(surface: kClubNavy),
        scaffoldBackgroundColor: kClubNavy,
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
    Fastory.configure(kDemoConfig);
    _eventsSubscription = Fastory.events.listen(
      (FastoryEvent event) => debugPrint('Fastory event: $event'),
    );
  }

  @override
  void dispose() {
    _eventsSubscription?.cancel();
    super.dispose();
  }

  // Games is an action, not a destination (identical on all three demos): the
  // hub opens over the current tab and the selection never moves.
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
      backgroundColor: kClubNavy,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            const _ClubHeader(),
            Expanded(
              child: IndexedStack(
                index: _currentIndex,
                children: const <Widget>[
                  _HomeContent(),
                  _CalendarContent(),
                  SizedBox.shrink(),
                  _ProfileContent(),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: _onItemTapped,
        type: BottomNavigationBarType.fixed,
        backgroundColor: kClubBar,
        selectedItemColor: kClubGreen,
        unselectedItemColor: Colors.white.withValues(alpha: 0.6),
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(
            icon: Icon(Icons.calendar_month),
            label: 'Calendar',
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

// Title plus the platform badge: the three demos are pixel-siblings, so the
// badge is the only way to tell at a glance which integration is running.
class _ClubHeader extends StatelessWidget {
  const _ClubHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 20, top: 8, bottom: 16),
      child: Row(
        children: <Widget>[
          const Text(
            'Demo Club',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: kClubGreen.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(50),
            ),
            child: Text(
              kClubPlatform,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: kClubGreen,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeContent extends StatelessWidget {
  const _HomeContent();

  @override
  Widget build(BuildContext context) {
    return _CenteredScreen(
      icon: Icons.sports_soccer,
      iconColor: kClubGreen,
      iconSize: 64,
      title: 'Welcome to the club',
      subtitle: 'News, matches and fan games in one place.',
    );
  }
}

class _ProfileContent extends StatelessWidget {
  const _ProfileContent();

  @override
  Widget build(BuildContext context) {
    return _CenteredScreen(
      icon: Icons.account_circle,
      iconColor: Colors.white.withValues(alpha: 0.85),
      iconSize: 72,
      title: 'Guest fan',
      subtitle: 'Season member since 2024',
    );
  }
}

class _CenteredScreen extends StatelessWidget {
  const _CenteredScreen({
    required this.icon,
    required this.iconColor,
    required this.iconSize,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final Color iconColor;
  final double iconSize;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: iconSize, color: iconColor),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
          ),
        ],
      ),
    );
  }
}

class _CalendarContent extends StatelessWidget {
  const _CalendarContent();

  static const List<(String, String)> _fixtures = <(String, String)>[
    ('Demo FC — Rivertown', 'Sat 21:00'),
    ('Northside — Demo FC', 'Wed 19:45'),
    ('Demo FC — Old Harbour', 'Sun 17:30'),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: <Widget>[
          for (final (String fixture, String time) in _fixtures)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: <Widget>[
                  Text(
                    fixture,
                    style: const TextStyle(color: Colors.white),
                  ),
                  const Spacer(),
                  Text(time, style: const TextStyle(color: kClubGreen)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
