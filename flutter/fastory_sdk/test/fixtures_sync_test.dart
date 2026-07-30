// Cross-platform drift guard: packages/sdk/fixtures/*.json is the single source of truth
// (see each file's own "$comment") shared by the Dart, iOS and Android test suites. This file
// proves every platform copy is byte-identical to the source, so a fixture edit that isn't
// propagated everywhere fails here instead of silently diverging per platform.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const List<String> _fixtureNames = <String>[
  'url-policy-cases.json',
  'bridge-protocol-cases.json',
];

void main() {
  // `flutter test` runs with Directory.current == this Flutter package's root
  // (packages/sdk/flutter/fastory_sdk). The shared fixtures source lives two levels up,
  // at packages/sdk/fixtures — computed from Directory.current rather than hardcoded so
  // this works on any machine/CI checkout.
  final Directory sdkRoot = Directory('${Directory.current.path}/../..');
  final Directory sourceDir = Directory('${sdkRoot.path}/fixtures');
  final bool sourceExists = sourceDir.existsSync();

  group('cross-platform fixture drift guard', () {
    for (final String name in _fixtureNames) {
      final File source = File('${sourceDir.path}/$name');

      group(name, () {
        late final List<int> sourceBytes;

        setUpAll(() {
          sourceBytes = source.readAsBytesSync();
        });

        void expectCopyMatches(String label, File copy) {
          test('$label copy matches the source byte-for-byte', () {
            expect(
              copy.existsSync(),
              isTrue,
              reason: 'missing $label fixture copy — expected at ${copy.path}',
            );
            expect(copy.readAsBytesSync(), sourceBytes);
          });
        }

        expectCopyMatches('Dart', File('${Directory.current.path}/test/fixtures/$name'));
        expectCopyMatches(
          'iOS',
          File('${sdkRoot.path}/ios/Tests/FastorySDKTests/Fixtures/$name'),
        );
        expectCopyMatches(
          'Android',
          File('${sdkRoot.path}/android/src/test/resources/fixtures/$name'),
        );
      });
    }
    // Missing platform copies FAIL the relevant test above (naming the expected path) —
    // by design, so the sync guard stays red until every platform actually lands its copy.
  },
      skip: sourceExists
          ? null
          : 'packages/sdk/fixtures not found at ${sourceDir.path} — expected only in the '
              'private monorepo checkout (this looks like a public fastory-sdk-mobile checkout).');
}
