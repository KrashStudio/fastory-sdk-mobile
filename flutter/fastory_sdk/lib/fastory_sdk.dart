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

  /// Pass exactly one identifier: a [publishableKey] created in the workspace
  /// settings (preferred), or the deprecated [fanzoneSlug].
  ///
  /// Both are optional so that an app written against 0.1 keeps compiling — the
  /// "exactly one" rule is enforced by [validate], which [Fastory.configure]
  /// always calls.
  ///
  /// [workspaceId] is an optional cross-check: when set, a key resolving to a
  /// different workspace is rejected, which catches a key pasted into the wrong
  /// app rather than failing silently on someone else's fanzone.
  const FastoryConfig({
    this.publishableKey,
    // ignore: deprecated_member_use_from_same_package
    this.fanzoneSlug,
    this.workspaceId,
    this.environment = FastoryEnvironment.production,
    this.hubTabSlug = 'games',
    this.locale,
    this.theme,
    this.developmentBaseUrl,
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

  final String? workspaceId;
  final FastoryEnvironment environment;
  final String hubTabSlug;
  final String? locale;
  final FastoryTheme? theme;
  final String? developmentBaseUrl;

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
    final String? workspace = workspaceId;
    if (workspace != null && workspace.trim().isEmpty) {
      throw ArgumentError.value(
        workspace,
        'workspaceId',
        'must not be blank when provided',
      );
    }
    if (environment == FastoryEnvironment.development &&
        (developmentBaseUrl == null || developmentBaseUrl!.trim().isEmpty)) {
      throw ArgumentError(
        'developmentBaseUrl is required when environment is development',
      );
    }
  }

  void _validatePublishableKey(String key) {
    final bool isLive = key.startsWith(livePublishableKeyPrefix);
    final bool isTest = key.startsWith(testPublishableKeyPrefix);
    if (!isLive && !isTest) {
      throw ArgumentError.value(
        key,
        'publishableKey',
        'must start with $livePublishableKeyPrefix or $testPublishableKeyPrefix',
      );
    }
    // A prefix alone is not a key: reject `fpk_live_` with nothing after it.
    final String prefix =
        isLive ? livePublishableKeyPrefix : testPublishableKeyPrefix;
    if (key.length <= prefix.length) {
      throw ArgumentError.value(
        key,
        'publishableKey',
        'must start with $livePublishableKeyPrefix or $testPublishableKeyPrefix',
      );
    }
    final String expected = environment == FastoryEnvironment.production
        ? livePublishableKeyPrefix
        : testPublishableKeyPrefix;
    if (prefix != expected) {
      throw ArgumentError.value(
        key,
        'publishableKey',
        'does not belong to the ${environment.name} environment',
      );
    }
  }

  Map<String, Object?> _toMap() => <String, Object?>{
        'publishableKey': publishableKey,
        'workspaceId': workspaceId,
        // ignore: deprecated_member_use_from_same_package
        'fanzoneSlug': fanzoneSlug,
        'environment': environment.name,
        'hubTabSlug': hubTabSlug,
        'locale': locale,
        'theme': theme?.name,
        'developmentBaseUrl': developmentBaseUrl,
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

  static Future<void> close() => _methodChannel.invokeMethod<void>('close');

  static FastoryEvent? _decodeEvent(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    return switch (raw['type']) {
      'hubOpened' => FastoryHubOpened(raw['slug'] as String? ?? ''),
      'hubClosed' => const FastoryHubClosed(),
      'gameOpened' => FastoryGameOpened(raw['slug'] as String? ?? ''),
      'gameClosed' => const FastoryGameClosed(),
      'externalLink' => FastoryExternalLink(raw['url'] as String? ?? ''),
      _ => null,
    };
  }
}
