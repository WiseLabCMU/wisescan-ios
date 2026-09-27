# Insta360 SDK EULA: compliance review for Scan4D

**Status:** Review complete, 2026-09-27. Engineering review, not legal advice; the items under
*For counsel* need CMU's Office of General Counsel (and CTTEC where IP is granted) before the
SDK ships in a public build.
**Source:** [End User License Agreement for Insta360 SDK](https://www.insta360.com/support/supportcourse?post_id=20734),
as published 2026-09-27 (the page carries no version number or effective date; keep a saved copy
with the application records). Clause numbers below are the agreement's own.
**Scope:** the iOS Camera SDK (`INSCameraSDK`, `INSCameraServiceSDK`, `INSCoreMedia`,
`SSZipArchive` xcframeworks) obtained through the developer application, for the Insta360 X6
still-source integration (#99, #100, design doc `still-source-360.md`).

## Headline

Our intended use is within the grant. Section 3.1(b) expressly allows shipping the SDK inside an
app to a third-party app store, and our licensing (BSD-3-Clause) is not the copyleft case that
4.2 forbids. Three engineering conditions are mandatory before the SDK enters any build, and four
contract terms need counsel's sign-off because they bind the licensee to obligations a university
usually cannot accept without review.

## Our facts

| Fact | Value | Bears on |
| :--- | :--- | :--- |
| Repo | `WiseLabCMU/wisescan-ios`, **public**, BSD-3-Clause | 4.1(d)/(e), 4.2 |
| App | Scan4D, `edu.cmu.wiselab.wisescan-ios`; TestFlight now, App Store planned | 3.1(b), 9.4 |
| Other SDKs | Meta Wearables DAT (proprietary developer terms, via SPM). No GPL/LGPL anywhere | 4.2 |
| SDK delivery | Four closed xcframeworks; no license file in the public GitHub repo; EULA governs | 4.1(d) |
| Activation | `INSCameraActivateManager.setAppid(_:secret:)` with an App ID + secret issued to us; contacts Insta360 servers with the camera serial | 7.4, 16, secret hygiene |
| Privacy policy | `docs/PRIVACY.md` (linked from App Store Connect) states no third-party SDKs and no data sent to anyone | 7.4, 16 |
| Consent UX | none at first launch today (the privacy-filter toggle is unrelated) | 16 |
| Imagery | 360° stills capture bystanders; export-time person-privacy pass, fail-closed | 7.5(e), 13(b) |
| Brand use | README and listing name "Ricoh Theta" and "Meta Ray-Ban" factually; nothing Insta360 yet | 4.3, 9.3, 9.4 |

## Clause by clause

Verdict key: **OK** = compliant as we are; **Action** = engineering/doc change required (listed
under *Required controls*); **Counsel** = contract term for OGC/CTTEC.

| § | What it says | Our situation | Verdict |
| :--- | :--- | :--- | :--- |
| 1 "Application Software" | app "running in connection with and for use of Insta360 Products **solely**" | Scan4D is a multi-device scanner; Insta360 is one still source among Theta and the phone camera | **Counsel** (scope ambiguity; also ask Insta360, see *Questions*) |
| 3.1(a) | use the SDK only to design/develop the Application Software | that is our only use | OK |
| 3.1(b), 3.3 | may copy/distribute the SDK **as part of the app** and upload to app stores | TestFlight + App Store | OK |
| 3.2, 10.1 | Insta360 owns the SDK | no claim made | OK |
| 4.1(a)–(c), (f) | no reverse engineering, no modification, no imitating Insta360 software, keep notices | wrapping via the `StillSource` seam only; must carry SDK notices into the app's acknowledgements | **Action** (notices) |
| 4.1(d) | no distributing the SDK **stand-alone** | committing the xcframeworks to a public repo would be stand-alone distribution | **Action** (never in the repo) |
| 4.1(e) | no sublicense/transfer to third parties | passing our SDK download to collaborators is a transfer; each contributor must obtain it through their own application, or accept the EULA in their own name | **Action** (contributor rule) |
| 4.2 | no combining with copyleft that would reach the SDK; no GPL | BSD-3 is permissive; Meta DAT is proprietary; no GPL/LGPL deps | OK (re-check on every new dependency) |
| 4.3, 9.3, 9.4 | no Insta360 marks in marketing without written permission; no implied endorsement; "Insta360" not in the app name | "Scan4D" is fine. Naming Insta360 compatibility in the App Store listing or README is trademark use in marketing | **Action** (factual wording only; get written permission before the listing names Insta360) |
| 5, 6, 7.1, 11 | no warranty, no support, we maintain the app | accepted risk; nothing to do | OK |
| 7.2 | no misrepresenting Insta360 as the developer/provider; no security circumvention | n/a | OK |
| 7.4 | protect end-user privacy per law; adequate privacy notice | `PRIVACY.md` must be updated when the SDK lands | **Action** (privacy policy) |
| 7.5 | Insta360 may terminate at once if, in its sole discretion, the app or **pictures obtained through it** infringe privacy rights, etc. | the fail-closed person-privacy pass on stills is the mitigation; must cover Insta360 stills identically | **Action** (keep parity) |
| 8 | SDK may change or be withdrawn at any time without notice | the app must build and ship without the SDK | **Action** (feature flag / stub) |
| 9.1, 9.2 | Insta360 may promote the app and gets a royalty-free license to use **our Mark** | "our Mark" reaches the Scan4D name and any CMU/WiSE Lab marks in the app | **Counsel** (university trademark policy) |
| 10.2 | we own the app, but grant Insta360 a worldwide, royalty-free, non-exclusive, **sublicensable and transferable** right to use it | BSD-3 already grants everyone a broader right, so practical exposure is small, but it is an IP grant by the licensee | **Counsel** (CTTEC) |
| 10.3 | SDK bundles third-party software under its own terms | `SSZipArchive` (MIT) at least; include its notice | **Action** (notices) |
| 12 | liability capped at what we paid (zero) | accepted risk | OK |
| 13 | broad indemnification of Insta360, including for imagery obtained through the app | universities routinely cannot agree to open-ended indemnities | **Counsel** |
| 14 | either side may terminate with notice; on termination stop distributing the app and destroy SDK copies | reinforces the feature flag; App Store build must be re-shippable without the SDK | **Action** (feature flag) |
| 15.1, 15.6 | unilateral amendment by notice; fees may be introduced later | continued use = acceptance; watch the notice email address used on the application | **Counsel** (note only) |
| 15.3 | California law and venue outside the EU | | **Counsel** (note only) |
| 15.5 | not assignable without consent | the licensee identity matters: individual applicant vs CMU | **Counsel** |
| 15.7, 17, 18 | export control; government end-user clauses | no embargoed distribution; federally funded research is not itself a government delivery | OK |
| 16 | Insta360 may collect SDK usage statistics **with prior consent**; partners must name the SDK in their privacy policy and product page, and prompt the user to read it and obtain consent **before initializing the SDK**, on first launch | no such prompt exists; `PRIVACY.md` says the opposite of what will be true | **Action** (consent gate + policy) |

## Required controls (engineering), in order

1. **The SDK never enters the repo.** `.gitignore` now excludes the four xcframeworks, an
   `Insta360SDK/` drop folder, and any `*.secrets.xcconfig` (this PR). The privacy guard should
   additionally refuse a path matching `INSCamera*.xcframework` and any literal
   `setAppid("…", secret: "…")` that is not a placeholder (follow-up in the integration PR).
2. **The app builds and ships without the SDK.** Gate the integration behind a compile-time
   flag (e.g. `INSTA360_SDK`) with a stub `StillSource` when absent, so the public repo, CI's
   compile job, and contributors without SDK access all build, and a §8/§14 withdrawal is a
   flag flip, not a rewrite.
3. **Secret hygiene.** The App ID and secret are injected from an untracked xcconfig or the
   build environment, never from source; TestFlight builds get them from the release machine.
4. **Consent before init (§16).** First-launch (or first-use-of-Insta360) prompt that names the
   Insta360 SDK, links the privacy policy, and blocks `INSCameraActivateManager` and any
   SDK initialization until the user accepts. Persist the decision; re-prompt on policy change.
5. **Privacy policy and listing (§7.4, §16).** In the integration PR, update `docs/PRIVACY.md`:
   replace "does not integrate any third-party SDKs" with a section naming the Insta360 Camera
   SDK as a partner component, what it transmits (camera activation with serial number to
   Insta360 servers; any usage statistics, per Insta360's answer to Q4 below), and that it runs
   only after consent. Mirror the disclosure on the App Store product page.
6. **Notices (§4.1(f), §10.3).** Add the SDK's proprietary notice and `SSZipArchive`'s MIT
   notice to the in-app acknowledgements and `README` third-party section.
7. **Trademark wording (§4.3, §9.3).** Compatibility statements only ("works with Insta360 X6
   cameras"), no logos, and written permission from Insta360 before the App Store listing or
   marketing names them. The app name stays "Scan4D" (§9.4).
8. **Contributor rule (§4.1(e)).** `CONTRIBUTING.md`: the SDK is obtained per person via
   Insta360's application; it is never shared through the repo, chat, or a shared drive.
9. **Privacy-pass parity (§7.5(e), §13(b)).** Insta360 stills go through the same fail-closed
   person-privacy pass as Theta stills; no export path bypasses it.

## For counsel

1. **Licensee identity.** Who accepted: the individual applicant or CMU? §15.5 makes it
   non-assignable, and §13/§10.2/§9.2 read very differently for a person than for the university.
2. **§13 indemnification**, open-ended and including third-party claims over imagery.
3. **§10.2 grant** of a sublicensable, transferable right in the app to Insta360, and **§9.2**
   license to "our Mark" (Scan4D and any CMU marks displayed in the app).
4. **§1 "solely"**: whether a multi-camera app is an "Application Software" at all. Low risk in
   practice (Insta360 approved an application that described the app), but the definition
   should be confirmed in writing (Question 1).

## Questions to put to Insta360 (developer contact used for the application)

1. Confirm that a multi-device scanning app in which Insta360 cameras are one supported source
   qualifies as "Application Software" under §1.
2. Which SDK version we were issued, and whether it supports the **X6** (the public README for
   V1.9.2, 2025-11, lists X5 as the newest supported model).
3. Written permission under §4.3(a) to state X6 compatibility in the App Store listing and README.
4. What the SDK transmits: activation payload, any usage statistics (§16), endpoints, and whether
   telemetry can be disabled, so the privacy policy can be accurate.

## Not in scope

The Meta Wearables Developer Terms and Ricoh's `theta-client` (open source) were not reviewed
here beyond confirming neither is copyleft; each deserves the same table before the App Store
release.
