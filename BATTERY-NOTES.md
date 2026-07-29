# Battery-saving notes

Battery tweaks for the S12 Mumla build on the Hytera POC radios. All of this is
now on `master` (there is no separate branch). Receiving audio is never affected
by any of it.

## 1. Suspend the mic while push-to-talk is released
Powers the microphone (audio HAL) down whenever PTT is released, instead of
keeping it capturing-and-discarding for the whole session.

- **User setting:** Settings → Audio → **"Power-save microphone"** (`suspend_mic_idle`),
  **default OFF (opt-in)**. Turn it on to power the mic down while PTT is released
  and save battery; leave it off for the stock always-on-mic behaviour.
- **Scope:** only push-to-talk. Voice-activity and continuous modes keep the mic
  running regardless of the setting (they must sample it to decide when to send).
- **Where:** humla `AudioHandler.onAudioInputReceived()` calls
  `AudioInput.suspendRecording()/resumeRecording()` (which `stop()/startRecording()`
  the `AudioRecord` without releasing it). Gated by `IInputMode.canSuspendInputWhileIdle()`
  (true only for `ToggleInputMode`) **and** the `suspendInputWhileIdle` flag, wired from
  the app via `HumlaService.EXTRAS_SUSPEND_MIC_IDLE` ← `Settings.isSuspendMicWhileIdle()`.
- **Takes effect on connect** (reconnect to apply a change to the setting).

### Known tradeoff
Restarting the mic on each press has a small warm-up (~tens of ms). If you press
**and immediately** talk, the first fraction of a syllable can be clipped. Mitigate by
the natural press-then-speak habit, or enable the PTT beep (Settings → Audio) so the
tone covers the warm-up. **This is the thing to listen for when testing.** If it bothers
you, just turn "Power-save microphone" off.

## 2. Ping the server every 10s instead of 5s
humla `HumlaConnection` pings TCP+UDP on a fixed interval; raised from the stock 5s
to `PING_INTERVAL_SECONDS = 10` (fewer radio wake-ups).

- ⚠️ **Requires a matching server change:** the Mumble server's `timeout` (in
  `mumble-server.ini` / `murmur.ini`) must be raised to **>= 30s** and the service
  restarted. With the default 15s, a single lost ping at a 10s interval can disconnect
  the client. All devices share one server, so set it once server-side.
- Proportional to stock (5s ping / 15s timeout → 10s ping / 30s timeout): still 3 pings
  before timeout, so packet-loss tolerance is unchanged.

## Deliberately NOT changed
The connection's 24/7 `PARTIAL_WAKE_LOCK` in `HumlaService` is left in place — releasing
it would risk missing incoming calls (a worse trade for a radio). That is a separate,
riskier experiment and the biggest remaining battery lever.

## Build / install
Standard build (humla is pinned to the personal fork `github.com/ChinThePluter/humla`,
which carries these commits):
```
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
git submodule update --init --recursive
./gradlew :app:assembleFossDebug
/opt/homebrew/share/android-commandlinetools/platform-tools/adb install -r \
  app/build/outputs/apk/foss/debug/mumla-foss-debug.apk
```
Not yet field-tested by the user.
