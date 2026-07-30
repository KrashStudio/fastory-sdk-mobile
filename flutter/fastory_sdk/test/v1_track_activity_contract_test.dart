// Dormant TDD scaffold for the v1 `trackActivity` surface (docs/sdk/V1_PLAN.md). Every test is
// skipped and its body is a structured comment (intended call + behavior assertions) plus a
// trivial placeholder so the file compiles against TODAY's API. Un-skip and fill in real
// assertions when FASTORY-2558 starts (backend counterpart: FASTORY-2549).
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('trackActivity — offline queue + idempotent crediting (FASTORY-2558)', () {
    test('trackActivity sends a type and metadata through a dedicated channel method', () {
      // Intended contract (V1_PLAN.md: `trackActivity(type, metadata)`):
      // - Fastory.trackActivity(type: 'game_completed', metadata: {'score': 42}) invokes the
      //   'trackActivity' method with argument map
      //     {'type': 'game_completed', 'metadata': {'score': 42}}.
      // - Transport to the Activity API is server-signed (HMAC, FASTORY-2549) and never goes
      //   through the webview — a native-side transport concern, not asserted from Dart.
      expect(true, isTrue);
    }, skip: 'v1: trackActivity — un-skip when FASTORY-2558 starts');

    test(
        'activity events queue while offline and flush once connectivity returns, bounded and '
        'deduplicated', () {
      // Intended contract:
      // - trackActivity() must not fail/throw when the device is offline: it enqueues locally
      //   (a bounded queue — exact cap owned by FASTORY-2549/2558) and flushes once
      //   connectivity returns.
      // - Retried/duplicate activity events are deduplicated server-side via an idempotency
      //   key, so a flaky-network retry of the same event never double-credits the activity.
      expect(true, isTrue);
    }, skip: 'v1: trackActivity — un-skip when FASTORY-2558 starts');

    test('trackActivity before configure surfaces not_configured', () {
      // Intended contract: same not_configured error contract as every other method that
      // requires prior configure() (SPEC §5.4) — no bespoke silent-drop behavior.
      expect(true, isTrue);
    }, skip: 'v1: trackActivity — un-skip when FASTORY-2558 starts');
  });
}
