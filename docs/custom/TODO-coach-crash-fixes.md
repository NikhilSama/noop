# TODO: potential fixes for Coach chat crashes / freezes

Branch: `nikhil/custom`. Opened 2026-10-29. Deferred until the iPhone is on the same Wi-Fi as the Mac, so a
fix can be installed and checked with Xcode attached.

**Symptom:** after a few exchanges in the Coach chat, the chat freezes. Sometimes the app crashes; sometimes
it needs a force-quit and relaunch.

## Status

- [ ] Collect crash reports: Settings → Privacy & Security → Analytics & Improvements → Analytics Data →
      `NOOP-*.ips` (and any watchdog / `ExcResource` entries). AirDrop them to the Mac. A crash inside SwiftUI or
      Swift Array internals, or a "Publishing changes from background threads" message, confirms fix 1.
- [ ] With the phone on Xcode: reproduce a freeze and pause the debugger (or run the Time Profiler in
      Instruments) to see what the main thread is doing.
- [ ] Fix 1, fix 2, fix 3 below. Verify each on the device.

## Potential fixes

### 1. Streamed chunks change `@MainActor` state from a background thread (likely crash cause; confirmed)

`AICoachEngine` is `@MainActor`, but the streaming loop (`performStreamingRequest`, `Strand/AI/AIProvider.swift:373`)
is a nonisolated async function and so runs on the cooperative thread pool. It calls the caller's `onDelta` /
`onStatus` closures synchronously from there. Those closures mutate `messages`
(`Strand/AI/AICoach.swift` `send` and `startBriefIfNeeded`) and `toolStatus` (`streamProvider`), so every
streamed chunk writes `@Published` state off the main thread while SwiftUI reads it on the main thread.

The compiler does not catch this: `project.yml` builds with `SWIFT_VERSION: 5.0` and
`SWIFT_STRICT_CONCURRENCY: minimal`. Swift 6 mode would reject it. A standalone repro built with
`swiftc -swift-version 5` prints `send() on main: true` then `onDelta on main: false`.

This affects every provider (OpenAI, Gemini, Custom, Anthropic). The Anthropic tool loop
(`streamWithTools`) makes it more frequent, because replies are longer and the status line also updates.

**Fix:** make the callbacks `@MainActor` (`onDelta: @MainActor (String) -> Void`, the same for `onStatus` and
`onLine`) through `AIProviderClient`, `performStreamingRequest` and every provider in `Strand/AI/Providers/`,
and `await` the calls. Alternatively, have the engine hop each mutation onto the main actor. Swift-only; there
is no Kotlin parity impact.

### 2. Every chunk re-renders and re-parses the whole transcript (why it worsens "after a few exchanges")

Each chunk replaces the last `ChatMessage`, which republishes `messages` and re-evaluates the whole `CoachView`
body. `bubble(_:)` is a function, not its own view, so every visible assistant bubble rebuilds
`Markdown(message.text)` (MarkdownUI, `Strand/Screens/CoachView.swift:555`) and re-parses its full text,
tables included. The main-thread cost per chunk grows with the reply's length and with how many long replies
are on screen.

**Fix:**
- Publish the streamed text at most about every 100 ms, and always flush the final text.
- Move the bubble into its own `Equatable` view keyed on `ChatMessage`, so unchanged replies are not
  re-parsed.
- Optionally, render the streaming bubble as plain `Text` and switch to `Markdown` once the reply finishes.

### 3. An extra blocking summarization call before every message once past 11 messages

`summarizeDroppedMiddleIfNeeded` (`Strand/AI/AICoach.swift`) runs before the reply on every send once
`messages.count > maxHistoryMessages + 1`. It caches on the exact set of dropped messages, but that set changes
whenever the window slides, which is every turn. In practice each message pays for a full non-streaming
model call first (with the full coach system prompt and `max_tokens` 4096). Meanwhile the UI shows only
"Coach is thinking…", which reads as a freeze.

**Fix:** re-summarize only every N turns, or when the dropped set grows by K messages, and reuse the old
summary in between. Or summarize after the reply finishes, for the next turn. Give the summary call a small
`max_tokens` and a short system prompt. Note that the Android twin has the same K13 logic; decide whether the
change should be mirrored there.
