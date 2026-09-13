# Caller-owned CloudKit transport

This fork (`0.21.0-fork.0`) supplies native transport capabilities, not an application synchronization engine. Import **`expo-cloudkit/transport`**, not the legacy `configure`/sync/queue APIs. The standalone entry is lazy; importing it does not acquire a native module, subscribe to account events, or start any service.

**SQLite remains application-authoritative.** The library never opens it. Domain mapping, validation, revisions, tombstones, conflict decisions, retries, durable inbox/outbox, acknowledgement transactions, file leases and lifecycle scheduling remain application-owned. No CKSyncEngine, polling, network monitor, push subscription, automatic zone recreation, conflict merge, offline journal or checkpoint persistence is activated by the transport.

The runtime contract is iOS/private database/custom zones. Container and zone names are caller configuration; no application identifier is built into the library. Expo Go, web and Android cannot perform these native operations. The SDK reports `nativeModuleUnavailable` or `unsupportedPlatform` rather than pretending to synchronize.

## API overview

All types are exported by the standalone entry and the main barrel. `TransportResult<T>` is a tagged envelope:

```ts
type TransportResult<T> =
  | { status: 'success'; generation: string; operationId: string; value: T }
  | { status: 'failed'; generation: string; operationId: string; error: TransportError };
```

**A successful envelope is not an all-items-succeeded acknowledgement.** Inspect each outcome, `operationError`, and page `checkpointUsable`. Ordinary native CloudKit errors resolve as data; they do not throw away a partially successful batch. Synchronous native invocation errors use Expo `Exception` subclasses and become typed SDK results.

| Public API | Return / behavior |
| --- | --- |
| `getTransportAccount(containerId, generation)` | Promise of account availability and optional opaque identity; result `operationId` is empty. No session configuration needed. |
| `createTransportSession({containerId, database: 'private', expectedAccountIdentity, generation})` | Synchronous session handle; no network request. Invalid creation is retained as structured failure on operations. |
| `session.fetchZone(zone)` | Operation returning `{status:'found', zone}` or typed missing/deleted/error result. Never creates. |
| `session.createZone(zone)` | Explicit operation returning `{status:'created', zone}`; cancellation can leave creation uncertain. |
| `session.fetchChanges({zone, previousToken?, desiredKeys, resultsLimit?})` | One zone change page. `resultsLimit` is 1–200, default 200; no internal pagination loop. |
| `session.fetchRecords({records, desiredKeys})` | 1–200 unique IDs; each is `found`, `notFound`, or `failed`. |
| `session.saveRecords({records})` | 1–200 writes; `saved`, `conflict`, `failed`, or `unattempted` per input, with correlation IDs. |
| `session.downloadAssets({record, assetFields, desiredKeys})` | Exact owner/version record plus durable `{field,uri,byteCount}` assets from that fetch. |
| `session.addAccountChangeListener(listener)` | Removable subscription, filtered by originating native session and generation. |
| `session.dispose()` | Idempotently cancels work, removes observers/listeners, and releases bookkeeping; no server rollback. |

Every session operation returns `{id, result, cancel()}`. IDs are session-local and reserved synchronously in native code before the handle is returned. Native execution is deferred by a JS microtask, so immediate cancellation is a real pre-submission boundary. At most 200 operations may be outstanding per session. There is no automatic chunking or retry.

Record identity is `{recordName,zoneName,ownerName}`; zone identity is `{zoneName,ownerName}`. Use exported `TRANSPORT_DEFAULT_OWNER` for the current user's private zones. Do not use the default CloudKit zone or omit ownership. Record names are opaque IDs, not unescaped UI text.

## Session and account lifecycle

```ts
import {
  getTransportAccount, createTransportSession, TRANSPORT_DEFAULT_OWNER,
} from 'expo-cloudkit/transport';

const containerId = 'iCloud.com.example.notes';
const generation = 'foreground-42'; // Caller-owned epoch; new value each lifecycle.
const account = await getTransportAccount(containerId, generation);
if (account.status === 'failed') {
  // Record diagnostics; local SQLite workflows continue.
} else if (account.value.availability === 'available' && account.value.identity) {
  // Compare with the application's persisted account binding BEFORE adoption.
  // First binding is an explicit application decision, not an automatic reset.
  const session = createTransportSession({
    containerId, database: 'private',
    expectedAccountIdentity: account.value.identity, generation,
  });
  const subscription = session.addAccountChangeListener(event => {
    // Pause this binding. Native already invalidated/cancelled this session.
    // Reject stale app updates using event.generation; do not migrate datasets.
  });
  const zone = { zoneName: 'Notes', ownerName: TRANSPORT_DEFAULT_OWNER };
  const check = await session.fetchZone(zone).result;
  // Only explicitly authorized first-use setup may call session.createZone(zone).
  subscription.remove();
  session.dispose();
}
```

Availability is `available`, `noAccount`, `restricted`, `couldNotDetermine`, or `temporarilyUnavailable`. The identity is a SHA-256 digest of length-prefixed container ID and current user record ID. It is container-scoped and opaque, not a credential and not Sign in with Apple. Account identity is fetched using a cancellable current-user record operation with no user fields; that identity lookup uses CloudKit's public database. Requested transport data operations use the private database only.

Before each data operation, native checks account availability and current identity against the expected binding. An account notification invalidates the session, removes its observer and cancels pending work; identity mismatch does the same. Notifications carry the original generation. A new session is required; probing a new identity never changes an existing session's binding. CloudKit's noncancellable `accountStatus` callback is fenced after cancellation/teardown; the subsequent identity/data operations have real cancellable CKOperation handles. Account probes are not individually cancellable JS operation handles and are released on completion or module destruction.

Checking identity cannot make server submission and an account switch atomic. A request accepted by CloudKit may commit even if cancellation or account invalidation happens before JS acknowledgement. Fence stale application state, retain any returned receipts, and reconcile uncertain writes by stable IDs. Never reinterpret cancellation as rollback.

## Caller-owned changes and checkpoints

`fetchChanges` uses `CKFetchRecordZoneChangesOperation` with `fetchAllChanges=false`. `desiredKeys` is required; `[]` requests system metadata only. Include only application metadata keys to avoid downloading assets. Ordinary reads never fabricate tombstones: a missing targeted lookup is `notFound`; actual deletion identities arrive in the changes API. Application deletion tombstones are ordinary application records.

A page contains:

- `records`: changed records with complete identity, selected fields, system fields and optional change tag/timestamps.
- `deletions`: complete record/zone identity and record type.
- `nextToken`, `moreComing`: the next checkpoint and continuation indicator.
- `failures`: visible per-record failures, and optional `operationError`.
- `checkpointUsable`: the only permission to advance the checkpoint.

**Any per-record/zone/operation failure makes the checkpoint unusable and omits `nextToken`.** Successfully decoded records/deletions remain visible, but callers replay from their previous durable token. Never persist a token from an incomplete page. A partial page may have a `success` envelope plus `operationError`; checking the envelope alone loses this invariant.

```ts
const page = await session.fetchChanges({
  zone, previousToken: persistedToken, desiredKeys: ['title', 'revision'], resultsLimit: 100,
}).result;
if (page.generation !== currentGeneration) {
  // Do not apply to the active account/domain projection.
} else if (page.status === 'success' && page.value.checkpointUsable) {
  // In ONE application-owned SQLite transaction:
  // idempotently apply page.value.records and page.value.deletions;
  // save page.value.nextToken with this account/container/database/zone binding.
}
```

The token is a secure CloudKit archive inside a versioned, base64 JSON scope envelope. It survives JSON serialization/restart, is never persisted internally, and is checked against container/account/database/zone. Ephemeral generation is intentionally excluded from its durable scope so a new session for the same binding can resume. Malformed/base64-invalid/foreign-scope tokens produce `invalidToken`; service expiry produces `tokenExpired`. Tokens/system fields are not encrypted secrets or a tamper-proof authorization mechanism. Keep them opaque. Changing the desired field projection may require an application-decided rescan.

## Conditional writes and explicit masks

```ts
const write = {
  recordName: observed.recordName,
  zoneName: observed.zoneName,
  ownerName: observed.ownerName,
  recordType: observed.recordType,
  systemFields: observed.systemFields,
  set: { title: { type: 'string' as const, value: 'Updated title' } },
  clear: ['obsoleteField'],
  correlationId: 'durable-outbox-row-123',
};
// Persist the whole write (system fields AND mask), not a JS/native record object.
const restored = JSON.parse(JSON.stringify(write));
const receipt = await session.saveRecords({ records: [restored] }).result;
```

Writes reconstruct `CKRecord` from `encodeSystemFields` metadata, validate identity/type/scope, then reapply explicit set and clear assignments. System metadata alone does not preserve user fields or dirty keys. New records omit system fields and use caller-supplied stable IDs. Every save uses **`.ifServerRecordUnchanged`**, never `.changedKeys` or `.allKeys`; `isAtomic=false` preserves independent successes. There is no merge or conflict retry.

| Mask | Intended server operation |
| --- | --- |
| Field absent from both masks | Preserve server value, including an asset with no local file. |
| `set[key]` | Assign the explicit typed value. |
| `clear` contains key | Assign nil/remove the field, including assets. |
| Key in both masks | Reject that input as `unattempted / invalidArguments`. |

Conflicts include the server record/system fields when CloudKit provides them. If conversion fails, `serverRecordError` retains diagnostics; perform a targeted recovery fetch rather than guessing. Invalid/duplicate-ID writes are individually unattempted while valid siblings remain eligible. Duplicate correlation IDs are caller-controlled, but unique correlation IDs are recommended for durable receipt matching. Submitted writes lacking a definitive receipt remain `failed` with `commitState:'unknown'`.

Field values use the repository's actual tagged format: string, finite number, ISO8601 date string, base64 data, location, complete reference plus `none|deleteSelf`, and corresponding supported lists. Record `creationDate`/`modificationDate` are numeric Unix milliseconds. Asset input is `{type:'asset',value:'file:///stable/path'}`; metadata and asset are set together on the same write. Asset-list uploads are not exposed. Unsupported server field types become visible failures rather than silently omitted records/checkpoints.

**Server semantics gate:** Apple's documentation establishes change-tag conflict checks and the loss of dirty keys during system-field serialization. It is not a substitute for exercising partial-record/asset preservation against CloudKit. Run the signed two-writer and undownloaded-asset scenarios below before relying on these intended server semantics.

## Errors and partial acknowledgements

`TransportError` contains stable `code`, diagnostic `message`, native `nativeDomain`/`nativeCode`, optional `retryAfterSeconds`, and `commitState:'notCommitted'|'unknown'`. Never parse localized messages. Retry duration is advice; scheduling is caller-owned. Batch results preserve successful receipts even if the aggregate CloudKit operation fails.

Codes cover network/service availability, authentication and temporary account availability, account mismatch, permissions, quota, rate limiting/zone busy, missing/deleted zones, token expiry, conflict, invalid input/records/archives, missing/oversized upload assets, batch limits, file I/O/disk exhaustion, cancellation/disposal, platform/module availability and unknown native errors. Native diagnostics retain otherwise unmapped CKError details. The 200-item transport bound is explicit; the server remains authoritative for record/data limits. Uploads above the documented 50 MiB asset ceiling are rejected before submission.

Known per-record server conflicts/rejections are `notCommitted`. Network/response loss/cancellation after write submission is conservatively `unknown`. A serialization failure after a saved callback is also uncertain to the JS consumer, not a fabricated rejection. Process termination can lose any in-memory acknowledgement; durable application reconciliation remains required even when this library's promise semantics are correct.

## Durable assets and file ownership

Ordinary record/page conversion never exposes a temporary CloudKit URL. Asset fields are metadata markers `{type:'asset',value:{available:true}}` (lists expose a count). Use selected metadata keys to avoid downloading asset bytes at all. `downloadAssets` fetches requested scalar asset fields and caller-selected owner metadata in **one record fetch**, copies bytes while the native callback retains the source, and returns owner identity/system fields/change tag with the staged files. An absent field produces no asset entry, not an invented download or tombstone.

Staging lives under the application's **Application Support/ExpoCloudKitTransport/Assets** directory, excluded from backup but not an evictable cache. Each request writes exclusive files inside a unique `.partial-UUID` directory, checks cancellation between 256 KiB chunks, synchronizes files and renames the directory to a completed UUID before delivery. Failed/cancelled copies remove only their private files. On first staging use in a new process, abandoned `.partial-UUID` directories in this dedicated root are removed; completed directories are never automatically removed. I/O and disk-full failures retain diagnostics.

Ownership rules:

1. Upload source files are application-owned. Keep them stable/readable until operation settlement and any uncertain-write reconciliation permits releasing their lease. Native never deletes/moves upload sources.
2. Successful download settlement transfers ownership to the caller. Teardown or late cancellation cannot revoke delivered files. Files remain readable after callback completion and process restart; the signed-device procedure verifies this.
3. The caller verifies expected photo identity/checksum/version, rejects stale account/generation results, adopts/journals files and eventually deletes only its leased staging paths. Returned metadata enables validation; the library does not validate domain checksums.
4. If the process dies after native staging but before application journaling, completed files may be orphaned. The application owns completed-directory reconciliation/cleanup; do not delete unrelated app files or active leases. A sandbox reinstall is not a durability promise.

## Cancellation and teardown

`operation.cancel()` is idempotent and cancels a reserved or active native operation. `session.dispose()` cancels all outstanding operations, removes native/JS subscriptions, releases delivered bookkeeping and fences late callbacks. A cancelled reservation is retained only until its already-scheduled execute call receives the original-generation result. Native operations are serialized through a state queue; promises settle at most once. JS never replaces a native batch receipt when cancellation/disposal races with acknowledgement.

For batches/pages, cancellation returns accumulated successes and explicit failure/unattempted outcomes, not one undifferentiated rejection. A completed receipt remains authoritative even if application acknowledgement is delayed. Application generation fencing must not turn a stale result into permission to mutate another account's SQLite state; retain/reconcile it under its originating binding instead.

## Built release installation

Distribution uses a public, immutable GitHub Release tarball from
`ivanjx/expo-cloudkit`, not the upstream npm package. The version-specific
coordinates for `v0.21.0-fork.0` are:

- Tarball: https://github.com/ivanjx/expo-cloudkit/releases/download/v0.21.0-fork.0/expo-cloudkit-0.21.0-fork.0.tgz
- SHA-256 file: https://github.com/ivanjx/expo-cloudkit/releases/download/v0.21.0-fork.0/expo-cloudkit-0.21.0-fork.0.tgz.sha256

Only after publication and checksum verification, install in the application:

```sh
npx expo install "https://github.com/ivanjx/expo-cloudkit/releases/download/v0.21.0-fork.0/expo-cloudkit-0.21.0-fork.0.tgz"
```

```json
{
  "dependencies": {
    "expo-cloudkit": "https://github.com/ivanjx/expo-cloudkit/releases/download/v0.21.0-fork.0/expo-cloudkit-0.21.0-fork.0.tgz"
  }
}
```

Commit the exact URL and npm lockfile, including resolved integrity; subsequent
clean installs use `npm ci`. Public assets require no credentials or registry
account. If repository visibility changes, resolve and document the access
requirement rather than introducing an undisclosed private registry or token.
Keep release bytes available and unchanged: a changed artifact needs a new
version/tag, never asset replacement. Do not use `latest`, a branch, GitHub's
automatic source archive, or an expiring Actions artifact as the dependency.

The package name and `expo-cloudkit/transport` import are unchanged. No source
submodule or library preparation hook is needed. The tarball contains compiled
JavaScript, declarations and config plugin, native sources/podspec, and Expo
metadata. It does not install the library's development dependencies or compile
its TypeScript in the application. Swift still compiles in the app's normal iOS
build: this is not a native binary/XCFramework or an offline dependency installer.
Normal npm/CocoaPods installation still needs online dependencies unless cached.
Native/config changes require regenerating the native project as appropriate
and building a new development or release binary; a JS reload is insufficient.

For library development only, the example retains a `file:..` source link; build
that checkout explicitly with `npm ci` followed by `npm run build`. This is not
the consumer distribution route. Source-link singleton settings are explained
in [the device lab](../example-transport/README.md).

## Maintainer release procedure

Release from a clean, reviewed `main` commit containing the caller-owned
transport and packaging workflow. These were merged in
`a4a46f207486f39e4b8f70f5f56d052d12567c3e` with
[passing post-merge CI](https://github.com/ivanjx/expo-cloudkit/actions/runs/34735488404).
The release tag must match the package version; never retag or replace an
existing release.

1. Review the complete release change and finish the applicable CI gates,
   including the outside-checkout packed consumer and macOS native build.
   Commit source and release documentation on a feature branch and merge its PR
   into `main`. Record the actual release commit, package version and checksum
   from the release workflow's packaging output.
2. For local packaging, run `npm ci`, then
   `node .github/scripts/pack-release.mjs <output-directory>`.
   The helper requires a new or empty output directory, invokes `npm pack --json` exactly
   once, and uses the filename returned by npm. Its `prepack` lifecycle builds
   JS, declarations and plugin; do not add a redundant `npm run build` before
   packing. Output is the `.tgz`, `<filename>.sha256` in `sha256sum` format, and
   `release.json` with `filename`, `version`, `tag`, `sourceCommit`, `sourceDirty`, and `sha256`.
3. Run the [clean-consumer procedure](../example-transport/README.md#reproducible-source-and-packed-installation)
   against those actual bytes. Packaging alone is not proof of a native build,
   and historical CI is not a passing result for the new release revision.
4. With publication authorization, from the clean, reviewed `main` commit,
   create and push the exact tag:

   ```sh
   git tag -a v0.21.0-fork.0 -m "Release v0.21.0-fork.0"
   git push origin refs/tags/v0.21.0-fork.0
   ```

   The tag must equal `v` plus `package.json`'s version exactly.
5. The [release workflow](https://github.com/ivanjx/expo-cloudkit/actions/workflows/publish.yml)
   checks out the tag, installs locked dependencies, validates and packs once.
   It verifies `GITHUB_REF_TYPE=tag` / `GITHUB_REF_NAME` against the version.
   Read-only validation jobs pass the same tarball, checksum and metadata through
   `release-package`; downstream jobs verify checksums before use or upload.
   Only the release job receives `contents: write`, using the repository's
   `GITHUB_TOKEN`, not npm credentials. Release creation uses
   `gh release create --verify-tag` with the explicit tarball/checksum assets;
   an existing release fails instead of overwriting assets. It does not repack
   after validation.
6. Confirm the workflow's actual conclusion and both public asset downloads.
   Verify the downloaded checksum with `sha256sum -c <filename>.sha256`
   (or `shasum -a 256 -c <filename>.sha256` on macOS) from their directory.
   Record the actual source commit/checksum and release evidence, then hand off
   the now-available coordinates. A configured workflow alone is not publication.

## MainteNote migration handoff

Before migrating, confirm both public assets above are available and verify
their checksum. The app maintainer should:

1. Run the exact `npx expo install` command above; commit the immutable tarball
   URL in `package.json` and the updated npm lockfile with resolved integrity.
2. Remove only MainteNote's CloudKit source submodule through a scoped Git
   submodule removal and remove its specific `.gitmodules` entry. Inspect the
   app's actual submodule path first; preserve other submodules and unrelated
   local work, and do not use a blanket vendor-directory deletion.
3. Remove `scripts/prepare-cloudkit.cjs`, `cloudkit:prepare`,
   `eas-build-pre-install`, and corresponding CI preparation/submodule-checkout
   steps where no longer needed. Preserve any unrelated duties of shared hooks
   or checkout steps. No replacement library build/download hook is needed.
4. Remove vendor-specific lint and TypeScript exclusions made unnecessary by
   removing this source checkout; preserve unrelated exclusions.
5. Re-evaluate source-link autolinking workarounds, including
   `experiments.autolinkingModuleResolution` and `expo.autolinking.include`,
   against the installed package. Remove them only after proving they are
   unnecessary for the app's other dependencies and that singleton resolution
   remains correct.
6. Keep the plugin name `expo-cloudkit`, transport import, MainteNote's real
   container/environment configuration, thin adapter, SQLite authority,
   application sync responsibilities and app-specific signed-IPA verification.
   Do not move or redesign its diagnostic harness.
7. Verify a clean locked install without the vendor checkout/preparation script,
   Expo config/plugin evaluation and entitlements, Apple autolinking, types/lint,
   iOS export with no legacy transport dependency graph or duplicate runtimes,
   and the app's native build path. Rebuild for native changes and retain
   signed-device CloudKit verification; unsigned packaging checks do not prove
   CloudKit account/server access.

## Application plugin configuration

Configure the app's plugin with caller-owned identifiers:

```json
["expo-cloudkit", {
  "containerIds": ["iCloud.com.example.notes"],
  "iCloudContainerEnvironment": "Development",
  "enableRemoteNotifications": false
}]
```

Containers and CloudKit services merge with existing entitlements. Existing background modes/App Groups remain intact. Remote notification mode is enabled by default for legacy high-level consumers; explicitly disable it for manual-only transport. Do not configure background task identifiers or subscriptions you do not use. Production vs Development is a signed-binary entitlement/config decision, not a session option.

## Capability matrix and evidence

Source audit covered this checkout and the published `expo-cloudkit@0.20.8` tarball (SHA-1 `8075c661e5f65ea9ac4567f07c8a3b4454f7a284`). The published build/native/plugin were present; `.changedKeys` writes and destructive container entitlement assignment were verified in the archive, not inferred from README text. Existing sync adapter pending saves, UserDefaults checkpoint ownership, offline journal and `serverWins` overlay semantics remain incompatible and unchanged outside this isolated path.

| Handoff requirement | Existing capability / decision | Implementation evidence | Runtime evidence / remaining gate |
| --- | --- | --- | --- |
| 1. Explicit sessions/account | Existing global configure is unsuitable; independent session registry | `CloudKitTransport`, separate Expo module, typed SDK lifecycle | JS lifecycle regressions; native lifecycle tests/CI; real account-switch gate pending |
| 2. Explicit zones | Reuse CloudKit zone primitives, not high-level configure | Separate fetch/create operations; typed zone errors | Native compile/CI; signed missing/deleted-zone gate |
| 3. Caller checkpoints | Existing token store is incompatible | `fetchAllChanges=false`, scoped secure archive codec, no next token on failures | Native codec tests; real pagination/expiry/replay gate |
| 4. Targeted reads | Existing converter loses needed identity/system fields | Bounded per-item found/notFound/failed; selected keys | Native compile/CI; real mixed read gate |
| 5. Conditional masks | Existing `.changedKeys` manager incompatible | Reconstructed CKRecord + set/clear; `.ifServerRecordUnchanged` | Native dirty-mask regression; signed conflict/asset-preservation gates |
| 6. Partial outcomes/errors | Existing throwing batches lose acknowledgements | Structured per-item receipts, commit uncertainty, native diagnostics | JS cancellation receipt regressions; signed partial-error/reconciliation gate |
| 7. Durable assets | Existing converter exposes temp URL | Dedicated staging codec, same-record owner/version metadata, preserved uploads | Native copy/cancellation regressions; signed callback/restart/disk-pressure gate |
| 8. Cancellation/teardown | Independent registry required | Reserved IDs, CKOperation.cancel, exactly-once state fence | JS lifecycle regressions; native lifecycle tests; timing/account gates |
| 9. Config/distribution | Existing compiled plugin/build reused and extended | Entitlement merge, manual opt-out, prepack, root podspec path; release artifact verification | Historical installed-tarball/native checks passed below; new outside-checkout release consumer and native results require separate evidence |

Historical local transport verification (before this release-packaging change) exercised the compiled packed entry without loading React/native/high-level modules; root build and lint passed, all 281 existing/new JS tests passed, and the example typechecked. Packed Apple autolinking resolved `ExpoCloudKit` and both module classes; real plugin introspection produced Development/CloudKit/container entitlements and no background modes. Exact installed baseline: Expo57.0.12, RN0.86.2, React19.2.3. Native patch versions are recorded by lockfiles and the example README.

Expo's online `expo install --check` currently recommends newer rolling SDK57/RN/TypeScript patches. CI uses `EXPO_OFFLINE=1` for the pinned SDK57.0.12 bundled map, whose RN requirement is0.86.2, rather than silently upgrading the requested baseline. This does not establish native compatibility; the macOS build/tests do that independently.

GitHub workflow `.github/workflows/transport.yml` is shared by ordinary CI, the feature branch and release validation. It verifies an outside-checkout consumer of the tarball, then runs autolinking/prebuild/CocoaPods, the installed package's native XCTest suite and a Release-app UI smoke which calls real module create/validation/dispose methods. Source/PR runs pack their own artifact; release validation consumes the already packed `release-package` artifact without repacking. It uses a standard public macOS runner, no signing secrets or paid build. Raw Xcode logs/results are retained as evidence. Consult the actual run conclusion; adding the workflow alone is not a passed gate.

Simulator CI enables local ad-hoc signing (`CODE_SIGN_IDENTITY=-`) so the plugin-generated CloudKit entitlements remain present. CloudKit requires those entitlements even when constructing a container before any network operation. This uses no developer signing credentials and does not provision or authorize a real CloudKit container.

Source/PR runs additionally exercise the direct `file:..` source-linked example, rerun Apple autolinking/CocoaPods, rebuild, and repeat the real native module UI smoke. This remains a source-development regression route without introducing a submodule into this library repository. Release validation uses the installed tarball rather than this source-link route.

**Passed native evidence, 2026-09-10:** [GitHub run 34455535763](https://github.com/ivanjx/expo-cloudkit/actions/runs/34455535763) verified implementation commit `9e438311c7de26d0d47c722b2f1964990c37ea26` on Xcode26.4.1 / iPhone17 simulator / iOS26.4.1. All 281 JS tests and 145 native XCTest cases passed, including eight transport codec and three native lifecycle cases. Both the installed-tarball and source-linked Release apps passed real module creation/validation/teardown and native file-digest UI smoke. The run includes packed artifacts and raw Xcode results. It completed the then-current automated transport checks; physical-device provisioning and real CloudKit server scenarios are not proven.

That run is historical transport evidence, not a run of the new outside-checkout
consumer or GitHub Release workflow. New release-packaging checks must be
executed and their actual results recorded separately; this documentation does
not claim they or the proposed release's macOS native build have passed.

## Required signed-device gates (not production-ready)

Use the lab's generated `TransportVerification-...` zones, a disposable app/container and two clients on the same iCloud account. Never delete an existing dataset. Capture generation, identity, correlation IDs, record change tags/system fields, errors and checkpoint decisions. The detailed button-by-button procedure is in the example README.

1. **Expo57 native compilation/module loading:** run macOS CI and install the signed example on iPhone; confirm native module loading independently of Expo Go.
2. **Create/targeted fetch:** explicit zone creation, stable new record, metadata-only lookup plus missing ID; require found/notFound distinction.
3. **Two-writer conflict:** both read one version; A saves, B conflicts; fetch again proves A was not overwritten and server system fields are usable.
4. **Restart mask reconstruction:** persist a draft/system fields/mask, force-quit, relaunch and save without refreshing the server record first.
5. **Undownloaded-asset preservation:** fetch only metadata, remove any local upload lease after original save, restart/save metadata-only draft, then download and compare original asset bytes.
6. **Asset replacement/removal:** atomically update photo metadata and asset on one record; explicitly clear it; absent field yields no staged entry.
7. **Changes/replay:** limit1 pages, repeat an uncommitted page, commit page+token together, restart/resume; actual deletion via disposable Dashboard record; malformed/expired token and per-record failure must not advance.
8. **Mixed outcomes:** fresh record plus stale conflict plus invalid/unattempted input; successes remain acknowledged under partial operation errors/cancellation.
9. **Durable download:** copy returns same-version ownership and byte count; delete temporary/original source where safe, force-quit/restart and read staged bytes; verify cleanup does not remove caller upload sources.
10. **Cancellation/account lifecycle:** cancel before submit, during request, mid-copy with native instrumentation, and after server callback before application acknowledgement; repeated teardown and account switch fence stale work; unknown writes reconcile by IDs.
11. **Missing/deleted zone:** remove only the disposable zone using Dashboard; reads return typed failure and never recreate; explicit application policy decides reset.
12. **Distribution/config:** clean outside-checkout release-tarball install, native autolinking and Development/Production plugin generation with pre-existing entitlements; no unwanted background requirements. Source-linked development remains a separate regression route, not a consumer prerequisite.

Additional destructive-service conditions (quota exhaustion, token expiration, disk exhaustion) require deliberate disposable environment setup; do not claim them tested from mocks or merely observing a typed switch case. Signed CloudKit server gates remain unexecuted until the observations are recorded. Application integration behind an adapter is a separate task: this fork does not install application dependencies or implement domain/SQLite/synchronization logic.

## Primary references

- [Exact Expo SDK57 reference](https://docs.expo.dev/versions/v57.0.0/)
- [Expo SDK57 FileSystem](https://docs.expo.dev/versions/v57.0.0/sdk/filesystem/)
- [Conditional save policy](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/recordsavepolicy/ifserverrecordunchanged)
- [System fields do not encode user or dirty keys](https://developer.apple.com/documentation/cloudkit/ckrecord/encodesystemfields(with:))
- [CKAsset temporary staging and desired keys](https://developer.apple.com/documentation/cloudkit/ckasset)
- [CloudKit documented data limits](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/PropertyMetrics.html)
