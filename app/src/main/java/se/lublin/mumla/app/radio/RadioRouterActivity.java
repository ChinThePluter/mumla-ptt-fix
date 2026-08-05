/*
 * Copyright (C) 2026 Mumla keypad-radio UI add-on
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

package se.lublin.mumla.app.radio;

import android.content.Intent;
import android.hardware.input.InputManager;
import android.os.Bundle;
import android.view.InputDevice;

import androidx.appcompat.app.AppCompatActivity;

import se.lublin.mumla.Settings;
import se.lublin.mumla.app.MumlaActivity;

/**
 * The launcher activity. It immediately routes to the right UI and finishes:
 * the keypad/D-pad "radio" UI ({@link RadioActivity}) on devices without a real
 * touchscreen (e.g. Hytera POC radios), otherwise the normal {@link MumlaActivity}.
 *
 * This keeps the touch UI completely untouched; the only shared change is that
 * this trampoline (not MumlaActivity) is the MAIN/LAUNCHER entry point.
 */
public class RadioRouterActivity extends AppCompatActivity {

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        Class<?> target = useRadioUi() ? RadioActivity.class : MumlaActivity.class;
        startActivity(new Intent(this, target));
        finish();
    }

    private boolean useRadioUi() {
        switch (Settings.getInstance(this).getRadioUiMode()) {
            case "on":  return true;   // force keypad UI (testing on a touch device)
            case "off": return false;  // force the normal touch UI
            default:    return !hasTouchscreen();  // "auto"
        }
    }

    /**
     * True only if a real touchscreen input device is present. We check the actual
     * input devices rather than {@code PackageManager.FEATURE_TOUCHSCREEN}, because
     * some POC radios declare that feature while having no touch hardware at all.
     */
    private boolean hasTouchscreen() {
        InputManager im = (InputManager) getSystemService(INPUT_SERVICE);
        if (im == null) {
            return true; // fail safe: prefer the normal UI if we can't tell
        }
        for (int id : im.getInputDeviceIds()) {
            InputDevice device = im.getInputDevice(id);
            if (device != null
                    && (device.getSources() & InputDevice.SOURCE_TOUCHSCREEN) == InputDevice.SOURCE_TOUCHSCREEN) {
                return true;
            }
        }
        return false;
    }
}
