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

import android.Manifest;
import android.content.ComponentName;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.IBinder;
import android.util.Log;
import android.view.KeyEvent;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import java.security.KeyStore;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.List;

import se.lublin.humla.HumlaService;
import se.lublin.humla.IHumlaSession;
import se.lublin.humla.model.IChannel;
import se.lublin.humla.model.IUser;
import se.lublin.humla.model.Server;
import se.lublin.humla.model.TalkState;
import se.lublin.humla.util.HumlaException;
import se.lublin.humla.util.HumlaObserver;
import se.lublin.mumla.R;
import se.lublin.mumla.Settings;
import se.lublin.mumla.app.ServerConnectTask;
import se.lublin.mumla.db.MumlaDatabase;
import se.lublin.mumla.db.MumlaSQLiteDatabase;
import se.lublin.mumla.service.IMumlaService;
import se.lublin.mumla.service.MumlaService;
import se.lublin.mumla.util.MumlaTrustStore;

/**
 * Minimal keypad/D-pad UI for no-touch radios (phase 1: the TALK/status screen).
 *
 * Reuses the existing backend untouched: it binds {@link MumlaService}, auto-connects
 * to the first favourite server via {@link ServerConnectTask}, and reflects connection
 * / channel / talk state via a {@link HumlaObserver}. The hardware PTT key is handled by
 * {@code MumlaService.onTalkKeyDown/Up} (globally by the accessibility service when the
 * screen is off, and here as a foreground fallback).
 */
public class RadioActivity extends AppCompatActivity {

    private static final String TAG = "RadioUI";
    private static final int REQ_RECORD_AUDIO = 1;

    private Settings mSettings;
    private MumlaDatabase mDatabase;
    private IMumlaService mService;
    private boolean mConnectRequested;
    private boolean mCertTrusted;
    private Server mFavourite;

    private TextView mServerText;
    private TextView mStatusText;
    private TextView mChannelText;
    private TextView mTalkingText;
    private TextView mPttText;

    private final ServiceConnection mConnection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
            mService = ((MumlaService.MumlaBinder) binder).getService();
            Log.i(TAG, "onServiceConnected connected=" + mService.isConnected()
                    + " state=" + mService.getConnectionState());
            mService.registerObserver(mObserver);
            maybeAutoConnect();
            updateUi();
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            mService = null;
        }
    };

    private final HumlaObserver mObserver = new HumlaObserver() {
        @Override public void onConnecting() { updateUi(); }
        @Override public void onConnected() { updateUi(); }
        @Override public void onDisconnected(HumlaException e) { updateUi(); }
        @Override public void onTLSHandshakeFailed(X509Certificate[] chain) { trustAndReconnect(chain); }
        @Override public void onUserTalkStateUpdated(IUser user) { updateUi(); }
        @Override public void onUserJoinedChannel(IUser u, IChannel n, IChannel o) { updateUi(); }
        @Override public void onUserConnected(IUser user) { updateUi(); }
        @Override public void onUserRemoved(IUser user, String reason) { updateUi(); }
        @Override public void onChannelStateUpdated(IChannel channel) { updateUi(); }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        mSettings = Settings.getInstance(this);
        mDatabase = new MumlaSQLiteDatabase(this);

        setContentView(R.layout.activity_radio);
        mServerText = findViewById(R.id.radio_server);
        mStatusText = findViewById(R.id.radio_status);
        mChannelText = findViewById(R.id.radio_channel);
        mTalkingText = findViewById(R.id.radio_talking);
        mPttText = findViewById(R.id.radio_ptt);

        // The provisioned radio has exactly one favourite server; connect to it.
        List<Server> servers = mDatabase.getServers();
        mFavourite = servers.isEmpty() ? null : servers.get(0);
        mServerText.setText(mFavourite != null ? mFavourite.getName() : "");
        Log.i(TAG, "onCreate favourites=" + servers.size()
                + " favourite=" + (mFavourite != null ? mFavourite.getName() : "null"));

        // Provisioning grants RECORD_AUDIO over adb (the keypad UI can't easily show a
        // dialog); request it at runtime too as a fallback for non-provisioned installs.
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this,
                    new String[]{Manifest.permission.RECORD_AUDIO}, REQ_RECORD_AUDIO);
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, @NonNull String[] permissions,
                                           @NonNull int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        // If the mic permission was just granted, (re)connect so the audio input can
        // initialize — a connection made before the grant comes up without a working mic.
        if (requestCode == REQ_RECORD_AUDIO && grantResults.length > 0
                && grantResults[0] == PackageManager.PERMISSION_GRANTED
                && mService != null && !mService.isConnected()) {
            mConnectRequested = false;
            maybeAutoConnect();
        }
    }

    @Override
    protected void onStart() {
        super.onStart();
        // BIND_AUTO_CREATE so a cold launch creates the service; the actual connect
        // is kicked off by ServerConnectTask (startService) in maybeAutoConnect().
        bindService(new Intent(this, MumlaService.class), mConnection, BIND_AUTO_CREATE);
    }

    @Override
    protected void onStop() {
        super.onStop();
        if (mService != null) {
            mService.unregisterObserver(mObserver);
        }
        unbindService(mConnection);
        mService = null;
    }

    private void maybeAutoConnect() {
        if (mConnectRequested || mService == null) {
            Log.i(TAG, "autoConnect skip: requested=" + mConnectRequested + " service=" + mService);
            return;
        }
        if (mService.isConnected()
                || mService.getConnectionState() == HumlaService.ConnectionState.CONNECTING) {
            Log.i(TAG, "autoConnect skip: already " + mService.getConnectionState());
            return; // already connected/connecting
        }
        if (mFavourite == null) {
            Log.w(TAG, "autoConnect skip: no favourite server in DB");
            return; // nothing to connect to
        }
        mConnectRequested = true;
        Log.i(TAG, "autoConnect -> connecting to " + mFavourite.getName()
                + " (" + mFavourite.getHost() + ":" + mFavourite.getPort() + ")");
        connect();
    }

    private void connect() {
        if (mFavourite != null) {
            new ServerConnectTask(this, mDatabase).execute(mFavourite);
        }
    }

    /**
     * Trust-on-first-use: the radio is dedicated to one known server, so when its
     * (self-signed) certificate isn't trusted yet, add it to the trust store and
     * reconnect instead of showing a keypad-unfriendly "trust this?" dialog. One-shot
     * per session to avoid a reconnect loop if trusting doesn't resolve the handshake.
     */
    private void trustAndReconnect(X509Certificate[] chain) {
        if (mCertTrusted || chain == null || chain.length == 0 || mFavourite == null) {
            return;
        }
        mCertTrusted = true;
        try {
            KeyStore trustStore = MumlaTrustStore.getTrustStore(this);
            trustStore.setCertificateEntry(mFavourite.getHost(), chain[0]);
            MumlaTrustStore.saveTrustStore(this, trustStore);
            Log.i(TAG, "trusted server cert (TOFU), reconnecting");
            connect();
        } catch (Exception e) {
            Log.w(TAG, "failed to trust server cert", e);
        }
    }

    private void updateUi() {
        runOnUiThread(() -> {
            mServerText.setText(mFavourite != null ? mFavourite.getName() : "");

            HumlaService.ConnectionState state = mService != null
                    ? mService.getConnectionState() : HumlaService.ConnectionState.DISCONNECTED;

            if (mService != null && mService.isConnected()) {
                mStatusText.setText(R.string.radio_status_connected);
                IHumlaSession session = mService.HumlaSession();
                IChannel channel = session.getSessionChannel();
                mChannelText.setText(channel != null ? channel.getName() : "");
                mTalkingText.setText(talkingUsers(channel));
                mPttText.setText(session.isTalking()
                        ? getString(R.string.radio_transmitting)
                        : getString(R.string.radio_hold_to_talk));
            } else {
                mStatusText.setText(state == HumlaService.ConnectionState.CONNECTING
                        ? getString(R.string.radio_status_connecting)
                        : getString(R.string.radio_status_offline));
                mChannelText.setText("");
                mTalkingText.setText("");
                mPttText.setText("");
            }
        });
    }

    /** Comma-separated names of users currently talking in the given channel. */
    private String talkingUsers(IChannel channel) {
        if (channel == null) {
            return "";
        }
        List<String> names = new ArrayList<>();
        for (IUser user : channel.getUsers()) {
            if (user.getTalkState() != TalkState.PASSIVE) {
                names.add(user.getName());
            }
        }
        return names.isEmpty() ? getString(R.string.radio_nobody_talking)
                : android.text.TextUtils.join(", ", names);
    }

    // --- hardware PTT key (foreground fallback; the accessibility service handles it
    //     globally when the screen is off and consumes the key before it reaches here) ---
    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (mService != null && keyCode == mSettings.getPushToTalkKey()) {
            mService.onTalkKeyDown();
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    @Override
    public boolean onKeyUp(int keyCode, KeyEvent event) {
        if (mService != null && keyCode == mSettings.getPushToTalkKey()) {
            mService.onTalkKeyUp();
            return true;
        }
        return super.onKeyUp(keyCode, event);
    }
}
