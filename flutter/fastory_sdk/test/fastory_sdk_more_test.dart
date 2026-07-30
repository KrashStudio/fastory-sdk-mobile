// Additional coverage layered on top of fastory_sdk_test.dart (the original 11 tests are
// left untouched there). This file exercises event ordering, error-code passthrough breadth,
// re-configure isolation, and broadcast-stream semantics that the base file does not cover.
import 'dart:async';

import 'package:fastory_sdk/fastory_sdk.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel methodChannel = MethodChannel('fastory_sdk');
  const String eventChannelName = 'fastory_sdk/events';
  const StandardMethodCodec codec = StandardMethodCodec();

  final List<MethodCall> calls = <MethodCall>[];
  Object? Function(MethodCall call)? methodResponder;

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    calls.clear();
    methodResponder = null;
    messenger().setMockMethodCallHandler(methodChannel, (MethodCall call) async {
      calls.add(call);
      return methodResponder?.call(call);
    });
    // The event channel's native side only has to acknowledge listen/cancel.
    messenger().setMockMethodCallHandler(
      const MethodChannel(eventChannelName),
      (MethodCall call) async => null,
    );
  });

  tearDown(() {
    messenger().setMockMethodCallHandler(methodChannel, null);
    messenger().setMockMethodCallHandler(const MethodChannel(eventChannelName), null);
  });

  Future<void> emitEvent(Object? payload) async {
    await messenger().handlePlatformMessage(
      eventChannelName,
      codec.encodeSuccessEnvelope(payload),
      (ByteData? _) {},
    );
  }

  group('events — ordering across a session (SPEC §5.3)', () {
    test('a hub session with a game swap is delivered in exact order', () async {
      final List<FastoryEvent> received = <FastoryEvent>[];
      final StreamSubscription<FastoryEvent> subscription =
          Fastory.events.listen(received.add);
      addTearDown(subscription.cancel);
      await null;

      await emitEvent(<String, Object?>{'type': 'hubOpened', 'slug': 'your-fanzone'});
      await emitEvent(<String, Object?>{'type': 'gameOpened', 'slug': 'summer-quiz'});
      await emitEvent(<String, Object?>{'type': 'gameClosed'});
      await emitEvent(<String, Object?>{'type': 'gameOpened', 'slug': 'winter-raffle'});
      await emitEvent(<String, Object?>{'type': 'gameClosed'});
      await emitEvent(<String, Object?>{'type': 'hubClosed'});
      await null;

      expect(received, hasLength(6));
      expect(received[0], isA<FastoryHubOpened>()
          .having((FastoryHubOpened e) => e.fanzoneSlug, 'fanzoneSlug', 'your-fanzone'));
      expect(received[1], isA<FastoryGameOpened>()
          .having((FastoryGameOpened e) => e.slug, 'slug', 'summer-quiz'));
      expect(received[2], isA<FastoryGameClosed>());
      expect(received[3], isA<FastoryGameOpened>()
          .having((FastoryGameOpened e) => e.slug, 'slug', 'winter-raffle'));
      expect(received[4], isA<FastoryGameClosed>());
      expect(received[5], isA<FastoryHubClosed>());
    });
  });

  group('error mapping — PlatformException codes surface unchanged (SPEC §5.4)', () {
    for (final String code in <String>['not_configured', 'invalid_config', 'already_open']) {
      test('openGames surfaces PlatformException code "$code" unchanged', () async {
        methodResponder = (MethodCall call) => throw PlatformException(code: code);
        expect(
          Fastory.openGames(),
          throwsA(isA<PlatformException>()
              .having((PlatformException e) => e.code, 'code', code)),
        );
      });
    }

    test('configure surfaces a native PlatformException unchanged', () async {
      methodResponder = (MethodCall call) => throw PlatformException(code: 'invalid_config');
      expect(
        Fastory.configure(const FastoryConfig(fanzoneSlug: 'your-fanzone')),
        throwsA(isA<PlatformException>()
            .having((PlatformException e) => e.code, 'code', 'invalid_config')),
      );
    });

    test('an unrecognized error code still surfaces unchanged (no code allow-list on the bridge)',
        () async {
      methodResponder = (MethodCall call) => throw PlatformException(code: 'some_future_code');
      expect(
        Fastory.openGames(),
        throwsA(isA<PlatformException>()
            .having((PlatformException e) => e.code, 'code', 'some_future_code')),
      );
    });

    test('a second configure call after a native error succeeds (recovery)', () async {
      int callCount = 0;
      methodResponder = (MethodCall call) {
        callCount++;
        if (callCount == 1) {
          throw PlatformException(code: 'invalid_config');
        }
        return null;
      };

      try {
        await Fastory.configure(const FastoryConfig(fanzoneSlug: 'your-fanzone'));
        fail('expected the first configure() call to throw');
      } on PlatformException catch (e) {
        expect(e.code, 'invalid_config');
      }

      // The bridge must not be left in a broken state by the previous error.
      await Fastory.configure(const FastoryConfig(fanzoneSlug: 'your-fanzone'));

      expect(calls, hasLength(2));
      expect(calls.every((MethodCall c) => c.method == 'configure'), isTrue);
    });
  });

  group('configure — re-configuring does not leak state (SPEC §2.1)', () {
    test('configuring twice with different slugs sends two independent maps', () async {
      await Fastory.configure(const FastoryConfig(
        fanzoneSlug: 'club-a',
        hubTabSlug: 'games',
        locale: 'en',
      ));
      await Fastory.configure(const FastoryConfig(
        fanzoneSlug: 'club-b',
        hubTabSlug: 'hidden-games',
      ));

      expect(calls, hasLength(2));
      expect(calls[0].arguments, <String, Object?>{
        'fanzoneSlug': 'club-a',
        'environment': 'production',
        'hubTabSlug': 'games',
        'locale': 'en',
        'developmentBaseUrl': null,
      });
      // The second call must not inherit any field from the first (e.g. a leaked
      // locale via a shared mutable map would silently corrupt this).
      expect(calls[1].arguments, <String, Object?>{
        'fanzoneSlug': 'club-b',
        'environment': 'production',
        'hubTabSlug': 'hidden-games',
        'locale': null,
        'developmentBaseUrl': null,
      });
    });
  });

  group('events — broadcast semantics', () {
    test('cancelling a subscription then re-listening keeps delivering events', () async {
      final List<FastoryEvent> firstBatch = <FastoryEvent>[];
      final StreamSubscription<FastoryEvent> first = Fastory.events.listen(firstBatch.add);
      await null;

      await emitEvent(<String, Object?>{'type': 'hubOpened', 'slug': 'club-a'});
      await null;
      expect(firstBatch, hasLength(1));

      await first.cancel();

      final List<FastoryEvent> secondBatch = <FastoryEvent>[];
      final StreamSubscription<FastoryEvent> second = Fastory.events.listen(secondBatch.add);
      addTearDown(second.cancel);
      await null;

      await emitEvent(<String, Object?>{'type': 'hubOpened', 'slug': 'club-b'});
      await null;

      // The cancelled listener must not receive anything emitted after it unsubscribed.
      expect(firstBatch, hasLength(1));
      expect(secondBatch, hasLength(1));
      expect((secondBatch.single as FastoryHubOpened).fanzoneSlug, 'club-b');
    });

    test('multiple concurrent listeners each receive the same events (broadcast fan-out)',
        () async {
      final List<FastoryEvent> receivedA = <FastoryEvent>[];
      final List<FastoryEvent> receivedB = <FastoryEvent>[];
      final StreamSubscription<FastoryEvent> subA = Fastory.events.listen(receivedA.add);
      final StreamSubscription<FastoryEvent> subB = Fastory.events.listen(receivedB.add);
      addTearDown(subA.cancel);
      addTearDown(subB.cancel);
      await null;

      await emitEvent(<String, Object?>{'type': 'hubOpened', 'slug': 'your-fanzone'});
      await null;

      expect(receivedA, hasLength(1));
      expect(receivedB, hasLength(1));
    });

    test('a listener attached right before emission loses nothing (no subscribe-then-wait gap)',
        () async {
      final List<FastoryEvent> received = <FastoryEvent>[];
      final StreamSubscription<FastoryEvent> subscription =
          Fastory.events.listen(received.add);
      addTearDown(subscription.cancel);
      // Deliberately no `await null` here: subscribing must take effect in time for
      // events emitted immediately afterwards, with no microtask gap that drops them.
      await emitEvent(<String, Object?>{'type': 'hubOpened', 'slug': 'your-fanzone'});
      await emitEvent(<String, Object?>{'type': 'hubClosed'});
      await null;

      expect(received, hasLength(2));
    });
  });

  group('FastoryEvent — toString() debug format', () {
    test('every event subtype renders its fields for logs', () {
      expect(
        const FastoryHubOpened('your-fanzone').toString(),
        'FastoryHubOpened(fanzoneSlug: your-fanzone)',
      );
      expect(const FastoryHubClosed().toString(), 'FastoryHubClosed()');
      expect(
        const FastoryGameOpened('summer-quiz').toString(),
        'FastoryGameOpened(slug: summer-quiz)',
      );
      expect(const FastoryGameClosed().toString(), 'FastoryGameClosed()');
      expect(
        const FastoryExternalLink('https://www.instagram.com/fastory').toString(),
        'FastoryExternalLink(url: https://www.instagram.com/fastory)',
      );
    });
  });
}
