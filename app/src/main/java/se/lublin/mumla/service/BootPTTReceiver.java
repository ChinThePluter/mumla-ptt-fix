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

import android.content.BroadcastReceiver;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.provider.Settings;
import android.text.TextUtils;
import android.util.Log;

import java.util.List;

import se.lublin.humla.model.Server;
import se.lublin.mumla.app.ServerConnectTask;
import se.lublin.mumla.db.MumlaDatabase;
import se.lublin.mumla.db.MumlaSQLiteDatabase;

/**
 * Re-enables the background-PTT accessibility service on every boot.
 *
 * The Hytera POC radios RESET {@code enabled_accessibility_services} on boot, dropping any
 * user-added accessibility service (keeping only the system one), so the hardware PTT key
 * stops working with the screen off after every reboot. This receiver re-adds our service.
 *
 * Writing that secure setting needs {@code WRITE_SECURE_SETTINGS} — a development permission
 * that setup-device.sh grants over adb ({@code pm grant}). Without the grant this is a
 * harmless no-op (the setting can still be re-enabled by hand or via reenable-bg-ptt.sh).
 */
public class BootPTTReceiver extends BroadcastReceiver {
    private static final String TAG = "MumlaPTT";

    @Override
    public void onReceive(Context context, Intent intent) {
        reEnableAccessibility(context);
        maybeAutoConnect(context);
    }

    /** Re-add our accessibility service to the (boot-wiped) secure settings so it rebinds. */
    private void reEnableAccessibility(Context context) {
        final String service = context.getPackageName()
                + "/se.lublin.mumla.service.MumlaPTTAccessibilityService";
        try {
            ContentResolver cr = context.getContentResolver();
            String enabled = Settings.Secure.getString(cr,
                    Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
            if (enabled == null) {
                enabled = "";
            }
            if ((":" + enabled + ":").contains(":" + service + ":")) {
                return; // already listed — nothing to do
            }
            // Append ours (keep any others), and make sure accessibility is on so the
            // system binds it. This mirrors what reenable-bg-ptt.sh does over adb.
            String updated = TextUtils.isEmpty(enabled) ? service : enabled + ":" + service;
            Settings.Secure.putString(cr, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, updated);
            Settings.Secure.putInt(cr, Settings.Secure.ACCESSIBILITY_ENABLED, 1);
            Log.i(TAG, "re-enabled background-PTT accessibility service on boot");
        } catch (Exception e) {
            // Most likely WRITE_SECURE_SETTINGS wasn't granted; can't recover from here.
            Log.w(TAG, "could not re-enable accessibility on boot: " + e);
        }
    }

    /**
     * If enabled (auto_connect_on_boot, default on), connect to the favourite server on
     * boot so the radio is ready without the user opening the app. Gated by a setting so
     * it can be turned off at any time (unlike a third-party auto-start app).
     */
    private void maybeAutoConnect(Context context) {
        try {
            if (!se.lublin.mumla.Settings.getInstance(context).isAutoConnectOnBoot()) {
                return;
            }
            MumlaDatabase database = new MumlaSQLiteDatabase(context);
            List<Server> servers = database.getServers();
            if (servers.isEmpty()) {
                return;
            }
            // startService works from a boot receiver on the target Android 7.1 radios; on
            // Android 8+ (background start) it throws and is caught — auto-connect is a radio
            // feature, not needed on touch phones.
            context.startService(ServerConnectTask.buildConnectIntent(context, servers.get(0), database));
            Log.i(TAG, "auto-connecting to " + servers.get(0).getName() + " on boot");
        } catch (Exception e) {
            Log.w(TAG, "auto-connect on boot skipped: " + e);
        }
    }
}
