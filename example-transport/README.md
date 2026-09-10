# Caller-owned CloudKit transport device lab

This is a dedicated native Expo application, not the legacy example, an application sync engine, or a CloudKit mock. Every cloud operation is button-triggered. It imports only `expo-cloudkit/transport`; no provider, hooks from the library, CKSyncEngine, push notifications, SQLite, retry scheduler, or app domain data are involved.

## Versions and prerequisites

Read against the exact [Expo SDK 57 reference](https://docs.expo.dev/versions/v57.0.0/) and [SDK 57 FileSystem API](https://docs.expo.dev/versions/v57.0.0/sdk/filesystem/). Expo documents Node 22.13+, iOS 16.4+, and Xcode 26.4+ for this SDK. The library itself declares iOS 16.0; the Expo application has the stricter SDK minimum.

The committed example pins Expo **57.0.12**, React Native **0.86.2**, and React **19.2.3**. Native dependencies were installed using `npx expo install`. The initial `~57.0.12` install resolved Expo 57.0.21 and recommended RN 0.86.3; Expo was subsequently pinned to the requested 57.0.12 baseline, whose bundled dependency table recommends RN 0.86.2. The lock currently resolves compatible patch updates: expo-modules-core 57.0.17, expo-constants 57.0.17, expo-file-system 57.0.6, expo-dev-client 57.0.18, and @expo/config-plugins 57.0.9. `npm ci` preserves the exact resolution; reinstalling without the lock may select newer patches.

A signed physical iPhone, an iCloud account, an Apple Developer team, and a provisioned **disposable verification app/container** are required for real CloudKit gates. Expo Go cannot load this module. Ad-hoc-signed simulator CI checks do not prove real account, conflict, asset, or CloudKit server semantics. Do not use a production/user dataset.

## Reproducible source and packed installation

From the repository root:

```sh
npm ci
npm run build
npm test -- --runInBand src/__tests__/transport.test.ts src/__tests__/transport-plugin.test.ts
npm pack
```

`npm pack` invokes `prepack`, which builds JS, declarations, and the config plugin. The archive is `expo-cloudkit-0.21.0-fork.0.tgz`. Its allowlist includes compiled `build/`, `transport.js`, `transport.d.ts`, Swift/Objective-C native sources, the podspec, Expo module metadata, and `app.plugin.js`. No exports map was added, so legacy subpath resolution remains available.

In `example-transport`:

```sh
npm ci
npm install --no-save --package-lock=false --ignore-scripts ../expo-cloudkit-0.21.0-fork.0.tgz
npm run typecheck
```

The checked-in dependency is `file:..` for source development. The explicit tarball command replaces that local link for the package acceptance gate without rewriting the source-development manifest or lock. Do not run `npm ci` after that replacement until you intend to restore source development. Confirm `node_modules/expo-cloudkit` is the unpacked package, not a source link, and inspect its package version and compiled files.

For an intentionally managed source submodule in another application's workspace, first run `npm ci && npm run build` inside the submodule, then install `file:../vendor/expo-cloudkit` (adjust to the app's actual relative path), and regenerate/reinstall native pods in that app. Do not depend on an implicit Git lifecycle build. This repository does not add a submodule. For distribution, prefer the exact versioned tarball.

The example explicitly enables Expo's autolinking module resolver and includes `react` in singleton resolution. Keep those settings when consuming a source checkout with its own development dependencies: a `file:` link is not automatically a workspace, and otherwise Metro can bundle duplicate React/React Native/Expo runtimes. See the configuration in `app.config.js` and `expo.autolinking` in `package.json`.

## Configuration, autolinking, and native build

Set these environment variables in the shell used for **both prebuild and Metro**:

```sh
export CLOUDKIT_CONTAINER_ID=iCloud.your.provisioned.disposable.container
export CLOUDKIT_BUNDLE_ID=your.provisioned.verification.bundle
export CLOUDKIT_ENVIRONMENT=Development
```

PowerShell equivalents are `$env:CLOUDKIT_CONTAINER_ID = '...'`, `$env:CLOUDKIT_BUNDLE_ID = '...'`, and `$env:CLOUDKIT_ENVIRONMENT = 'Development'`.

The app config deliberately rejects missing identifiers. Nothing defaults to the application's real CloudKit container. `CLOUDKIT_ENVIRONMENT` accepts `Development` or `Production`; changing environment/container requires rebuilding and reprovisioning the binary. Development is appropriate for the disposable lab. The plugin opts out of remote-notification background mode and preserves other app capabilities.

On macOS, from this directory after packed installation:

```sh
npx expo-modules-autolinking resolve --platform apple
npx expo config --type introspect
npx expo prebuild --platform ios --no-install
npx pod-install
npx expo run:ios --device
```

Inspect autolinking output for the `ExpoCloudKit` pod and both native module registrations, including `ExpoCloudKitTransport`. Inspect the generated entitlements for the supplied container, CloudKit service and requested environment. Info.plist should not gain `UIBackgroundModes` for this manual integration. Xcode's generated target is expected to be `CloudKitTransportVerification`; use the generated project as the authority. Configure your signing team and iCloud capability in Xcode if automatic provisioning needs assistance.

For subsequent JS work with that installed development binary:

```sh
npm start
```

No EAS/paid builds or publication are needed. `EXPO_PUBLIC_CI_SMOKE=1` replaces the lab UI with a native-loading smoke screen: it requires the native module, creates a session, submits an empty targeted fetch (native validation before any account/network call), checks `invalidArguments` plus generation `ci-smoke`, and disposes twice. It also exercises the real native file-digest API against known bytes and equal-length changed bytes, deleting its temporary probe afterward. Only then does it expose `transport-native-loaded` as an accessibility label/test ID. A missing or incompatible module displays `transport-native-failed: ...`. This proves module/bridge/session/validation and local file-digest loading, not CloudKit operations. Unset the variable and rebuild/rebundle for real device verification.

## Device procedure and expected observations

Receipts are selectable in the app and also printed to Metro. Keep full per-record outcomes, generation, correlation IDs, native error domain/code, retry-after and `commitState` as evidence. Network/account failures are results, not instructions to automatically retry.

1. **Isolated zone and account.** Probe the current account, then open a session. Opening explicitly persists the first account binding; later probes never silently replace it. The generated `TransportVerification-...` zone is unique and not created yet. Check zone and expect a typed missing-zone outcome. Explicitly create the displayed zone, then check it again. Copy that displayed name to a second device's zone input and press **Use shared disposable zone** to verify against the same private-account dataset. This resets only the local lab notebook. Both clients must use the same iCloud account/container/environment.
2. **Create, fetch, and missing identity.** Create the stable record with an upload. Repeat creation and require conflict rather than overwrite. Fetch metadata plus a generated missing ID. Require one `found` and one `notFound`; the missing lookup is not a deletion tombstone. Check that metadata fetching does not download attachment bytes.
3. **Two conditional writers.** Fetch metadata, capture clients A/B at the observed version, save A, then save B. B must return conflict and usable server system fields; fetch again to establish A was not overwritten. For two real devices, fetch/capture on both before either saves, then save A on device one and B on device two. The example never merges or resubmits automatically.
4. **Restart reconstruction and omitted asset.** With an existing attachment, fetch metadata only, enter a new title, prepare the metadata-only draft, and force-quit. Relaunch, probe/open, and submit the persisted draft **without fetching again or downloading the asset**. The notebook contains serialized system fields plus the explicit set/clear mask. Verify the title changed and a later targeted asset download still has the original bytes and assetLabel. A conflict is legitimate if another client wrote during the restart; do not silently refresh the draft.
5. **Explicit replacement/removal.** Fetch current metadata before each edit. Replace the asset and assetLabel together, download to compare owner/changeTag and bytes. Explicitly clear attachment and inspect the saved record, then download assets and require an empty `assets` array for the absent field on that returned record version. Upload sources must still exist. Restore an attachment before later asset scenarios.
6. **Pagination, replay, restart.** Create several mixed-batch records. Set page limit to 1 and fetch from the persisted checkpoint. Fetch again **without committing** to exercise replay. Commit the displayed page and next token together only when `checkpointUsable` is true. Force-quit, relaunch/probe/open, and fetch from the restored token. Repeat while `moreComing` is true. A failed/partial page must not offer a usable next checkpoint; retain and replay the previous token. Initial scan deliberately does not clear/advance the saved checkpoint. Actual record-deletion notifications can be exercised by deleting only a disposable lab record in CloudKit Dashboard, then fetching changes; no cloud delete control is provided in this app.
7. **Partial acknowledgements.** Capture A/B, save A, then submit the mixed batch (fresh ID plus stale B). Require the new-record acknowledgement and conflict to remain separately visible. If cancelled or interrupted, inspect every item and `commitState`, then reconcile stable IDs explicitly instead of assuming nothing committed.
8. **Durable asset lease.** Download and persist the returned owner/version/URI/byte count. Force-quit/relaunch and use **Verify persisted downloads and uploads by content digest**. Require the downloaded MD5 and byte count to match the per-upload expectation identified by `assetLabel`; cross-device reads compare the digest saved with the asset on the same record. The notebook retains all generated upload URIs/digests and their first saved owner version, not only the latest file. Same-length stale/corrupted bytes must fail. MD5 here is a lab integrity check, not a security primitive or the application's domain checksum policy. Native staging remains caller-owned and every retained upload must remain readable and unchanged.
9. **Cancellation and late acknowledgement.** Immediate cancellation exercises pre-submission cancellation. For in-flight writes use a persisted draft with a delay, vary delay, inspect `commitState`, and refetch the stable ID. For copy timing use 1–32 MiB assets and delayed download cancellation; repeat at several delays while observing native logs/staging and storage. Toggle **Hold application acknowledgements**, finish a request, dispose twice, then release held acknowledgements: receipts stay visible but the example's generation fence must reject stale application updates. This intentionally delays only application receipt processing, not native bridge delivery. Native callback-boundary and exact mid-copy cancellation require native instrumentation/device timing; UI timing alone does not prove those boundaries.
10. **Account changes and teardown.** Keep a session open, change/sign out of the iCloud account in device Settings, return, and inspect invalidation. Repeated teardown must be safe; stale receipts must not update the notebook. Probe/open while retaining the old binding to observe mismatch. To explicitly start a new account-bound lab dataset, select a newly generated disposable zone (local notebook reset), then probe/open. Never silently reuse an old dataset under a new identity.
11. **Missing previously created zone.** In CloudKit Dashboard remove only the exact disposable `TransportVerification-...` zone you created, then check/fetch it. Require typed missing/deleted zone behavior, not recreation. Creation remains a separate explicit button. Token expiry, permission/quota/service/account-temporarily-unavailable errors require an appropriately configured device/service state; record the actual error rather than treating an unavailable gate as passed.

## Local ownership and cleanup

The app-owned Documents/transport-verification directory holds immutable JSON notebook snapshots, persisted masks/system fields/checkpoints, and generated upload sources. A snapshot uses a unique partial file then moves to a complete JSON file; restore ignores partials. This is a small manual verification journal, not a transactional application inbox/outbox. Production applications should commit their own domain page and checkpoint in their own transaction.

Downloads are in the native transport's durable staging directory; notebook entries associate each URI with the exact record owner/version and byte count. Successful downloads, including receipts deliberately withheld by the lab, become caller-owned. Retain logs/URIs when testing abandoned acknowledgements and clean up only those recorded/generated files. Never delete arbitrary paths returned by another source. Export evidence first, then remove this disposable app to clean its sandbox, and remove only the exact disposable zone(s) in CloudKit Dashboard. Do not delete existing user zones or data. Old snapshot files intentionally remain for inspection; the lab never opens or edits an application's SQLite database.

## Evidence boundaries

Dependency installation, exact installed-version inspection, tarball/source autolinking, and Hermes bundling were exercised on Windows. Source bundling uses a single React/React Native/Expo Modules Core runtime after explicit Expo resolver configuration. Native compilation and simulator UI are exercised by GitHub macOS CI; consult its actual run conclusion. Real iCloud account transitions, conflicts, asset preservation, restart durability, and callback/copy cancellation still require the signed-device procedure. TypeScript tests and the ad-hoc-signed simulator smoke do not establish those server semantics or production readiness.

[GitHub run 34455535763 passed](https://github.com/ivanjx/expo-cloudkit/actions/runs/34455535763) for implementation commit `9e43831`: 281 JS tests, 145 native XCTest cases, and both tarball/source-linked Release-app UI smokes on Xcode26.4.1 and iPhone17 / iOS26.4.1 simulator. The native file-digest smoke passed as well. This completes the automated compilation, loading and distribution portions of the procedure, not the signed-account/server observations.
