// Dormant TDD scaffold for the v1 postMessage bridge envelope (docs/sdk/V1_PLAN.md). Every
// test is skipped and its body is a structured comment (intended call + behavior assertions)
// plus a trivial placeholder so the file compiles against TODAY's API. Un-skip and fill in
// real assertions when FASTORY-2552 starts.
//
// Fixture: packages/sdk/fixtures/bridge-protocol-cases.json (mirrored at
// test/fixtures/bridge-protocol-cases.json, integrity-checked by fixtures_integrity_test.dart,
// drift-checked cross-platform by fixtures_sync_test.dart). Envelope shape frozen as
// {v, type, payload}; v1 transport is URL interception, postMessage replaces it progressively.
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('bridge envelope — postMessage, allow-list, coexistence with interception (FASTORY-2552)',
      () {
    test(
        'a well-formed envelope with a known type decodes into a new bridge event, coexisting '
        'with URL interception', () {
      // Intended contract:
      // - A new FastoryEvent subtype (e.g. FastoryBridgeMessage(type, payload)) is added to
      //   the sealed FastoryEvent hierarchy and surfaces on Fastory.events.
      // - Matches bridge-protocol-cases.json "accept" cases: strict integer `v == 1`, a `type`
      //   present in the host's known-type allow-list, `payload` optional (defaults to an
      //   empty map when absent).
      // - postMessage and URL interception coexist in v1 ("allow-list, coexistence with
      //   interception" — V1_PLAN.md): receiving a bridge message must not suppress or replace
      //   the existing URLPolicy interception of the same WebView navigation.
      expect(true, isTrue);
    }, skip: 'v1: bridge envelope — un-skip when FASTORY-2552 starts');

    test('an envelope with an unknown type is ignored (allow-list model)', () {
      // Intended contract: matches bridge-protocol-cases.json "ignore" cases for unknown
      // types — no event is emitted and no exception is thrown; unrecognized types are
      // silently dropped, exactly like unknown event `type` discriminators are dropped by
      // Fastory._decodeEvent today.
      expect(true, isTrue);
    }, skip: 'v1: bridge envelope — un-skip when FASTORY-2552 starts');

    test('a malformed or wrong-version envelope never throws — decoder fails closed', () {
      // Intended contract: matches bridge-protocol-cases.json "ignore" cases for malformed
      // JSON, a higher/string `v`, a missing `v`, a non-string `type`, a non-object `payload`,
      // and a top-level array — every one of these must be silently ignored, never surfaced as
      // a thrown error or a crash across the platform channel boundary (SPEC §5.4's "MUST NOT
      // throw uncaught native exceptions" applies symmetrically to this Dart-side decoder).
      expect(true, isTrue);
    }, skip: 'v1: bridge envelope — un-skip when FASTORY-2552 starts');
  });
}
