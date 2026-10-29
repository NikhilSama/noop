# TO-FIX: iPhone battery drain (NOOP + Health both at the top of Settings → Battery)

Branch: `nikhil/custom`. Opened 2026-10-27. Setup: iPhone + WHOOP strap + **Apple Watch Ultra**.

## Status

- [x] Ruled out: Live HR Lock Screen banner (turned **off**; with the switch off each HR tick returns early).
- [x] Ruled out: Continuous HRV capture (**off**; "Overnight only" only narrows the base switch, so it does
      nothing while the base is off). Note: the "Deep sleep" picker is the HRV *window*, not a battery knob.
- [x] Ruled out for now: NOOP → Health heart-rate write (Heart Rate *write* permission not granted, and
      `writeHeartRate` returns early without `sharingAuthorized`). HRV write is ~14 samples/pass, negligible.
- [ ] **Running test (started 2026-10-27):** in iOS Settings → Health → Data Access & Devices → NOOP, turned
      off NOOP's READ access to Heart Rate, Active Energy (and Workouts / Workout Routes). If NOOP and Health
      both drop down the battery list after a day, the import path below is confirmed as the cause.
- [ ] Also worth trying: Settings → Power Saving → "Sync in the background every hour instead of every 15
      minutes" (cuts strap reconnect + offload + re-score + write-back passes by 4×).
- [ ] If still unclear: export the strap log (Live screen). Its header carries `HealthSyncStats` (observer
      wakes / full syncs / coalesced / empty wakes / ms spent in sync) for the session.

## Suspected causes (Apple Health import, all in `StrandiOS/Health/HealthKitBridge.swift`)

1. **Every app foreground runs a full 30-day `sync()` with no staleness gate.**
   `StrandiOSApp.swift` scenePhase `.active` → `HealthSyncRefreshCoordinator.run(sync: { await health.sync() })`,
   and `sync(days: Int = 30)`. Each pass: ~20 `HKStatisticsCollectionQuery` aggregates over 30 days, hourly
   steps, caffeine, sleep, workouts, then a full `writeBack`. The observer path has a 15-min coalesce
   (`observerCoalesceWindow`) but the foreground path deliberately ignores it.

2. **Every Watch workout in the window is re-fetched from scratch on every sync** (`collectWorkouts`):
   `fetchWorkoutRoute` (full GPS route), `fetchWorkoutHeartRate` (all workout HR samples),
   `fetchWorkoutSteps`, per workout, every time — even when the workout is already stored and unchanged.
   With an Ultra (dense GPS + HR) over 30 days this is the likely dominant `healthd` cost.

3. **Background observers on `.heartRate` and `.activeEnergyBurned`** (`liveQuantityIds`). An Ultra produces
   new samples for these every few minutes. While NOOP is kept alive in the background (BLE central for the
   strap sync) observer callbacks are not limited to the hourly background-delivery cadence; each wake runs an
   anchored delta query (and the anchor is deliberately NOT advanced on a coalesced wake, so the delta keeps
   growing until the next full sync). Daily HR avg/max and energy totals do not need minute-level freshness.
   The observer also uses `predicate: nil`, so NOOP's OWN Health writes wake it (filtered out afterwards by
   `notNoopAuthored`, i.e. an empty wake, but still a wake).

## Planned fixes

1. **Workout import cache.** Skip route / HR / steps fetch for a Watch workout already stored with the same
   identity (HK UUID or startTs+endTs+sport) and unchanged end date. Only new or edited workouts are read.
2. **Gate the foreground sync.** Skip if a sync completed < 15 min ago; otherwise read a short window
   (2–3 days); full 30-day window at most once per day (or on explicit pull / Settings "Sync now").
3. **Drop `.heartRate` and `.activeEnergyBurned` from background observers.** Keep HRV, resting HR, VO2 max,
   sleep, workouts. HR/energy refresh on foreground + after strap sync instead.

## Heart-rate write-back (fix before re-granting Heart Rate write permission)

`writeHeartRate(fromTs:nowTs:)` currently, on EVERY write-back (after every strap offload ≈ every 15 min, the
hourly `HealthWritebackBackgroundScheduler` task, every foreground sync, every deferred re-score):

- reads 1-min HR buckets from `cursor − 48 h` to now,
- **deletes all of NOOP's HR samples in that 48 h window**, then re-saves them all.

That is ~2,900 deletes + ~2,900 inserts per pass, ~275k Health DB writes/day, each one also syncing to iCloud
and the Watch, plus waking NOOP's own `.heartRate` observer. The 48 h overlap exists because an offload can
land data OLDER than the cursor (live HR advances the cursor while the strap's backlog fills a gap behind it).

Fix:
- Append-only past the cursor (with a small overlap, e.g. 10 min, for the partial last bucket).
- For the 48 h overlap: keep a per-hour fingerprint (count + bpm sum, FNV) in UserDefaults; only delete and
  rewrite the hours whose fingerprint changed. Steady state becomes ~15 inserts per pass, zero deletes.
- Optional: skip minutes where an Apple Watch HR sample already exists (avoid doubling the stream when both
  are worn) — behind a setting, since it changes what Health shows.

## How Health handles NOOP + Watch heart rate (for reference)

Two separate streams, never overwritten. Every sample keeps its source. Heart rate is a *discrete* type, and
the Data Sources priority order de-duplicates only *cumulative* types (steps, distance, energy). So the Health
HR chart and its daily min/avg/max blend both sources, and any third-party app reading HR sees both unless it
filters by source. NOOP's own HR import excludes NOOP-authored samples (`notNoopAuthored`), so there is no
read-back feedback loop.
