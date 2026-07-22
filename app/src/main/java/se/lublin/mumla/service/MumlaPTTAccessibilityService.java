/*
 * Copyright (C) 2026 Mumla background-PTT add-on
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

package se.lublin.mumla.service;

import android.accessibilityservice.AccessibilityService;
import android.content.Intent;
import android.util.Log;
import android.view.KeyEvent;
import android.view.accessibility.AccessibilityEvent;

import se.lublin.mumla.Settings;
import se.lublin.mumla.service.ipc.TalkBroadcastReceiver;

/**
 * Optional, fully self-contained add-on that lets the hardware push-to-talk
 * (PTT) key toggle the microphone even when Mumla is in the background or the
 * screen is off.
 *
 * <p>Background: the app normally handles the PTT key in
 * {@code MumlaActivity.onKeyDown()/onKeyUp()}, which only receives key events
 * while the activity is in the foreground. On dedicated PTT devices (e.g. a
 * Hytera POC radio) this means the button stops working once the screen turns
 * off.
 *
 * <p>By declaring {@code android:canRequestFilterKeyEvents="true"} (see
 * {@code res/xml/ptt_accessibility_service.xml}) this service receives raw key
 * events globally, regardless of which window is focused or whether the screen
 * is on. When the configured PTT key
 * ({@link Settings#getPushToTalkKey()}, set under Settings &gt; Audio &gt;
 * "Push-to-talk key") is pressed, it forwards the press to the running
 * {@code MumlaService} through the existing {@link TalkBroadcastReceiver},
 * reusing {@code onTalkKeyDown()/onTalkKeyUp()} so that all PTT settings
 * (toggle mode, input method) behave exactly as they do in the foreground.
 *
 * <p>This class intentionally does not touch any existing app logic. If the
 * user never enables the service (Settings &gt; Accessibility) nothing changes
 * and the app keeps handling the PTT key through {@code MumlaActivity} as
 * before.
 */
public class MumlaPTTAccessibilityService extends AccessibilityService {
    private static final String TAG = "MumlaPTT";

    @Override
    protected boolean onKeyEvent(KeyEvent event) {
        // Log every key so the actual PTT keycode can be discovered with:
        //   adb logcat -s MumlaPTT
        Log.d(TAG, "onKeyEvent keyCode=" + event.getKeyCode()
                + " (" + KeyEvent.keyCodeToString(event.getKeyCode()) + ")"
                + " action=" + event.getAction()
                + " repeat=" + event.getRepeatCount());

        final int pttKey = Settings.getInstance(this).getPushToTalkKey();

        // Settings.DEFAULT_PUSH_KEY (-1) means "no PTT key configured". In that
        // case never consume anything, so the device behaves completely
        // normally until the user actually assigns a PTT key.
        if (pttKey == Settings.DEFAULT_PUSH_KEY || event.getKeyCode() != pttKey) {
            return false; // not our key -> let the system / foreground app handle it
        }

        switch (event.getAction()) {
            case KeyEvent.ACTION_DOWN:
                // Ignore auto-repeat events while the key is held down.
                if (event.getRepeatCount() == 0) {
                    forwardTalk(TalkBroadcastReceiver.TALK_STATUS_KEY_DOWN);
                }
                return true; // consume -> avoids MumlaActivity handling it a second time
            case KeyEvent.ACTION_UP:
                forwardTalk(TalkBroadcastReceiver.TALK_STATUS_KEY_UP);
                return true;
            default:
                return true;
        }
    }

    /**
     * Forwards a PTT key press/release to MumlaService via an explicit
     * (same-package) TALK broadcast. If MumlaService is not connected the
     * broadcast receiver is not registered and the event is simply dropped,
     * which mirrors the foreground behaviour.
     */
    private void forwardTalk(String status) {
        Intent intent = new Intent(TalkBroadcastReceiver.BROADCAST_TALK);
        intent.setPackage(getPackageName()); // keep it strictly intra-app
        intent.putExtra(TalkBroadcastReceiver.EXTRA_TALK_STATUS, status);
        sendBroadcast(intent);
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        // Unused: this service only cares about filtered key events.
    }

    @Override
    public void onInterrupt() {
        // Nothing to interrupt.
    }
}
