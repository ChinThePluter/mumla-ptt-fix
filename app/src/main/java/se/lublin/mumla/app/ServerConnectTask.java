/*
 * Copyright (C) 2014 Andrew Comminos
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

package se.lublin.mumla.app;

import android.content.Context;
import android.content.Intent;
import android.media.AudioManager;
import android.media.MediaRecorder;
import android.os.AsyncTask;

import java.util.ArrayList;

import se.lublin.humla.HumlaService;
import se.lublin.humla.model.Server;
import se.lublin.mumla.BuildConfig;
import se.lublin.mumla.R;
import se.lublin.mumla.Settings;
import se.lublin.mumla.db.MumlaDatabase;
import se.lublin.mumla.service.MumlaService;
import se.lublin.mumla.util.MumlaTrustStore;

/**
 * Constructs an intent for connection to a MumlaService and executes it.
 * Created by andrew on 20/08/14.
 */
public class ServerConnectTask extends AsyncTask<Server, Void, Intent> {
    private Context mContext;
    private MumlaDatabase mDatabase;
    private Settings mSettings;

    public ServerConnectTask(Context context, MumlaDatabase database) {
        mContext = context;
        mDatabase = database;
        mSettings = Settings.getInstance(context);
    }

    @Override
    protected Intent doInBackground(Server... params) {
        return buildConnectIntent(mContext, params[0], mDatabase);
    }

    /**
     * Builds the MumlaService ACTION_CONNECT intent for the given server, pulling all
     * audio / certificate / trust-store settings from {@link Settings} and the database.
     * Exposed as static so non-UI callers (e.g. connect-on-boot in BootPTTReceiver) can
     * reuse the exact same connect parameters.
     */
    public static Intent buildConnectIntent(Context context, Server server, MumlaDatabase database) {
        Settings settings = Settings.getInstance(context);

        /* Convert input method defined in settings to an integer format used by Humla. */
        int inputMethod = settings.getHumlaInputMethod();

        // INPUT: handset mode uses the (better) handset mic. OUTPUT: the loudspeaker,
        // unless the user wants earpiece routing (usesVoiceCallOutput) — decoupled so a
        // radio can have "handset mic + loud speaker".
        int audioSource = settings.isHandsetMode() ?
                MediaRecorder.AudioSource.DEFAULT : MediaRecorder.AudioSource.MIC;
        int audioStream = settings.usesVoiceCallOutput() ?
                AudioManager.STREAM_VOICE_CALL : AudioManager.STREAM_MUSIC;

        Intent connectIntent = new Intent(context, MumlaService.class);
        connectIntent.putExtra(HumlaService.EXTRAS_SERVER, server);
        connectIntent.putExtra(HumlaService.EXTRAS_CLIENT_NAME, context.getString(R.string.app_name)+" "+ BuildConfig.VERSION_NAME);
        connectIntent.putExtra(HumlaService.EXTRAS_TRANSMIT_MODE, inputMethod);
        connectIntent.putExtra(HumlaService.EXTRAS_DETECTION_THRESHOLD, settings.getDetectionThreshold());
        connectIntent.putExtra(HumlaService.EXTRAS_AMPLITUDE_BOOST, settings.getAmplitudeBoostMultiplier());
        connectIntent.putExtra(HumlaService.EXTRAS_AUTO_RECONNECT, settings.isAutoReconnectEnabled());
        connectIntent.putExtra(HumlaService.EXTRAS_AUTO_RECONNECT_DELAY, MumlaService.RECONNECT_DELAY);
        connectIntent.putExtra(HumlaService.EXTRAS_USE_OPUS, !settings.isOpusDisabled());
        connectIntent.putExtra(HumlaService.EXTRAS_INPUT_RATE, settings.getInputSampleRate());
        connectIntent.putExtra(HumlaService.EXTRAS_INPUT_QUALITY, settings.getInputQuality());
        connectIntent.putExtra(HumlaService.EXTRAS_FORCE_TCP, settings.isTcpForced());
        connectIntent.putExtra(HumlaService.EXTRAS_USE_TOR, settings.isTorEnabled());
        connectIntent.putStringArrayListExtra(HumlaService.EXTRAS_ACCESS_TOKENS, (ArrayList<String>) database.getAccessTokens(server.getId()));
        connectIntent.putExtra(HumlaService.EXTRAS_AUDIO_SOURCE, audioSource);
        connectIntent.putExtra(HumlaService.EXTRAS_AUDIO_STREAM, audioStream);
        connectIntent.putExtra(HumlaService.EXTRAS_FRAMES_PER_PACKET, settings.getFramesPerPacket());
        connectIntent.putExtra(HumlaService.EXTRAS_TRUST_STORE, MumlaTrustStore.getTrustStorePath(context));
        connectIntent.putExtra(HumlaService.EXTRAS_TRUST_STORE_PASSWORD, MumlaTrustStore.getTrustStorePassword());
        connectIntent.putExtra(HumlaService.EXTRAS_TRUST_STORE_FORMAT, MumlaTrustStore.getTrustStoreFormat());
        connectIntent.putExtra(HumlaService.EXTRAS_HALF_DUPLEX, settings.isHalfDuplex());
        connectIntent.putExtra(HumlaService.EXTRAS_ENABLE_PREPROCESSOR, settings.isPreprocessorEnabled());
        connectIntent.putExtra(HumlaService.EXTRAS_ECHO_CANCELLATION_METHOD, settings.getEchoCancellationMethod());
        connectIntent.putExtra(HumlaService.EXTRAS_SUSPEND_MIC_IDLE, settings.isSuspendMicWhileIdle());
        if (server.isSaved()) {
            ArrayList<Integer> muteHistory = (ArrayList<Integer>) database.getLocalMutedUsers(server.getId());
            ArrayList<Integer> ignoreHistory = (ArrayList<Integer>) database.getLocalIgnoredUsers(server.getId());
            connectIntent.putExtra(HumlaService.EXTRAS_LOCAL_MUTE_HISTORY, muteHistory);
            connectIntent.putExtra(HumlaService.EXTRAS_LOCAL_IGNORE_HISTORY, ignoreHistory);
        }

        if (settings.isUsingCertificate()) {
            long certificateId = settings.getDefaultCertificate();
            byte[] certificate = database.getCertificateData(certificateId);
            if (certificate != null)
                connectIntent.putExtra(HumlaService.EXTRAS_CERTIFICATE, certificate);
            // TODO(acomminos): handle the case where a certificate's data is unavailable.
        }

        connectIntent.setAction(HumlaService.ACTION_CONNECT);
        return connectIntent;
    }

    @Override
    protected void onPostExecute(Intent intent) {
        super.onPostExecute(intent);
        mContext.startService(intent);
    }
}
