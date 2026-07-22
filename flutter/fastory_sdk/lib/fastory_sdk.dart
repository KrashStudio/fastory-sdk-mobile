import 'package:flutter/services.dart';

enum FastoryEnvironment { production, staging, development }

class FastoryConfig {
  const FastoryConfig({
    required this.fanzoneSlug,
    this.environment = FastoryEnvironment.production,
    this.hubTabSlug = 'games-app',
    this.locale,
    this.developmentBaseUrl,
  });

  final String fanzoneSlug;
  final FastoryEnvironment environment;
  final String hubTabSlug;
  final String? locale;
  final String? developmentBaseUrl;

  Map<String, Object?> _toMap() => <String, Object?>{
        'fanzoneSlug': fanzoneSlug,
        'environment': environment.name,
        'hubTabSlug': hubTabSlug,
        'locale': locale,
        'developmentBaseUrl': developmentBaseUrl,
      };
}

sealed class FastoryEvent {
  const FastoryEvent();
}

class FastoryHubOpened extends FastoryEvent {
  const FastoryHubOpened();

  @override
  String toString() => 'FastoryHubOpened()';
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
    if (config.fanzoneSlug.trim().isEmpty) {
      throw ArgumentError.value(
        config.fanzoneSlug,
        'fanzoneSlug',
        'must not be blank',
      );
    }
    if (config.hubTabSlug.trim().isEmpty) {
      throw ArgumentError.value(
        config.hubTabSlug,
        'hubTabSlug',
        'must not be blank',
      );
    }
    if (config.environment == FastoryEnvironment.development &&
        (config.developmentBaseUrl?.trim().isEmpty ?? true)) {
      throw ArgumentError(
        'developmentBaseUrl is required when environment is development',
      );
    }
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
      'hubOpened' => const FastoryHubOpened(),
      'hubClosed' => const FastoryHubClosed(),
      'gameOpened' => FastoryGameOpened(raw['slug'] as String? ?? ''),
      'gameClosed' => const FastoryGameClosed(),
      'externalLink' => FastoryExternalLink(raw['url'] as String? ?? ''),
      _ => null,
    };
  }
}
