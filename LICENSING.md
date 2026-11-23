# Licensing

## The short version
- **L1ne's own source code is MIT licensed** (see [LICENSE](LICENSE)). Use, change and share it freely.
- **A built copy of L1ne is not MIT.** It links **PJSIP** (pjproject), which is licensed **GPL-2.0-or-later** by Teluu Inc., so the finished app is a
  combined work that must be distributed under the GPL. MIT is compatible with that, which is why the two can sit together.
- **Using your own build costs you nothing and requires nothing.** The GPL obligations begin when someone *distributes* a build to other people.

## What distributing a build means
If you give a built L1ne (an `.ipa`, an `.apk`, a TestFlight build, a download) to anyone else, you must:
1. Offer them the **complete corresponding source** for that build: L1ne's source, the pjproject source it was built from, **and the patch in `scripts/patches/`**.
2. License the combined work under the GPL (version 3 in practice, see the OpenSSL note below) and include the license texts.
3. Keep the notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

This repository stays MIT because it contains **no PJSIP source**: `scripts/fetch-deps.sh` downloads PJSIP and OpenSSL at build time.
The one exception is `scripts/patches/pjsip-tls-wildcard.patch`, a change to a PJSIP file. It is a modification of GPL code and is covered by
PJSIP's license (GPL-2.0-or-later), not by the MIT license.

## The App Store and TestFlight
Apple's App Store and TestFlight terms add restrictions on what recipients may do with an app, and the GPL does not allow additional restrictions.
This is a long-standing conflict, so **do not publish a GPL-covered build to the App Store or TestFlight unless PJSIP is licensed to you
commercially.** Teluu sells a commercial license for PJSIP (see https://docs.pjsip.org/en/latest/overview/license.html). Another way out is to
replace PJSIP with a permissively licensed SIP stack, which would be a large piece of work.

Android builds distributed outside Google Play only need the GPL steps above. Play Store policy is less restrictive than Apple's, but check it
before publishing.

## OpenSSL and the GPL version
PJSIP is "GPL version 2 **or later**". OpenSSL 3.x is Apache-2.0, which is compatible with GPL **version 3** but not with version 2 alone. So a build
that includes both is distributed under GPL-3.0-or-later terms.

## This is not legal advice
It describes how these licenses are generally understood. If you plan to distribute builds beyond friends and family, ask a lawyer or contact Teluu.
