# Battery experiment: suspend mic while PTT idle (`battery-mic-idle` branch)

Experimental branch to test whether powering down the microphone while the
push-to-talk button is released improves battery life on the Hytera PNC550,
**without affecting voice** (receiving is untouched; transmitted audio quality
is unchanged).

## What changed
All changes are in the `humla` submodule (branch `battery-mic-idle`, commit
recorded by this repo's `battery-mic-idle` branch):

- `audio/inputmode/IInputMode.java` — new `canSuspendInputWhileIdle()` (default `false`).
- `audio/inputmode/ToggleInputMode.java` — returns `true` (PTT only).
- `audio/AudioInput.java` — `suspendRecording()` / `resumeRecording()` stop/start the
  `AudioRecord` (mic HAL) without releasing it.
- `protocol/AudioHandler.java` — in `onAudioInputReceived()`, suspend the mic before
  blocking in `waitForInput()` and resume on the next press.

Before: in PTT mode the mic stayed powered the entire session (frames read and
discarded while not talking). After: the mic is off whenever PTT is released.

## Known tradeoff
Restarting the mic on each press has a small warm-up (~tens of ms). If you press
**and immediately** talk, the first fraction of a syllable can be clipped. Mitigate by
the natural press-then-speak habit, or enable the PTT sound (Settings → Audio) so the
beep covers the warm-up. **This is the thing to listen for when testing.**

Note: the connection's `PARTIAL_WAKE_LOCK` is intentionally left in place — releasing it
would risk missing incoming calls (a worse trade for a radio). That is a separate,
riskier experiment.

## Build / install this branch
```
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
git submodule update --init --recursive     # if humla isn't on battery-mic-idle
./gradlew :app:assembleFossDebug
/opt/homebrew/share/android-commandlinetools/platform-tools/adb install -r \
  app/build/outputs/apk/foss/debug/mumla-foss-debug.apk
```

## Revert to the normal build
```
git checkout master
git submodule update --init --recursive
./gradlew :app:assembleFossDebug   # rebuild + reinstall
```

This branch is for local testing; the humla commit is local-only (not pushed to
gitlab.com/quite/humla), so build it on this machine.
