// Dormant TDD scaffold for the v1 `openEmbedBlock` surface (docs/sdk/V1_PLAN.md). Every test
// is skipped and its body is a structured comment (intended call + behavior assertions) plus a
// trivial placeholder so the file compiles against TODAY's API. Un-skip and fill in real
// assertions when FASTORY-2554 starts.
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('openEmbedBlock — in-feed gamified block (FASTORY-2554)', () {
    test('openEmbedBlock sends the method call with a blockId argument', () {
      // Intended contract (V1_PLAN.md: `openEmbedBlock(blockId)`):
      // - Fastory.openEmbedBlock('block-slug') invokes 'openEmbedBlock' with argument map
      //   {'blockId': 'block-slug'}.
      // - Deliberately NOT asserting any resulting URL/content shape here — embed surfaces are
      //   "not frozen by the strategy doc" (V1_PLAN.md) until the spec freezes them.
      expect(true, isTrue);
    }, skip: 'v1: openEmbedBlock — un-skip when FASTORY-2554 starts');

    test('openEmbedBlock rejects a blank blockId before touching the channel', () {
      // Intended contract: mirrors the blank-slug / blank-hubTabSlug guards already in
      // configure() today — throws ArgumentError synchronously, zero MethodCalls recorded.
      expect(true, isTrue);
    }, skip: 'v1: openEmbedBlock — un-skip when FASTORY-2554 starts');
  });
}
