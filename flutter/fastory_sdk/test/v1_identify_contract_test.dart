// Dormant TDD scaffold for the v1 `identify` surface (docs/sdk/V1_PLAN.md). Every test is
// skipped and its body is a structured comment (intended call + behavior assertions) plus a
// trivial placeholder so the file compiles against TODAY's API — no forward references to
// not-yet-written classes/methods. Un-skip and fill in real assertions when FASTORY-2553 starts.
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('identify — three binding modes + SSO (FASTORY-2553)', () {
    test(
        'each identify mode sends a distinct, discriminated argument map; hostToken drives '
        'native SSO', () {
      // Intended contract (V1_PLAN.md: `identify(anonymous | fanId | hostToken(jwt))`):
      // - Fastory.identify(...) accepts exactly one of three mutually-exclusive modes:
      //   anonymous, fanId(String), hostToken(jwt: String). The Dart API shape should make
      //   constructing more than one impossible (sealed class / factory constructors), not
      //   just a runtime check.
      // - Each mode invokes the 'identify' method with a discriminated argument map, e.g.
      //   {'mode': 'anonymous'} / {'mode': 'fanId', 'fanId': '...'} /
      //   {'mode': 'hostToken', 'jwt': '...'}.
      // - hostToken(jwt:) additionally drives a native SSO flow (ASWebAuthenticationSession on
      //   iOS, Custom Tabs on Android) before completing; the returned Future must not resolve
      //   until that flow completes, and should reject with a dedicated error code (e.g.
      //   `sso_cancelled`) if the user cancels it — not a generic PlatformException.
      expect(true, isTrue);
    }, skip: 'v1: identify — un-skip when FASTORY-2553 starts');

    test('identify before configure surfaces not_configured', () {
      // Intended contract: identical error contract to openGames() (SPEC §5.4) — calling
      // identify() before configure() surfaces PlatformException(code: 'not_configured')
      // unchanged, not a new/different code.
      expect(true, isTrue);
    }, skip: 'v1: identify — un-skip when FASTORY-2553 starts');
  });
}
