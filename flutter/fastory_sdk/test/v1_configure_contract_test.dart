// Dormant TDD scaffold for the v1 `configure` surface (docs/sdk/V1_PLAN.md). Every test is
// skipped and its body is a structured comment (intended call + behavior assertions) plus a
// trivial placeholder so the file compiles against TODAY's API — no forward references to
// not-yet-written classes/methods. Un-skip and fill in real assertions as each ticket starts.
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('configure v2 — publishable key init (FASTORY-2551)', () {
    test('configure sends key, workspaceId and env instead of a slug', () {
      // Intended contract (V1_PLAN.md §"The frozen v1 surface"):
      // - configure(key, workspaceId, env, theme) replaces slug-only config: the SDK is
      //   initialized by a publishable key scoped to a workspace, not a fanzoneSlug.
      // - The 'configure' channel argument map carries {'key': ..., 'workspaceId': ...,
      //   'env': ..., 'theme': ...}, replacing the v0.1 {'fanzoneSlug': ...} shape for v2
      //   callers.
      // - No behavior change to openGames()/close()/events — only configure()'s argument
      //   shape and client-side validation move.
      expect(true, isTrue);
    }, skip: 'v1: configure v2 — un-skip when FASTORY-2551 starts');

    test('legacy slug-based configure keeps working during the deprecation window', () {
      // Intended contract:
      // - v0.1's FastoryConfig(fanzoneSlug: ...) call shape MUST still be accepted and still
      //   resolve to a working configure() call after v2 ships ("v0.1 config stays accepted
      //   through a deprecation window" — V1_PLAN.md). Existing integrators upgrading the SDK
      //   version without touching their call site must not break.
      // - Only once the deprecation window closes (a later, separately-tracked change) does
      //   the slug-only shape stop being accepted.
      expect(true, isTrue);
    }, skip: 'v1: configure v2 — un-skip when FASTORY-2551 starts');
  });

  group('theming — CSS tokens via configure (FASTORY-2555)', () {
    test('configure sends theme CSS tokens when provided, and a stable default otherwise', () {
      // Intended contract:
      // - configure() gains an optional `theme` argument carrying CSS design tokens ("CSS
      //   tokens end-to-end" — V1_PLAN.md); the exact token set is owned by FASTORY-2555 and
      //   is NOT asserted here.
      // - Omitting theme must not regress the call shape: the channel map keeps sending a
      //   `theme` key (null) so native sides on either version parse it safely, mirroring how
      //   every optional FastoryConfig field is always present in the map today.
      expect(true, isTrue);
    }, skip: 'v1: theming — un-skip when FASTORY-2555 starts');
  });
}
