# Disk reclaim safety

Twozz participates in the same release-safe Apple build/cleanup interlock used
by the other apps on this machine. This repository does not contain or enable
the destructive cleanup implementation. It only publishes shared build leases
so an approved cleanup tool can refuse to run while Twozz owns build resources.

## Current rollout status: destructive cleanup disabled

Two independent gates must remain closed until every owner listed below is
ported or administratively disabled:

1. `~/.config/smart-disk-maintenance/SUSPENDED` must be absent.
2. The exact rollout policy must exist at
   `~/.config/smart-disk-maintenance/apple-build-interlock-v1/rollout-policy-v1`.

The machine currently uses `SUSPENDED`. This repository does not remove it,
create the rollout policy, enable a scheduler, or authorize cleanup.

The required rollout file is intentionally all-or-nothing:

```text
protocol=1
global-cleanup-entrypoints
manual-xcode-writers-disabled-or-wrapped
mozz-current-writers
mozz-legacy-writers
plozz-current-writers
plozz-legacy-writers
twozz-current-writers
twozz-legacy-writers
```

Each line means the named owner has confirmed every relevant writer uses this
protocol before its first build-resource write, or cannot run during cleanup.
Listing an owner without completing that work is not authorization. Missing,
reordered, extra, unreadable, replaced, symlinked, or writable-by-other policy
data denies cleanup. There is no environment or command-line bypass.

This change implements only `twozz-current-writers` in this branch. Plozz's
current-writer implementation landed separately. Remaining blockers include:

- the 137 linked Twozz checkouts other than this worktree, including the
  primary checkout, inventoried on 2026-09-06 without this protocol;
- direct/manual Xcode, raw `xcodebuild`, raw `xcodegen`, Swift compiler tools,
  and third-party build tools that bypass repository wrappers;
- current and older Mozz writers;
- older Plozz worktrees;
- installed global cleanup entrypoints and policy-update tooling.

Until those owners are coordinated, keep `SUSPENDED`, keep broad schedules
disabled, and do not create the rollout file. Porting this branch is not
permission to run cleanup.

## Shared/exclusive protocol

The same-user host-wide namespace is:

```text
~/.config/smart-disk-maintenance/apple-build-interlock-v1/
```

The path is physically resolved from the effective UID's account record, not
caller `HOME`, so alternate environments or a symlinked home cannot create a
second production lock domain or weaken protected-path comparisons. It is
outside DerivedData, SwiftPM caches, worktrees, and every reclaim target.

The protocol uses Darwin `flock` through the system Python standard library:

- build, test, generation, localization, archive, upload, processing,
  distribution, and tagging lanes hold a shared lease;
- several shared leases may coexist;
- cleanup requests an exclusive lease with `LOCK_NB` and refuses immediately
  when any shared lease is active;
- once exclusive ownership exists, a new cooperative build cannot start until
  cleanup releases it.

Shell and Fastlane callers retain the actual locked file descriptor and export
its authenticated descriptor identity to descendants. Descendants inherit the
same open file description, so a parent exit cannot release the kernel lock
while a child still owns that descriptor. Nested entrypoints validate an
unlinked proof descriptor plus exact lease id/token, record schema, lock inode,
owner, and mode. Partial, forged, closed, replaced, or stale inherited state
fails; it never falls back to a new lease.

Every lease also publishes a durable JSON identity under `leases/`. Normal
completion authenticates a release request, then a background finalizer waits
for all inherited shared descriptors to close before removing that record.
Signals, hard crashes, failed lanes, helper errors, malformed records, unknown
files, or finalizer failure leave evidence behind. Exclusive cleanup refuses
every remaining record and never infers safety from PID age, an empty process
list, or a quiet machine.

Inspect records without changing them:

```bash
/usr/bin/python3 tools/lib/apple_build_lease.py inspect
```

There is deliberately no automatic stale-record deletion. Investigate the
record and its owner while cleanup remains suspended before resolving any exact
fixture or production record.

## Twozz writer coverage

Current Twozz entrypoints acquire a shared lease before their first relevant
write:

- Fastlane `generate_project`, `build`, `beta`, and `release`; outer
  `beta`/`release` ownership spans project generation, archive/export, upload,
  processing/distribution behavior performed by Fastlane, and all gaps between
  those operations;
- `tools/generate-project.sh`;
- `tools/bootstrap-worktree.sh`, by delegating generation to the protected
  generator;
- `tools/xcbuild.sh`, which covers repository-supported build, test, archive,
  build-settings, and device/simulator Xcode invocations.

This repository currently has no Apple-build GitHub Actions workflow, deploy
script, screenshot runner, localization compiler/extractor, or separate test
runner. Adding any such entrypoint requires acquiring the same shared lease
before its first build-resource write. The existing Linux data-refresh and
version-bump workflows do not invoke Apple build tools.

The lease is independent of output naming and location. Worktree build folders,
DerivedData, SwiftPM repositories, archives, and release evidence remain
distinct real outputs; this change does not merge, rename, delete, or
reinterpret them.

## Frozen protocol provenance

The protocol was copied from the Plozz tree at frozen commit
`b1d24c0de` (the release-safe interlock originated in `5407b2508`). The three
language helpers are vendored byte-for-byte so Twozz and Plozz use one wire
protocol without a runtime dependency on another worktree:

| File | SHA-256 |
|---|---|
| `tools/lib/apple-build-lease.sh` | `bcb0a687d32ffa740953a687c812515d2516bd0ba90ea824c01c21fc6303c705` |
| `tools/lib/apple_build_lease.py` | `56a54b71f9a642ddd5e10a51128bc59610cbe6e3f9600cc7f6799c3b196bdca2` |
| `tools/lib/apple_build_lease.rb` | `c7726eaf3470da9dacbacbdf65d86ce353770f47da15882624be4455b7008372` |

`tools/with-apple-build-lease.sh` is also copied from that frozen commit. Its
repository-relative working-directory behavior already matches Twozz, so no
path adaptation was required.

## Defense in depth

The cleanup implementation must retain its prior checks after acquiring
exclusive ownership, including a continuous Apple-build quiet interval, process
checks, open-path inspection, recent-mtime skips, strict target validation, and
hard refusal for the shared SwiftPM repository cache. Those checks catch
uncooperative or unexpected activity, but they do not replace the cooperative
lease because process sampling has a start-after-check race.

The policy lock must be held shared for the whole cleanup lane. Future tooling
that changes `SUSPENDED` or rollout policy must take the conflicting exclusive
policy lock. Manual file changes that ignore this protocol remain a rollout
blocker.

Protected source, Git data, worktrees, archives, IPAs, release dSYMs/evidence,
SDKs/toolchains, shared SwiftPM dependencies, simulator data, VMs, personal
data, and Trash are not made eligible by this lease. Target selection and
release-retention policy remain separate mandatory checks.

## Regression tests

No app build or real cleanup is required:

```bash
tools/tests/test-apple-build-interlock.sh
```

The tests use private temporary HOME/cache roots and fixture commands only.
They cover concurrent readers, nonblocking exclusive refusal, release-lane
gaps, nested and exec inheritance, Ruby-to-child descriptor inheritance,
children outliving parents, written identity, effective-UID and physical-home
resolution, forged environments, signal/crash/failed-lane evidence, malformed
registry state, lock replacement, suspension/rollout gates, and current writer
entrypoint coverage.
