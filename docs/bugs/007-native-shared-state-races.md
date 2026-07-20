# BUG-007: Native shared mutable state raced across threads (UAF / double-complete / cache corruption)

**Status:** open (each instance is fixed, but the *class* is only closed when every native
component that shares mutable state is audited against the invariant below — there is no
universal structural guard, and known gaps remain, see the end)
**Platform:** Android (Kotlin + Rust/JNI) and iOS/macOS (Swift) — anywhere native code holds
state touched by more than one thread.
**Spec:** the mutated state is owned by
[per-site-containers](../../openspec/specs/per-site-containers/spec.md),
[content-blocker](../../openspec/specs/content-blocker/spec.md), and
[web-push-notifications](../../openspec/specs/web-push-notifications/spec.md); none carried a
normative concurrency requirement — this file is the cross-cutting record.
**Formal model:** none. Native thread interleavings sit outside the TLA+ kernel's observable
projection ([formal/README.md](../../formal/README.md)); this class is guarded in code
(concurrency smoke test + structural funnel gate), not in the model.
**Tests:** [android/app/src/test/kotlin/.../AdblockEngineNativeTest.kt](../../android/app/src/test/kotlin/org/codeberg/theoden8/webspace/AdblockEngineNativeTest.kt)
(concurrent readers/writers don't deadlock or throw) and
[test/js/native_bgtask_completion_funnel.test.js](../../test/js/native_bgtask_completion_funnel.test.js)
(structural gate: completion only through the funnel). The intercept cache (attempt 3) has
no dedicated guard yet — see open gaps.

## Symptom

Three symptoms, one shape:

- **Adblock:** rare native crash on the chromium IO thread when the user flipped the
  content-blocker toggle while a page was loading sub-resources.
- **iOS notifications:** process crash (`BGTask.setTaskCompleted` called twice) or silently
  throttled background refresh (completion lost), when a background-refresh finished at the
  same moment iOS fired the task's expiration handler.
- **Content blocker (Android):** intermittent `ConcurrentModificationException` / an IO
  thread spinning at 100% on a busy page, and a transient window where a blocked host could
  slip through.

## Root mechanism (the invariant behind every instance)

A piece of **native mutable state is touched from more than one thread without total
synchronization**. In every case a *callback / IO thread* (chromium's sub-resource
`shouldInterceptRequest` workers, iOS's `expirationHandler`, the `BGTaskScheduler` launch
queue) read or freed state that another path (a method-channel handler on the main/platform
thread, a toggle, a timer) mutated concurrently — and the synchronization that existed was
**partial**, which is worse than none because it *looks* safe:

- adblock: only the two writers (`setRules`/`dispose`) were `@Synchronized`; the readers ran
  lock-free, so a `Box::from_raw` could free the engine mid-`deref`.
- iOS: `pendingRefreshTask` had no lock at all across three threads.
- intercept cache: only `clearHostDecisionCache` was `@Synchronized` (on `this`); the reads,
  writes, and FIFO eviction were lock-free.

**The invariant:** native state that any callback/IO thread can observe MUST be either
(a) not shared (single owner / immutable snapshot / message-passed), or (b) guarded by *total*
synchronization — every read, write, and eviction under the same monitor, one-shot resources
(a freed pointer, a completed task) made **idempotent and identity-guarded** so a second
completion is a no-op. Half a lock does not satisfy this.

## Fix attempts (chronological)

### Attempt 1 — Adblock JNI engine: read/write lock around free-vs-deref
**Date:** 2026-07-19 · **PR:** #495 · **Files:** `android/app/src/main/kotlin/.../AdblockEngineNative.kt`, `rust/webspace_adblock/src/jni.rs`
**What it did:** `nativeCheckUrl`/`nativeRedirectFor` deref the raw `enginePtr` (a
`Box<Engine>`) on the chromium IO thread while `setRules`/`dispose` `Box::from_raw` it.
Replaced the writer-only `@Synchronized` with a `ReentrantReadWriteLock`: readers take the
read lock (many concurrent, preserving the parallel hot path), writers take the write lock,
so no free runs while any read holds the pointer. Added a JVM concurrency smoke test.
**Why:** a use-after-free in native code is memory-unsafe and crashes the process.
**Why it was partial:** it closed the adblock engine's pointer only. The *class* — native
shared state raced across threads — still lived in the iOS background-task slot and the
Android intercept cache.

### Attempt 2 — iOS BGAppRefreshTask: funnel completion onto one queue, make it idempotent
**Date:** 2026-07-20 · **PR:** #498 · **Files:** `ios/Runner/BackgroundTaskPlugin.swift`
**What it did:** `pendingRefreshTask` was mutated and `setTaskCompleted` called from the
launch queue, the `expirationHandler`, and the main-thread `bgRefreshDidComplete` callback,
unsynchronized — so a completion racing an expiration could complete the task twice (crash)
or lose it (iOS throttles future scheduling). Confined all pending-slot access to the main
queue and made completion idempotent per task via a `completeTask(_:success:)` helper guarded
on task identity (`guard pendingRefreshTask === task`). Added a structural CI gate.
**Why:** `BGTask.setTaskCompleted` must fire exactly once; the notification-refresh contract
(NOTIF-005-I) breaks silently otherwise.
**Why it was partial:** it fixed the background-task slot. The Android sub-resource intercept
cache was still an unguarded `LinkedHashMap` on concurrent IO threads.

### Attempt 3 — Android intercept cache: one monitor for read, write, and eviction
**Date:** 2026-07-20 · **PR:** #504 · **Files:** `android/app/src/main/kotlin/.../WebInterceptPlugin.kt`
**What it did:** `FastSubresourceInterceptor.checkUrl` runs on chromium's concurrent
sub-resource IO threads and read, wrote, and FIFO-evicted a plain `LinkedHashMap` while only
`clearHostDecisionCache` was `@Synchronized`. Introduced a single `hostDecisionLock`; guarded
the cache read, `putHostDecision` (including eviction), and the clear under it; made
`checkCount` an `AtomicInteger`. Read the cache under the lock, computed on miss *outside* it
(to avoid holding the lock across the blocking `awaitReady`), wrote under the lock.
**Why:** concurrent structural mutation of a `LinkedHashMap` throws
`ConcurrentModificationException` or, on resize, forms a cycle that spins the IO thread; a
dropped `BLOCKED` entry is a transient filter-bypass.
**Why it was partial:** it closes this cache, but the class is not closed for good — a *new*
native component that shares mutable state can reintroduce it, and the fork + a few
same-class reads remain (open gaps).

## Known open gaps

1. **No universal structural guard.** Each instance got its own guard (or none, for the
   intercept cache). A new native plugin that shares mutable state across a callback/IO
   thread and another path can reintroduce the class silently. Mitigation is process: the
   CLAUDE.md "Adding native code that mutates shared state" checklist points here; hold every
   new native component to the invariant above.
2. **Fork `ContainerManager.swift` registry lost-update.** The `id → uuid` map's
   read-modify-write (`loadIdMap` → mutate → `saveIdMap`) is guarded by `sharedStoresLock`
   only inside `getOrCreateDataStore`; the same sequence in `deleteContainer`'s completion
   handler and `registerContainerBinding` runs without the lock. Same class, lives in the
   flutter_inappwebview fork (out of this repo's tree), not yet fixed. Consequence is a
   stale/missing registry entry, not a crash. Fix before the next fork tag.
3. **`WebInterceptPlugin` unsynchronized size checks.** The `cdnPatterns.isNotEmpty()` /
   `cdnCacheIndex.isNotEmpty()` reads sit outside the `synchronized` blocks that guard their
   real reads/writes. Benign (`isEmpty` can't throw), same class — fold into the lock.
4. **CONT-005 silent degrade-to-shared.** If the native `containerId` bind ever fails, the
   site falls back to the default store; the engine tolerates a zero-bind result but can't
   detect the degraded (isolation-lost) state. Wants a native post-bind assertion.
