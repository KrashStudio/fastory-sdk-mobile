// Dormant TDD scaffold for the `openMembership` surface (packages/sdk/docs/V1_PLAN.md). Every
// test is skipped and its body is a structured comment (intended call + behavior assertions)
// plus a trivial placeholder so the file compiles against TODAY's API.
//
// Deferred out of v1 (2026-07-27) along with paid subscriptions — FASTORY-2557 sits in the
// backlog with no planned start. This file stays so the reserved surface keeps a written intent,
// but it is tied to no active ticket: do not un-skip without a product decision reviving
// membership.
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('openMembership — section deep link (FASTORY-2557)', () {
    test('openMembership sends the method with a section argument', () {
      // Intended contract (V1_PLAN.md: `openMembership(section:)`):
      // - Fastory.openMembership(section: ...) invokes 'openMembership' with an argument map
      //   carrying the requested section, e.g. {'section': 'rewards'}; omitting it falls back
      //   to a default landing section.
      // - Deliberately NOT asserting any concrete section identifier or resulting URL/content
      //   shape here — membership surfaces are "not frozen by the strategy doc" (V1_PLAN.md)
      //   until the spec freezes them; this contract only asserts that the argument is sent.
      expect(true, isTrue);
    }, skip: 'deferred: openMembership — out of v1 scope, no active ticket (FASTORY-2557 backlog)');

    test('openMembership reuses the existing not_configured / already_open error codes', () {
      // Intended contract: no new error codes introduced for this surface — the native side
      // reuses `not_configured` and `already_open` (SPEC §5.2 table) for the membership
      // presentation, so the Dart bridge needs no membership-specific error mapping.
      expect(true, isTrue);
    }, skip: 'deferred: openMembership — out of v1 scope, no active ticket (FASTORY-2557 backlog)');
  });
}
