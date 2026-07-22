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

  group('configure — platform channel contract (SPEC §5.2)', () {
    test('sends the full configure map with defaults applied', () async {
      await Fastory.configure(const FastoryConfig(fanzoneSlug: '433'));

      expect(calls, hasLength(1));
      expect(calls.single.method, 'configure');
      expect(calls.single.arguments, <String, Object?>{
        'fanzoneSlug': '433',
        'environment': 'production',
        'hubTabSlug': 'games-app',
        'locale': null,
        'developmentBaseUrl': null,
      });
    });

    test('sends every configured field', () async {
      await Fastory.configure(const FastoryConfig(
        fanzoneSlug: '433',
        environment: FastoryEnvironment.development,
        hubTabSlug: 'hidden-games',
        locale: 'fr-FR',
        developmentBaseUrl: 'https://fanzone-dev.tl:4001',
      ));

      expect(calls.single.arguments, <String, Object?>{
        'fanzoneSlug': '433',
        'environment': 'development',
        'hubTabSlug': 'hidden-games',
        'locale': 'fr-FR',
        'developmentBaseUrl': 'https://fanzone-dev.tl:4001',
      });
    });

    test('environment enum names match the channel contract', () async {
      for (final FastoryEnvironment environment in <FastoryEnvironment>[
        FastoryEnvironment.production,
        FastoryEnvironment.staging,
      ]) {
        await Fastory.configure(FastoryConfig(
          fanzoneSlug: '433',
          environment: environment,
        ));
      }
      expect(
        calls.map((MethodCall call) =>
            (call.arguments as Map<Object?, Object?>)['environment']),
        <String>['production', 'staging'],
      );
    });

    test('rejects a blank fanzoneSlug before touching the channel', () async {
      expect(
        () => Fastory.configure(const FastoryConfig(fanzoneSlug: '  ')),
        throwsArgumentError,
      );
      expect(calls, isEmpty);
    });

    test('rejects a blank hubTabSlug', () {
      expect(
        () => Fastory.configure(
          const FastoryConfig(fanzoneSlug: '433', hubTabSlug: ''),
        ),
        throwsArgumentError,
      );
    });

    test('rejects development without developmentBaseUrl', () {
      expect(
        () => Fastory.configure(const FastoryConfig(
          fanzoneSlug: '433',
          environment: FastoryEnvironment.development,
        )),
        throwsArgumentError,
      );
    });
  });

  group('openGames / close (SPEC §5.2)', () {
    test('openGames invokes the method with no arguments', () async {
      await Fastory.openGames();
      expect(calls.single.method, 'openGames');
      expect(calls.single.arguments, isNull);
    });

    test('close invokes the method with no arguments', () async {
      await Fastory.close();
      expect(calls.single.method, 'close');
      expect(calls.single.arguments, isNull);
    });

    test('native errors surface as PlatformException (SPEC §5.4)', () async {
      methodResponder = (MethodCall call) {
        throw PlatformException(code: 'not_configured');
      };
      expect(
        Fastory.openGames(),
        throwsA(isA<PlatformException>()
            .having((PlatformException e) => e.code, 'code', 'not_configured')),
      );
    });
  });

  group('events — payload decoding (SPEC §5.3)', () {
    test('decodes the five event payloads into sealed classes', () async {
      final List<FastoryEvent> received = <FastoryEvent>[];
      final Stream<FastoryEvent> events = Fastory.events;
      events.listen(received.add);
      await null;

      await emitEvent(<String, Object?>{'type': 'hubOpened', 'slug': '433'});
      await emitEvent(<String, Object?>{'type': 'gameOpened', 'slug': 'summer-quiz'});
      await emitEvent(<String, Object?>{'type': 'gameClosed'});
      await emitEvent(<String, Object?>{
        'type': 'externalLink',
        'url': 'https://www.instagram.com/433',
      });
      await emitEvent(<String, Object?>{'type': 'hubClosed'});
      await null;

      expect(received, hasLength(5));
      expect(received[0], isA<FastoryHubOpened>()
          .having((FastoryHubOpened event) => event.fanzoneSlug, 'fanzoneSlug', '433'));
      expect(received[1], isA<FastoryGameOpened>()
          .having((FastoryGameOpened event) => event.slug, 'slug', 'summer-quiz'));
      expect(received[2], isA<FastoryGameClosed>());
      expect(received[3], isA<FastoryExternalLink>()
          .having((FastoryExternalLink event) => event.url, 'url',
              'https://www.instagram.com/433'));
      expect(received[4], isA<FastoryHubClosed>());
    });

    test('drops unknown event types and non-map payloads', () async {
      final List<FastoryEvent> received = <FastoryEvent>[];
      Fastory.events.listen(received.add);
      await null;

      await emitEvent(<String, Object?>{'type': 'somethingNew'});
      await emitEvent('not-a-map');
      await emitEvent(<String, Object?>{'type': 'hubOpened'});
      await null;

      expect(received, hasLength(1));
      expect(received.single, isA<FastoryHubOpened>());
    });
  });
}
