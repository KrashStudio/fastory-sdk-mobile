import 'dart:async';

import 'package:fastory_sdk/fastory_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

// Shared structure across the three demo apps (iOS native, Android native, Flutter): same four
// tabs, same console sections in the same order, same palette, same activity glyphs. The charter is
// `docs/DEMO_APPS.md` in the development monorepo — an integrator comparing two of them must see
// one product.
const Color kClubNavy = Color(0xFF0D2147);
const Color kClubGreen = Color(0xFF29C770);
const Color kClubBar = Color(0xFF091834);
const Color kClubRed = Color(0xFFE5484D);

// The one deliberate difference between the three: a screenshot without it is unattributable.
const String kClubPlatform = 'Flutter';

// Stamped from the plugin's pubspec.yaml by tools/sync_cores.py — never edit it by hand.
const String kDeclaredSdkVersion = '0.4.1';

// Pointing the demo at a real fanzone needs a real publishable key, and a key must
// never reach a commit. Run with `--dart-define-from-file=fastory.local.json` (that
// file is gitignored; copy `fastory.local.example.json`). Without it the demo still
// runs, on the placeholder slug — the pre-key behaviour.
const String kPlaceholderFanzoneSlug = 'your-fanzone';
const String kPublishableKey = String.fromEnvironment('FASTORY_PUBLISHABLE_KEY');
const String kEnvironmentName =
    String.fromEnvironment('FASTORY_ENVIRONMENT', defaultValue: 'staging');

// Prefilled so the bridge control works without typing anything, and so does the reserved
// hostToken mode the day it ships: the point is to reach the SDK, not to hold a real credential.
// The jwt is shaped like one and signed by nobody.
const String kSampleFanToken = 'demo-fan-token';
const String kSampleHostTokenJwt =
    'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJkZW1vLWZhbiJ9.not-a-real-signature';

// The hub covers the whole screen, so close() is unobservable unless it is armed beforehand.
const Duration kAutoCloseDelay = Duration(seconds: 5);

// Activity log glyphs, identical across the three demos.
const String kGlyphCall = '→';
const String kGlyphResult = '↩';
const String kGlyphEvent = '←';
const String kGlyphFailure = '✕';

/// What the 'standing answer' line reads once the SDK has dropped the value (SPEC § 13.8.6).
const String kRevokedBridgeReply = 'revoked by the SDK — set it again';

/// One `identify` mode as the console offers it. The two identified modes are reserved signatures —
/// declared, final, and not shipped — so each carries the ticket that will land it and its control
/// is disabled rather than absent: an absent control reads as an oversight, a disabled one with a
/// ticket reads as a decision.
class IdentityModeOption {
  const IdentityModeOption({
    required this.identity,
    required this.label,
    this.blockedBy,
  });

  final FastoryIdentity identity;
  final String label;
  final String? blockedBy;
}

const List<IdentityModeOption> kIdentityModes = <IdentityModeOption>[
  IdentityModeOption(identity: FastoryAnonymous(), label: 'anonymous'),
  IdentityModeOption(
    identity: FastoryFanId(),
    label: 'fanId',
    blockedBy: 'FASTORY-2862',
  ),
  IdentityModeOption(
    identity: FastoryHostToken(kSampleHostTokenJwt),
    label: 'hostToken',
    blockedBy: 'FASTORY-2861',
  ),
];

/// One line of the activity log. The log is the only place where the ordering of calls, results and
/// events is visible, which is what a parity investigation reads first.
class ActivityEntry {
  const ActivityEntry({
    required this.glyph,
    required this.at,
    required this.name,
    required this.detail,
  });

  final String glyph;
  final String at;
  final String name;
  final String detail;
}

/// The last refused call, kept as its machine-readable code — the code is what a host branches on,
/// so it is what the console shows.
class SdkFailure {
  const SdkFailure({required this.call, required this.code});

  final String call;
  final String code;
}

FastoryEnvironment get kEnvironment {
  switch (kEnvironmentName.toLowerCase()) {
    case 'production':
      return FastoryEnvironment.production;
    case 'staging':
      return FastoryEnvironment.staging;
    // Failing here beats silently running against the wrong platform: a typo would otherwise look
    // like "the key is rejected" hours later. The console reports it as a refused configure()
    // rather than taking the app down.
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
FastoryConfig demoConfig({FastoryTheme? theme}) => kPublishableKey.isEmpty
    // ignore: deprecated_member_use
    ? FastoryConfig(
        fanzoneSlug: kPlaceholderFanzoneSlug,
        environment: kEnvironment,
        theme: theme,
      )
    : FastoryConfig(
        publishableKey: kPublishableKey,
        environment: kEnvironment,
        theme: theme,
      );

String get kIdentifierInUse => kPublishableKey.isEmpty
    ? 'fanzone slug $kPlaceholderFanzoneSlug (deprecated)'
    : 'publishable key';

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
  // Four destinations and one action, in the charter's order. Games sits between them because that
  // is where a fan looks for it, not because it is a screen.
  static const int _gamesIndex = 2;

  int _currentIndex = 0;
  final GlobalKey<SdkConsoleState> _console = GlobalKey<SdkConsoleState>();

  /// Games is an action, not a destination: the hub opens over the current tab and the selection
  /// never moves, so there is no intermediate screen and closing the hub lands back in place. The
  /// call is routed through the console rather than straight to the SDK, so it reaches the one log
  /// a tester reads.
  void _onItemTapped(int index) {
    if (index == _gamesIndex) {
      _console.currentState?.openHub();
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
                children: <Widget>[
                  const _HomeContent(),
                  const _CalendarContent(),
                  // The bar returns before the selection moves, so this slot is never shown; it
                  // exists to keep the indices aligned, and it is themed rather than empty because
                  // a platform whose bar switches first would otherwise flash white.
                  const ColoredBox(color: kClubNavy),
                  SdkConsole(key: _console),
                  const _ProfileContent(),
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
          BottomNavigationBarItem(
            icon: Icon(Icons.terminal),
            label: 'SDK',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}

/// The SDK tab, and the reason the demo exists: every public method has a control here and every
/// piece of state the SDK hands back is on screen, never only in the platform log. Sections keep the
/// charter's order — a developer scrolling this after the iOS app should not have to hunt.
///
/// It owns the SDK interaction as well as the display, so a call, its outcome and its failure all
/// land in the one log a tester reads. A real host app configures once from `main()` instead — see
/// the integration guide.
class SdkConsole extends StatefulWidget {
  const SdkConsole({super.key});

  @override
  SdkConsoleState createState() => SdkConsoleState();
}

/// Public so the club shell can reach [openHub] through a [GlobalKey] — the Games entry has to open
/// the hub through the console, not behind its back.
class SdkConsoleState extends State<SdkConsole> {
  static const int _activityLimit = 25;

  StreamSubscription<FastoryEvent>? _eventsSubscription;
  Timer? _autoCloseTimer;

  final TextEditingController _replyController =
      TextEditingController(text: kSampleFanToken);

  bool _configured = false;
  bool _busy = false;
  bool _autoClose = false;
  FastoryTheme? _theme;
  FastoryResolvedIdentity? _identity;
  String _bridgeReply = 'unset';

  /// Whether a standing answer is currently in force, as far as this host knows.
  ///
  /// Not derived from [_bridgeReply]: that string is a display line, and `'cleared'` reads as a
  /// value while meaning the absence of one. Reporting a revocation off it announced one after the
  /// host had already cleared the answer itself — nothing to revoke, and the console said otherwise.
  bool _bridgeReplyIsSet = false;
  String? _lastMessage;
  SdkFailure? _lastFailure;
  final List<ActivityEntry> _activity = <ActivityEntry>[];

  @override
  void initState() {
    super.initState();
    // Configured through the same path as every control, so a bad FASTORY_ENVIRONMENT shows up in
    // the console instead of killing the app.
    unawaited(_configure(null));
    // onError matters as much as the data: an error on the event channel is a failure of a public
    // part of the surface, and without it that failure would surface as an unhandled zone error —
    // invisible in the console, which is the one place a tester looks.
    _eventsSubscription = Fastory.events.listen(
      _onEvent,
      onError: (Object error) => _fail('events', _codeOf(error)),
    );
  }

  @override
  void dispose() {
    _autoCloseTimer?.cancel();
    _eventsSubscription?.cancel();
    _replyController.dispose();
    super.dispose();
  }

  void _onEvent(FastoryEvent event) {
    final ({String name, String detail}) described = _describe(event);
    _log(kGlyphEvent, described.name, described.detail);
    if (!mounted) return;
    setState(() {
      switch (event) {
        // The event is the SDK's own account of the resolution, so it — not identify()'s return
        // value — is what the identity line reflects once it arrives.
        case FastoryIdentityResolved(:final mode, :final fanId):
          _identity = FastoryResolvedIdentity(mode, fanId);
        case FastoryBridgeMessage():
          _lastMessage = described.detail;
        // A surface that did not load lands in Last error with a machine-readable code, which is
        // the whole point of the event: before 0.4.0 a revoked key, an undeclared application
        // identifier and a phone in a tunnel all produced the same native error view and left that
        // section at `none`. It stays logged with the event glyph — `docs/DEMO_APPS.md` reserves
        // `✕` for a *call or result* that failed.
        case FastorySurfaceLoadFailed(:final surface):
          _lastFailure = SdkFailure(
            call: '${surface.name} load',
            code: _failureCode(event),
          );
        default:
          break;
      }
    });
  }

  /// The API's own code when there is one, the reason otherwise. Both are machine-readable, which
  /// is what `docs/DEMO_APPS.md` asks Last error to carry — never a sentence.
  static String _failureCode(FastorySurfaceLoadFailed event) =>
      event.code ?? event.reason.name;

  /// Exhaustive on purpose, with no `default:`. `FastoryEvent` is sealed, so a release that adds an
  /// event stops this file from compiling — the demo noticing before a human has to.
  static ({String name, String detail}) _describe(FastoryEvent event) {
    return switch (event) {
      FastoryHubOpened(:final fanzoneSlug) => (
          name: 'hubOpened',
          detail: 'fanzone: $fanzoneSlug',
        ),
      FastoryHubClosed() => (name: 'hubClosed', detail: '—'),
      FastoryGameOpened(:final slug) => (name: 'gameOpened', detail: 'slug: $slug'),
      FastoryGameClosed() => (name: 'gameClosed', detail: '—'),
      FastoryExternalLink(:final url) => (name: 'externalLink', detail: url),
      FastoryBridgeMessage(:final type, :final payload) => (
          name: 'bridgeMessage',
          detail: '$type $payload',
        ),
      FastoryIdentityResolved(:final mode, :final fanId) => (
          name: 'identityResolved',
          detail: 'mode: ${mode.name} · fanId: ${fanId ?? '—'}',
        ),
      FastorySurfaceLoadFailed(
        :final surface,
        :final reason,
        :final code,
        :final statusCode
      ) =>
        (
          name: 'surfaceLoadFailed',
          detail: <String>[
            'surface=${surface.name}',
            'reason=${reason.name}',
            if (code != null) 'code=$code',
            if (statusCode != null) 'status=$statusCode',
          ].join(' · '),
        ),
    };
  }

  void _log(String glyph, String name, String detail) {
    debugPrint('fastory demo $glyph $name — $detail');
    if (!mounted) return;
    setState(() {
      _activity.insert(
        0,
        ActivityEntry(glyph: glyph, at: _stamp(), name: name, detail: detail),
      );
      if (_activity.length > _activityLimit) _activity.removeLast();
    });
  }

  static String _stamp() {
    final DateTime now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  /// Every SDK call goes through here: a refused call answers a code the console has to show, and
  /// an unguarded rejection would take the demo down with it. Returns whether the call went
  /// through, so no line on screen states an intent the SDK rejected.
  Future<bool> _call(
    String name,
    String detail,
    Future<void> Function() action, {
    String Function()? result,
  }) async {
    _log(kGlyphCall, name, detail);
    setState(() => _busy = true);
    try {
      await action();
      _log(kGlyphResult, name, result?.call() ?? 'ok');
      return true;
    } catch (error) {
      _fail(name, _codeOf(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return false;
  }

  /// The machine-readable code the console shows. A `PlatformException` carries one; nothing else
  /// does, so the type name stands in — a `MissingPluginException` on an unsupported platform has to
  /// be readable too, and catching only the typed cases let everything else escape into an
  /// unawaited future and take the demo down.
  static String _codeOf(Object error) => switch (error) {
        PlatformException(:final String code) => code,
        // configure() validates in Dart before the platform channel, so its rejections carry no
        // platform code.
        ArgumentError() => 'argument_error',
        _ => error.runtimeType.toString(),
      };

  void _fail(String name, String code) {
    _log(kGlyphFailure, name, 'code: $code');
    if (mounted) {
      setState(() => _lastFailure = SdkFailure(call: name, code: code));
    }
  }

  Future<void> _configure(FastoryTheme? theme) async {
    final bool wasConfigured = _configured;
    final FastoryTheme? previousTheme = _theme;
    final bool ok = await _call(
      'configure',
      'theme: ${theme?.name ?? 'none'} · $kIdentifierInUse',
      () => Fastory.configure(demoConfig(theme: theme)),
    );
    if (!mounted) return;
    setState(() {
      _configured = _configured || ok;
      if (ok) _theme = theme;
    });
    // A configure that replaces the configuration revokes the standing bridge answer
    // (SPEC § 13.8.6) — including a plain theme switch, which is the only thing that differs
    // between two of this demo's configurations, and is why the console says so on screen rather
    // than leaving the developer to notice the game went anonymous.
    if (ok && wasConfigured && previousTheme != theme) {
      // Switching the theme is the console's way to reach this path: it is a different
      // configuration, so the SDK drops what the previous one produced (SPEC § 2.1).
      _log(
        kGlyphResult,
        'configure',
        'configuration replaced — warm hub discarded, the next openGames() is a cold open',
      );
      _noteStandingAnswerRevoked('configure');
    }
  }

  void openHub() => unawaited(_openHub());

  Future<void> _openHub() async {
    final bool ok = await _call(
      'openGames',
      'hub over the current tab',
      Fastory.openGames,
    );
    if (!ok || !_autoClose) return;
    _autoCloseTimer?.cancel();
    _autoCloseTimer = Timer(kAutoCloseDelay, () {
      unawaited(_call(
        'close',
        'armed: ${kAutoCloseDelay.inSeconds}s after opening',
        Fastory.close,
      ));
    });
  }

  Future<void> _identify(IdentityModeOption mode) async {
    FastoryResolvedIdentity? resolved;
    final bool ok = await _call(
      'identify',
      'mode: ${mode.label}',
      () async {
        resolved = await Fastory.identify(mode.identity);
      },
      result: () => 'resolved: ${resolved ?? '—'}',
    );
    if (ok && mounted) setState(() => _identity = resolved);
  }

  Future<void> _logout() async {
    final bool ok = await _call('logout', 'Fastory session only', Fastory.logout);
    if (ok && mounted) setState(() => _identity = null);
    if (ok) _noteStandingAnswerRevoked('logout');
  }

  /// The SDK revoked the standing answer, so the console stops claiming it has one.
  ///
  /// A well-behaved host does exactly this — the value is gone whether or not it notices, and the
  /// only alternative is a screen that lies. Mirrored rather than read back: there is no accessor
  /// for the standing answer and there is deliberately none, since the three revocation points are
  /// all calls the host itself just made (SPEC § 13.8.6).
  void _noteStandingAnswerRevoked(String call) {
    if (!_bridgeReplyIsSet) return;
    _log(
      kGlyphResult,
      call,
      'standing bridge answer revoked (SPEC § 13.8.6) — the next request is answered `unavailable`',
    );
    if (mounted) {
      setState(() {
        _bridgeReply = kRevokedBridgeReply;
        _bridgeReplyIsSet = false;
      });
    }
  }

  Future<void> _setBridgeReply(Map<String, Object?>? payload) async {
    final bool ok = await _call(
      'setBridgeReply',
      '${FastoryBridgeRequestType.userToken.wireValue} · ${payload ?? 'cleared'}',
      () => Fastory.setBridgeReply(FastoryBridgeRequestType.userToken, payload),
    );
    if (ok && mounted) {
      setState(() {
        _bridgeReply = payload == null ? 'cleared' : '$payload';
        _bridgeReplyIsSet = payload != null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: <Widget>[
        _ConsoleSection(
          title: 'Runtime',
          children: <Widget>[
            const _ValueLine(label: 'sdk version', value: kDeclaredSdkVersion),
            const _ValueLine(label: 'environment', value: kEnvironmentName),
            _ValueLine(label: 'identifier', value: kIdentifierInUse),
            _ValueLine(label: 'configured', value: _configured ? 'yes' : 'no'),
            const _ActionRow(
              children: <Widget>[
                // Present and disabled with the reason on screen, per docs/DEMO_APPS.md: the two
                // native consoles have this control, and an absent section reads as an oversight
                // while a disabled one reads as a decision.
                _Action(label: 'configure() off the main thread', onPressed: null),
              ],
            ),
            const _Hint(
              'SPEC § 2.7 is a contract with the native cores, and there is no Dart side to it: a '
              'platform-channel call already arrives on the platform thread, and Dart has no host '
              'thread to call from. The iOS and Android consoles carry the live control.',
            ),
          ],
        ),
        _ConsoleSection(
          title: 'Hub',
          children: <Widget>[
            _ActionRow(
              children: <Widget>[
                _Action(label: 'openGames', onPressed: _busy ? null : openHub),
                _Action(
                  label: 'close',
                  onPressed: _busy
                      ? null
                      : () => unawaited(
                            _call('close', 'from the console', Fastory.close),
                          ),
                ),
              ],
            ),
            _Toggle(
              label: 'close ${kAutoCloseDelay.inSeconds}s after opening',
              value: _autoClose,
              onChanged: (bool armed) => setState(() => _autoClose = armed),
            ),
            const _Hint(
              'The hub covers the screen, so close() is only observable when it is armed before '
              'opening. hubOpened fires on every opening whose page loaded, pre-warmed or not; '
              'one that does not load sends surfaceLoadFailed instead, and no hubClosed after it '
              '(SPEC § 9.1).',
            ),
          ],
        ),
        _ConsoleSection(
          title: 'Appearance',
          children: <Widget>[
            _ValueLine(label: 'theme hint', value: _theme?.name ?? 'none'),
            _ActionRow(
              children: <Widget>[
                for (final FastoryTheme? option in <FastoryTheme?>[
                  null,
                  FastoryTheme.light,
                  FastoryTheme.dark,
                ])
                  _Action(
                    label: option?.name ?? 'none',
                    selected: _theme == option,
                    onPressed:
                        _busy ? null : () => unawaited(_configure(option)),
                  ),
              ],
            ),
            const _Hint(
              'Switching re-runs configure(); the web side does not read the hint yet. Since the '
              'configuration differs, it also drops the warm hub and revokes the standing bridge '
              'answer (SPEC § 2.1, § 13.8.6) — the activity log shows both.',
            ),
          ],
        ),
        _ConsoleSection(
          title: 'Identity',
          children: <Widget>[
            _ValueLine(
              label: 'resolved',
              value: _identity == null
                  ? 'nobody — identify() has not resolved'
                  : '${_identity!.mode.name} · fanId: ${_identity!.fanId ?? '—'}',
            ),
            _ActionRow(
              children: <Widget>[
                for (final IdentityModeOption mode in kIdentityModes)
                  _Action(
                    label: mode.blockedBy == null
                        ? mode.label
                        : '${mode.label} · ${mode.blockedBy}',
                    onPressed: _busy || mode.blockedBy != null
                        ? null
                        : () => unawaited(_identify(mode)),
                  ),
                _Action(
                  label: 'logout',
                  onPressed: _busy ? null : () => unawaited(_logout()),
                ),
              ],
            ),
            const _Hint(
              'The two identified modes are declared with their final signature and are not '
              'shipped, so their control is disabled and labelled with the ticket that lands it.',
            ),
          ],
        ),
        _ConsoleSection(
          title: 'Bridge reply',
          children: <Widget>[
            _ValueLine(label: 'standing answer', value: _bridgeReply),
            _ConsoleField(
              controller: _replyController,
              label: '${FastoryBridgeRequestType.userToken.wireValue} token',
            ),
            _ActionRow(
              children: <Widget>[
                _Action(
                  label: 'set',
                  onPressed: _busy
                      ? null
                      : () => unawaited(_setBridgeReply(<String, Object?>{
                            'token': _replyController.text,
                          })),
                ),
                _Action(
                  label: 'clear',
                  onPressed:
                      _busy ? null : () => unawaited(_setBridgeReply(null)),
                ),
              ],
            ),
            const _Hint(
              'Set it before opening the hub: the game asks while it boots, so a later answer '
              'misses that session.',
            ),
          ],
        ),
        _ConsoleSection(
          title: 'Last message',
          children: <Widget>[
            _ValueLine(
              label: 'from web',
              value: _lastMessage ?? 'nothing received yet',
            ),
          ],
        ),
        _ConsoleSection(
          title: 'Last error',
          children: <Widget>[
            _ValueLine(
              label: 'code',
              value: _lastFailure?.code ?? 'none',
              tone: _lastFailure == null ? null : kClubRed,
            ),
            _ValueLine(label: 'call', value: _lastFailure?.call ?? '—'),
          ],
        ),
        _ConsoleSection(
          title: 'Activity',
          children: <Widget>[
            if (_activity.isEmpty)
              const _ValueLine(label: 'log', value: 'nothing yet')
            else
              for (final ActivityEntry entry in _activity)
                _ValueLine(
                  label: '${entry.at} ${entry.glyph}',
                  value: '${entry.name} — ${entry.detail}',
                  tone: entry.glyph == kGlyphFailure ? kClubRed : null,
                ),
            const _Hint(
              '$kGlyphCall call · $kGlyphResult result · $kGlyphEvent event · '
              '$kGlyphFailure failure',
            ),
          ],
        ),
      ],
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
            child: const Text(
              kClubPlatform,
              style: TextStyle(
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

class _ConsoleSection extends StatelessWidget {
  const _ConsoleSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              color: kClubGreen,
              fontWeight: FontWeight.w700,
              fontSize: 13,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

class _ValueLine extends StatelessWidget {
  const _ValueLine({required this.label, required this.value, this.tone});

  final String label;
  final String value;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: tone ?? Colors.white,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(spacing: 8, runSpacing: 8, children: children),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.label,
    required this.onPressed,
    this.selected = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        backgroundColor:
            selected ? kClubGreen : Colors.white.withValues(alpha: 0.10),
        foregroundColor: selected ? kClubBar : Colors.white,
        disabledForegroundColor: Colors.white.withValues(alpha: 0.35),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        minimumSize: const Size(0, 34),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 12,
            ),
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeTrackColor: kClubGreen,
        ),
      ],
    );
  }
}

class _ConsoleField extends StatelessWidget {
  const _ConsoleField({required this.controller, required this.label});

  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: TextField(
        controller: controller,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontFamily: 'monospace',
        ),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 12,
          ),
          isDense: true,
          enabledBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
          ),
          focusedBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: kClubGreen),
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.45),
          fontSize: 11,
          height: 1.35,
        ),
      ),
    );
  }
}
