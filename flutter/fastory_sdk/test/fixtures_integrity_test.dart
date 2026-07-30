// The Dart plugin has no UrlPolicy or bridge parser of its own (URL decisions and the
// v1 postMessage envelope are native/future concerns — see v1_contracts_test.dart), so this
// suite does not execute any decision logic. It only validates the *shape* of the shared
// fixtures (packages/sdk/fixtures/*.json, mirrored at test/fixtures/) so a malformed edit to
// either file fails fast here — the cheapest suite to run — rather than surfacing as a
// confusing failure in the iOS/Android/v1 suites that actually consume it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _readFixture(String name) {
  return jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map<String, Object?>;
}

List<Map<String, Object?>> _cases(Map<String, Object?> fixture) {
  return (fixture['cases'] as List<Object?>).cast<Map<String, Object?>>();
}

void main() {
  group('url-policy-cases.json integrity', () {
    late final Map<String, Object?> fixture;
    late final List<Map<String, Object?>> cases;

    setUpAll(() {
      fixture = _readFixture('url-policy-cases.json');
      cases = _cases(fixture);
    });

    test('schemaVersion is 1', () {
      expect(fixture['schemaVersion'], 1);
    });

    test('every case has a non-blank name, url and decision', () {
      for (final Map<String, Object?> testCase in cases) {
        expect(testCase['name'], isA<String>());
        expect((testCase['name']! as String).trim(), isNotEmpty);
        expect(testCase['url'], isA<String>());
        expect((testCase['url']! as String).trim(), isNotEmpty);
        expect(testCase['decision'], isA<String>());
      }
    });

    test('every decision is one of the allowed values', () {
      const Set<String> allowed = <String>{'gameSheet', 'allow', 'external'};
      for (final Map<String, Object?> testCase in cases) {
        expect(
          allowed,
          contains(testCase['decision']),
          reason: 'unexpected decision "${testCase['decision']}" in case "${testCase['name']}"',
        );
      }
    });

    test('every since is one of the allowed values', () {
      const Set<String> allowed = <String>{'0.1', 'v1'};
      for (final Map<String, Object?> testCase in cases) {
        expect(
          allowed,
          contains(testCase['since']),
          reason: 'unexpected since "${testCase['since']}" in case "${testCase['name']}"',
        );
      }
    });

    test('case names are unique', () {
      final List<String> names =
          cases.map((Map<String, Object?> c) => c['name']! as String).toList();
      expect(names.toSet(), hasLength(names.length));
    });
  });

  // Parallel integrity guard for the v1 bridge-envelope fixture (FASTORY-2552, see
  // v1_contracts_test.dart) — same rationale, different schema shape.
  group('bridge-protocol-cases.json integrity', () {
    late final Map<String, Object?> fixture;
    late final List<Map<String, Object?>> cases;

    setUpAll(() {
      fixture = _readFixture('bridge-protocol-cases.json');
      cases = _cases(fixture);
    });

    test('schemaVersion and envelopeVersion are 1', () {
      expect(fixture['schemaVersion'], 1);
      expect(fixture['envelopeVersion'], 1);
    });

    test('every case has a non-blank name, a message, and a knownTypes list', () {
      for (final Map<String, Object?> testCase in cases) {
        expect(testCase['name'], isA<String>());
        expect((testCase['name']! as String).trim(), isNotEmpty);
        expect(testCase['message'], isA<String>());
        expect(testCase['knownTypes'], isA<List<Object?>>());
      }
    });

    test('every decision is one of the allowed values', () {
      const Set<String> allowed = <String>{'accept', 'ignore'};
      for (final Map<String, Object?> testCase in cases) {
        expect(
          allowed,
          contains(testCase['decision']),
          reason: 'unexpected decision "${testCase['decision']}" in case "${testCase['name']}"',
        );
      }
    });

    test('every case is tagged since "v1"', () {
      for (final Map<String, Object?> testCase in cases) {
        expect(testCase['since'], 'v1');
      }
    });

    test('case names are unique', () {
      final List<String> names =
          cases.map((Map<String, Object?> c) => c['name']! as String).toList();
      expect(names.toSet(), hasLength(names.length));
    });
  });
}
