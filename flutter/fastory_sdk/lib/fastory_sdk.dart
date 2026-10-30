import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum FastoryEnvironment { production, staging, development }

/// Appearance the host app asks the web surfaces to render in. Forwarded as a
/// `theme` query parameter; the web side does not read it yet, so setting it is
/// inert until it ships there.
enum FastoryTheme { light, dark }

class FastoryConfig {
  /// Publishable key prefixes, one per environment. A `live` key belongs to
  /// production, a `test` key to everything else.
  static const String livePublishableKeyPrefix = 'fpk_live_';
  static const String testPublishableKeyPrefix = 'fpk_test_';
  static const String _malformedPublishableKey =
      'publishableKey must start with $livePublishableKeyPrefix '
      'or $testPublishableKeyPrefix, followed by the key itself';

  /// Pass exactly one identifier: a [publishableKey] created in the workspace
  /// settings (preferred), or the deprecated [fanzoneSlug].
  ///
  /// Both are optional so that an app written against 0.1 keeps compiling — the
  /// "exactly one" rule is enforced by [validate], which [Fastory.configure]
  /// always calls.
  const FastoryConfig({
    this.publishableKey,
    // ignore: deprecated_member_use_from_same_package
    this.fanzoneSlug,
    this.environment = FastoryEnvironment.production,
    this.hubTabSlug = 'games',
    this.locale,
    this.theme,
    this.developmentBaseUrl,
    this.prewarm = const <FastorySurface>{FastorySurface.hub},
    this.handlesLoginRequests = false,
  });

  /// Non-null only when configured by publishable key.
  final String? publishableKey;

  /// Non-null only when configured by the deprecated slug path.
  ///
  /// Dart cannot deprecate a single constructor parameter, so the annotation
  /// sits on the field: reading it warns, passing it does not.
  @Deprecated(
    'Configure with a publishableKey instead. Create one in the workspace settings. '
    'The fanzone slug keeps working for the whole 0.x window; it will be removed in 1.0.',
  )
  final String? fanzoneSlug;

  final FastoryEnvironment environment;
  final String hubTabSlug;
  final String? locale;
  final FastoryTheme? theme;
  final String? developmentBaseUrl;

  /// The surfaces the SDK prepares before their first opening (SPEC §2.1) — the
  /// hub alone unless you ask for more.
  ///
  /// A prepared surface opens already rendered, and it keeps a WebView resident
  /// from the moment it is prepared. Add [FastorySurface.membership] when your app
  /// opens the membership panel; left out, the panel's first opening loads when
  /// it is asked for, and its page is kept after it closes like any other. An
  /// empty set prepares nothing ahead of time. [FastorySurface.game] has no effect
  /// of its own: games are preloaded from the hub's page, so they follow
  /// [FastorySurface.hub]. The deprecated slug path resolves no workspace, so it
  /// has no panel to prepare and ignores [FastorySurface.membership].
  final Set<FastorySurface> prewarm;

  /// Whether your app signs the fan in when a Fastory page asks it to (SPEC §2.6).
  ///
  /// No page the SDK presents ever shows a login form of its own. Declared, the hub, the
  /// membership panel and the games keep their sign-in entries, and a fan's tap on one reaches
  /// [Fastory.events] as a [FastoryBridgeMessage] of type `fastory:login-requested`: sign the fan
  /// in your own way, then call [Fastory.identify]. Left `false`, the pages show no sign-in entry
  /// at all. Declare it only if you handle that message — otherwise every sign-in entry becomes a
  /// control that does nothing.
  final bool handlesLoginRequests;

  /// Every rule the three platforms enforce identically. Called by [Fastory.configure]
  /// before the platform channel, so a bad configuration throws in Dart instead of
  /// coming back as an opaque `invalid_config` from the native side.
  void validate() {
    if (hubTabSlug.trim().isEmpty) {
      throw ArgumentError.value(hubTabSlug, 'hubTabSlug', 'must not be blank');
    }
    // ignore: deprecated_member_use_from_same_package
    if (publishableKey == null && fanzoneSlug == null) {
      throw ArgumentError('configure with either a publishableKey or a fanzoneSlug');
    }
    // ignore: deprecated_member_use_from_same_package
    if (publishableKey != null && fanzoneSlug != null) {
      throw ArgumentError(
        'configure with a publishableKey or a fanzoneSlug, not both',
      );
    }
    // ignore: deprecated_member_use_from_same_package
    final String? slug = fanzoneSlug;
    if (slug != null && slug.trim().isEmpty) {
      throw ArgumentError.value(slug, 'fanzoneSlug', 'must not be blank');
    }
    final String? key = publishableKey;
    if (key != null) {
      _validatePublishableKey(key);
    }
    if (environment == FastoryEnvironment.development &&
        (developmentBaseUrl == null || developmentBaseUrl!.trim().isEmpty)) {
      throw ArgumentError(
        'developmentBaseUrl is required when environment is development',
      );
    }
  }

  /// Names the rule, never the value. `ArgumentError.value` would put the whole key in
  /// `toString()`, and logging a failed `configure` is the ordinary thing for a host to do — so
  /// the key would reach their crash reporter and their log aggregator for nothing. A publishable
  /// key is not a credential (SPEC.md § 2.5), so this buys no secrecy; it removes a value a third
  /// party has no use for, and matches what the Swift and Kotlin guards already say.
  void _validatePublishableKey(String key) {
    final bool isLive = key.startsWith(livePublishableKeyPrefix);
    final bool isTest = key.startsWith(testPublishableKeyPrefix);
    if (!isLive && !isTest) {
      throw ArgumentError(_malformedPublishableKey);
    }
    // A prefix alone is not a key: reject `fpk_live_` with nothing after it.
    final String prefix =
        isLive ? livePublishableKeyPrefix : testPublishableKeyPrefix;
    if (key.length <= prefix.length) {
      throw ArgumentError(_malformedPublishableKey);
    }
    final String expected = environment == FastoryEnvironment.production
        ? livePublishableKeyPrefix
        : testPublishableKeyPrefix;
    if (prefix != expected) {
      throw ArgumentError(
        'publishableKey does not belong to the ${environment.name} environment: '
        'it expects a key prefixed $expected',
      );
    }
  }

  Map<String, Object?> _toMap() => <String, Object?>{
        'publishableKey': publishableKey,
        // ignore: deprecated_member_use_from_same_package
        'fanzoneSlug': fanzoneSlug,
        'environment': environment.name,
        'hubTabSlug': hubTabSlug,
        'locale': locale,
        'theme': theme?.name,
        'developmentBaseUrl': developmentBaseUrl,
        // A list, since the codec has no set; in declaration order, so one configuration always
        // crosses the channel as one payload.
        'prewarm': <String>[
          for (final FastorySurface surface in FastorySurface.values)
            if (prewarm.contains(surface)) surface.name,
        ],
        'handlesLoginRequests': handlesLoginRequests,
      };
}

sealed class FastoryEvent {
  const FastoryEvent();
}

class FastoryHubOpened extends FastoryEvent {
  const FastoryHubOpened(this.fanzoneSlug);

  final String fanzoneSlug;

  @override
  String toString() => 'FastoryHubOpened(fanzoneSlug: $fanzoneSlug)';
}

class FastoryHubClosed extends FastoryEvent {
  const FastoryHubClosed();

  @override
  String toString() => 'FastoryHubClosed()';
}

/// The membership panel reached the screen with its page loaded (SPEC §5.3).
class FastoryMembershipOpened extends FastoryEvent {
  const FastoryMembershipOpened();

  @override
  String toString() => 'FastoryMembershipOpened()';
}

/// The membership panel was dismissed (SPEC §5.3). Emitted once per presentation,
/// and only for a panel that opened.
class FastoryMembershipClosed extends FastoryEvent {
  const FastoryMembershipClosed();

  @override
  String toString() => 'FastoryMembershipClosed()';
}

class FastoryGameOpened extends FastoryEvent {
  const FastoryGameOpened(this.slug);

  final String slug;

  @override
  String toString() => 'FastoryGameOpened(slug: $slug)';
}

class FastoryGameClosed extends FastoryEvent {
  const FastoryGameClosed();

  @override
  String toString() => 'FastoryGameClosed()';
}

class FastoryExternalLink extends FastoryEvent {
  const FastoryExternalLink(this.url);

  final String url;

  @override
  String toString() => 'FastoryExternalLink(url: $url)';
}

/// A message the Fastory web surface posted through the versioned bridge envelope
/// `{v, type, payload}` (SPEC §13).
///
/// The native side validates the envelope and only forwards types in [knownTypes], so a web
/// release that introduces a new type is dropped by an older SDK rather than breaking it.
class FastoryBridgeMessage extends FastoryEvent {
  const FastoryBridgeMessage(this.type, this.payload);

  /// The allow-list, mirrored from the native cores. Re-applied here because a host can drive
  /// the event channel directly — the same reason the native side re-checks `configure`.
  static const Set<String> knownTypes = <String>{
    'fastory:ready',
    'fastory:login-requested',
  };

  final String type;
  final Map<String, Object?> payload;

  @override
  String toString() => 'FastoryBridgeMessage(type: $type, payload: $payload)';
}

/// Which Fastory surface a load failure is about (SPEC §9.1).
enum FastorySurface { hub, game, membership }

/// How a surface failed to load, as a host branches on it (SPEC §9.1).
///
/// Three cases rather than one per cause: the cause itself is in
/// [FastorySurfaceLoadFailed.code] and [FastorySurfaceLoadFailed.statusCode], and
/// a host that only needs "was anything reachable at all" must not have to
/// enumerate every future API code to answer it.
enum FastoryLoadFailureReason {
  /// Something answered and refused — a publishable key the API rejected, or a
  /// main document that came back with an error status.
  rejected,

  /// Nothing answered: no connection, DNS failure, timeout.
  network,

  /// Neither of the two above. The escape hatch that keeps them meaning exactly
  /// what they say, and the case a host maps to "log it and move on".
  unknown,
}

/// A hub or a game that did not load (SPEC §9.1).
///
/// The SDK reports and never retries on its own: the host is the only party that
/// can decide whether to log it, alert its team, or offer the fan something else.
/// No `FastoryHubOpened` or `FastoryGameOpened` is emitted for a surface that
/// failed, and none of the matching closing events either.
class FastorySurfaceLoadFailed extends FastoryEvent {
  const FastorySurfaceLoadFailed(
    this.surface,
    this.reason, {
    this.code,
    this.statusCode,
  });

  final FastorySurface surface;
  final FastoryLoadFailureReason reason;

  /// The API's machine-readable failure code (`sdk_key_revoked`,
  /// `sdk_application_not_allowed`, …), non-null only when the publishable-key
  /// exchange refused the configuration (SPEC §2.5). Branch on this, never on a
  /// message.
  final String? code;

  /// The HTTP status the surface's main document answered, non-null only when
  /// one did.
  final int? statusCode;

  @override
  String toString() => 'FastorySurfaceLoadFailed(surface: ${surface.name}, '
      'reason: ${reason.name}, code: $code, statusCode: $statusCode)';
}

/// What the web content may ask the native side to answer over the bridge (SPEC §13.8.3).
///
/// An enum rather than a free string, mirroring the native cores: the request registry is
/// the security boundary of § 13.8.4, so a host cannot name a type outside it.
enum FastoryBridgeRequestType {
  /// The stories-origin fan token a game asks its host page for. In an SDK WebView the
  /// game *is* the top-level document, so there is no host page and the native side
  /// answers in its place.
  userToken('fastory:user-token');

  const FastoryBridgeRequestType(this.wireValue);

  /// The registry string the three platforms share, and the value that crosses the
  /// platform channel — never the Dart enum name, which is not the contract.
  final String wireValue;
}

/// Emitted once per successful [Fastory.identify], before any hub or game opening
/// carrying that identity. A refused identification emits nothing — its error is
/// reported to the caller instead. See `SPEC.md` § 2.6.2.
class FastoryIdentityResolved extends FastoryEvent {
  const FastoryIdentityResolved(this.mode, this.fanId);

  final FastoryIdentityMode mode;

  /// Always null in [FastoryIdentityMode.anonymous]: the device visitor is minted
  /// per origin by the web page, so the native side never sees it.
  final String? fanId;

  @override
  String toString() => 'FastoryIdentityResolved(mode: ${mode.name}, fanId: $fanId)';
}

/// Why the SDK dropped a delegated identity on its own (`SPEC.md` § 5.3).
enum FastoryRevocationReason {
  /// A background re-exchange was refused by the API. Carries the API's own code
  /// when it named one.
  rejected,

  /// The embed session expired and could not be renewed — no host-token provider
  /// was registered, so there was no fresh assertion to re-exchange. Carries no code.
  expired,
}

/// The SDK dropped a delegated identity **on its own** (`SPEC.md` § 5.3): a session
/// that expired with no way to renew, or a background re-exchange the API refused.
/// The fan is now anonymous. The host learns why through [reason] so it can
/// re-`identify` with a fresh token or let the fan continue anonymously — never a
/// blank panel. A host-driven `logout()` is not a revocation and never emits this.
class FastoryIdentityRevoked extends FastoryEvent {
  const FastoryIdentityRevoked(this.reason, this.code);

  final FastoryRevocationReason reason;

  /// The API's machine-readable reason, present only for
  /// [FastoryRevocationReason.rejected] and only when the refusal named one.
  final String? code;

  @override
  String toString() => 'FastoryIdentityRevoked(reason: ${reason.name}, code: $code)';
}

/// The identity a host asks the SDK to resolve. See `SPEC.md` § 2.6.
///
/// [FastoryFanId] carries no argument on purpose — it is a Fastory *login* through
/// the system browser, not an identifier the host supplies. [FastoryHostToken] is
/// the opposite: the partner already authenticated the fan, so nothing is typed and
/// no browser opens.
///
/// Sealed, so a mode cannot be combined with another.
sealed class FastoryIdentity {
  const FastoryIdentity();

  Map<String, Object?> _toMap();
}

/// The v0.1 behaviour: each origin's web page mints or reuses its own device visitor.
/// The only mode that resolves in this version.
class FastoryAnonymous extends FastoryIdentity {
  const FastoryAnonymous();

  @override
  Map<String, Object?> _toMap() =>
      <String, Object?>{'mode': 'anonymous', 'jwt': null};
}

/// Fastory login through the system browser. Reserved: fails with
/// `identify_mode_unavailable` until it ships.
class FastoryFanId extends FastoryIdentity {
  const FastoryFanId();

  @override
  Map<String, Object?> _toMap() => <String, Object?>{'mode': 'fanId', 'jwt': null};
}

/// Delegated identity: a JWT signed by the partner's backend, verified server-side.
/// Reserved: fails with `identify_mode_unavailable` until it ships.
class FastoryHostToken extends FastoryIdentity {
  const FastoryHostToken(this.jwt);

  final String jwt;

  @override
  Map<String, Object?> _toMap() =>
      <String, Object?>{'mode': 'hostToken', 'jwt': jwt};
}

enum FastoryIdentityMode { anonymous, fanId, hostToken }

/// Hands the SDK a fresh host assertion when it needs to renew a delegated session
/// (`SPEC.md` § 2.6.3). Registered with [Fastory.setHostTokenProvider] and awaited when
/// the SDK needs a token; returns a fresh JWT, or `null` when the host cannot supply
/// one — in which case the session lapses and the fan becomes anonymous.
typedef FastoryHostTokenProvider = Future<String?> Function();

class FastoryResolvedIdentity {
  const FastoryResolvedIdentity(this.mode, this.fanId);

  final FastoryIdentityMode mode;
  final String? fanId;

  @override
  String toString() =>
      'FastoryResolvedIdentity(mode: ${mode.name}, fanId: $fanId)';

  @override
  bool operator ==(Object other) =>
      other is FastoryResolvedIdentity &&
      other.mode == mode &&
      other.fanId == fanId;

  @override
  int get hashCode => Object.hash(mode, fanId);
}

FastoryIdentityMode? _decodeIdentityMode(Object? raw) {
  // The registry is re-applied on the Dart side for the same reason the native side
  // re-checks configure: a host can drive the channel directly.
  for (final FastoryIdentityMode mode in FastoryIdentityMode.values) {
    if (mode.name == raw) return mode;
  }
  return null;
}

abstract final class Fastory {
  static const MethodChannel _methodChannel = MethodChannel('fastory_sdk');
  static const EventChannel _eventChannel = EventChannel('fastory_sdk/events');
  static Stream<FastoryEvent>? _events;

  static Stream<FastoryEvent> get events => _events ??= _eventChannel
      .receiveBroadcastStream()
      .map(_decodeEvent)
      .where((FastoryEvent? event) => event != null)
      .cast<FastoryEvent>();

  static Future<void> configure(FastoryConfig config) {
    // configure() is documented as callable straight from main(); make sure the platform
    // channel has a binding even when runApp() has not executed yet.
    WidgetsFlutterBinding.ensureInitialized();
    config.validate();
    return _methodChannel.invokeMethod<void>('configure', config._toMap());
  }

  static Future<void> openGames() =>
      _methodChannel.invokeMethod<void>('openGames');

  /// Opens the membership panel full-screen over the host app (`SPEC.md` § 3.5).
  ///
  /// [sequenceId] names one of the sequences the panel already owns and opens it
  /// on that one; naming none lands on the panel's default screen, which stays the
  /// club's setting. It needs a publishable key — a fanzone slug names a fanzone,
  /// not the workspace this surface is addressed by, and rejects with
  /// `publishable_key_required` on that path.
  ///
  /// One surface at a time: called while the hub or the panel is already up, it
  /// does nothing and completes normally. [close] dismisses whichever is showing.
  static Future<void> openMembership({String? sequenceId}) =>
      _methodChannel.invokeMethod<void>('openMembership', <String, Object?>{
        'sequenceId': sequenceId,
      });

  static Future<void> close() => _methodChannel.invokeMethod<void>('close');

  /// Binds the host app's user to a Fastory fan (`SPEC.md` § 2.6).
  ///
  /// Only [FastoryAnonymous] resolves in this version, and calling it twice is a
  /// no-op that hands back the same fan. The two identified modes are reserved
  /// signatures that reject with `identify_mode_unavailable`.
  ///
  /// Rejects with a [PlatformException] carrying one of the § 5.4 codes; it never
  /// completes with a partially resolved identity.
  static Future<FastoryResolvedIdentity> identify(
    FastoryIdentity identity,
  ) async {
    final Map<Object?, Object?>? resolved = await _methodChannel
        .invokeMethod<Map<Object?, Object?>>('identify', identity._toMap());
    final FastoryIdentityMode? mode = _decodeIdentityMode(resolved?['mode']);
    if (mode == null) {
      throw PlatformException(
        code: 'invalid_identity_mode',
        message: 'the native side resolved an unknown mode: ${resolved?['mode']}',
      );
    }
    return FastoryResolvedIdentity(mode, resolved?['fanId'] as String?);
  }

  /// Signs the fan out of Fastory only — the host app's own session is never
  /// touched. Idempotent, and never fails.
  static Future<void> logout() => _methodChannel.invokeMethod<void>('logout');

  static FastoryHostTokenProvider? _hostTokenProvider;
  static bool _requestHandlerInstalled = false;

  /// Registers the closure the SDK calls to obtain a fresh host assertion when a
  /// delegated session must be renewed (`SPEC.md` § 2.6.3). Pass `null` to clear it.
  ///
  /// The SDK calls back into Dart (`requestHostToken`) only when it needs a token;
  /// the provider returns a fresh JWT, or `null` when the host cannot supply one — in
  /// which case the session lapses and the fan becomes anonymous. Setting the provider
  /// never renews anything on its own.
  static Future<void> setHostTokenProvider(
    FastoryHostTokenProvider? provider,
  ) {
    _hostTokenProvider = provider;
    if (!_requestHandlerInstalled) {
      _methodChannel.setMethodCallHandler(_handleMethodCall);
      _requestHandlerInstalled = true;
    }
    // Advertise whether a provider now exists so the native side knows to invoke — or not — when a
    // session needs renewing. The provider itself never crosses the channel; only its answers do.
    return _methodChannel.invokeMethod<void>(
      'setHostTokenProvider',
      <String, Object?>{'hasProvider': provider != null},
    );
  }

  /// Native → Dart calls land here. Only `requestHostToken` is expected: the native side needs a
  /// fresh assertion and the registered provider answers it, or answers `null` when it has none.
  static Future<Object?> _handleMethodCall(MethodCall call) async {
    if (call.method == 'requestHostToken') {
      return _hostTokenProvider == null ? null : await _hostTokenProvider!.call();
    }
    return null;
  }

  /// What the SDK answers the next time a web surface asks for [type] over the bridge
  /// (`SPEC.md` § 13.8) — the fan token a game requests from its host page, in the place
  /// of the host page it does not have.
  ///
  /// Standing rather than resolved on demand: the game asks while it boots, so an answer
  /// that had to be fetched would stall its first paint, and § 13.5 forbids network or disk
  /// on that path anyway. Set it before opening a game. A null [payload] clears it, and a
  /// cleared type is answered with an explicit failure rather than with silence.
  ///
  /// This sets what a *request* gets. It never pushes anything into a page — the SDK
  /// answers, it does not speak first (§ 13).
  static Future<void> setBridgeReply(
    FastoryBridgeRequestType type,
    Map<String, Object?>? payload,
  ) =>
      _methodChannel.invokeMethod<void>('setBridgeReply', <String, Object?>{
        'type': type.wireValue,
        'payload': payload,
      });

  static FastoryEvent? _decodeEvent(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    return switch (raw['type']) {
      'hubOpened' => FastoryHubOpened(raw['slug'] as String? ?? ''),
      'hubClosed' => const FastoryHubClosed(),
      'membershipOpened' => const FastoryMembershipOpened(),
      'membershipClosed' => const FastoryMembershipClosed(),
      'gameOpened' => FastoryGameOpened(raw['slug'] as String? ?? ''),
      'gameClosed' => const FastoryGameClosed(),
      'externalLink' => FastoryExternalLink(raw['url'] as String? ?? ''),
      'bridgeMessage' => _decodeBridgeMessage(raw),
      'identityResolved' => _decodeIdentityResolved(raw),
      'identityRevoked' => _decodeIdentityRevoked(raw),
      'surfaceLoadFailed' => _decodeSurfaceLoadFailed(raw),
      // 'identityRehydrated' and every other type fall here and are dropped: a restoration is not a
      // resolution, so it must never surface as one, and the host reads the rehydrated fan natively.
      _ => null,
    };
  }

  /// An unknown `reason` drops the event rather than guessing: a host branches on
  /// [FastoryIdentityRevoked.reason], so an unrecognised word must not be forced into one of the two.
  static FastoryEvent? _decodeIdentityRevoked(Map<Object?, Object?> raw) {
    final Object? rawReason = raw['reason'];
    for (final FastoryRevocationReason reason in FastoryRevocationReason.values) {
      if (reason.name == rawReason) {
        return FastoryIdentityRevoked(reason, raw['code'] as String?);
      }
    }
    return null;
  }

  /// An unknown `surface` drops the event, exactly as an unknown identity mode
  /// does: a host must not be handed a surface it cannot switch over. An unknown
  /// `reason` does not, because [FastoryLoadFailureReason.unknown] is what that
  /// case means — dropping the whole failure to avoid one unrecognised word would
  /// re-create the silence this event exists to end.
  static FastoryEvent? _decodeSurfaceLoadFailed(Map<Object?, Object?> raw) {
    final Object? rawSurface = raw['surface'];
    for (final FastorySurface surface in FastorySurface.values) {
      if (surface.name == rawSurface) {
        return FastorySurfaceLoadFailed(
          surface,
          FastoryLoadFailureReason.values.firstWhere(
            (FastoryLoadFailureReason reason) => reason.name == raw['reason'],
            orElse: () => FastoryLoadFailureReason.unknown,
          ),
          code: raw['code'] as String?,
          statusCode: raw['statusCode'] as int?,
        );
      }
    }
    return null;
  }

  /// Fails closed like the native decoder: an unknown bridge type, or a payload that is not a
  /// map, is dropped rather than surfaced or thrown (SPEC §5.4, §13.4). `bridgeType` carries the
  /// envelope type because `type` is already the channel's own discriminator.
  static FastoryEvent? _decodeBridgeMessage(Map<Object?, Object?> raw) {
    final Object? type = raw['bridgeType'];
    if (type is! String || !FastoryBridgeMessage.knownTypes.contains(type)) {
      _traceIgnoredBridgeMessage('type outside the registry', raw);
      return null;
    }
    final Object? payload = raw['payload'];
    if (payload != null && payload is! Map) {
      _traceIgnoredBridgeMessage('payload is not a map', raw);
      return null;
    }
    return FastoryBridgeMessage(type, _plainMap(payload));
  }

  /// Debug builds only: an SDK shipping inside third-party apps must not print in production, and
  /// a dropped message is a normal outcome (the web side can be at any version), not an error.
  ///
  /// The event originates from web content, so it is flattened and truncated before printing —
  /// a forged newline would otherwise forge a whole log line.
  static void _traceIgnoredBridgeMessage(String reason, Map<Object?, Object?> raw) {
    if (kDebugMode) {
      final String flattened = raw.toString().replaceAll(RegExp(r'[\r\n]'), r'\n');
      final String excerpt =
          flattened.length <= 256 ? flattened : '${flattened.substring(0, 256)}…';
      debugPrint('fastory_sdk: ignored bridge message — $reason: $excerpt');
    }
  }

  /// The platform codec hands back `Map<Object?, Object?>` at every depth; re-key it so a host
  /// can read a nested payload without casting each level itself.
  static Map<String, Object?> _plainMap(Object? value) {
    if (value is! Map) {
      return const <String, Object?>{};
    }
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> entry in value.entries)
        if (entry.key is String) entry.key! as String: _plainValue(entry.value),
    };
  }

  static Object? _plainValue(Object? value) => switch (value) {
        final Map<Object?, Object?> map => _plainMap(map),
        final List<Object?> list => list.map(_plainValue).toList(),
        _ => value,
      };

  static FastoryEvent? _decodeIdentityResolved(Map<Object?, Object?> raw) {
    final FastoryIdentityMode? mode = _decodeIdentityMode(raw['mode']);
    // An unknown mode is dropped rather than surfaced: the event stream is not an
    // error channel, and a host must not be handed a mode it cannot switch over.
    if (mode == null) return null;
    return FastoryIdentityResolved(mode, raw['fanId'] as String?);
  }
}
