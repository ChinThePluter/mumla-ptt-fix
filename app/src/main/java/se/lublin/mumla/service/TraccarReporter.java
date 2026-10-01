/*
 * Battery-friendly GPS -> Traccar position reporter for the S12 Mumla fork.
 *
 * This is an additive, self-contained module (not part of upstream Mumla logic):
 * MumlaService creates/starts it on connect and stops it on disconnect. It takes
 * a SINGLE GPS fix every interval and powers the GPS back down in between, so it
 * is cheap on battery — no continuous location stream. Positions are sent to a
 * Traccar server using the simple OsmAnd protocol (an HTTP request with the
 * position in the query string). No Google Play Services required: it uses the
 * Android framework LocationManager, which works on these POC radios.
 */
package se.lublin.mumla.service;

import android.content.Context;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.BatteryManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.util.Locale;

public class TraccarReporter {
    private static final String TAG = "MumlaTraccar";
    // If no fix arrives within this long, give up for this cycle so the GPS
    // engine doesn't stay powered on waiting.
    private static final long FIX_TIMEOUT_MS = 90_000L;

    private final Context mContext;
    private final LocationManager mLocationManager;
    private final Handler mHandler;
    private final String mDeviceId;
    private final String mHost;
    private final int mPort;
    private final long mIntervalMs;

    private boolean mRunning;
    private LocationListener mListener;
    // Current Mumble channel name, attached to each report (set from MumlaService).
    private volatile String mChannel;

    public TraccarReporter(Context ctx, String deviceId, String host, int port, long intervalMs) {
        mContext = ctx.getApplicationContext();
        mLocationManager = (LocationManager) mContext.getSystemService(Context.LOCATION_SERVICE);
        mHandler = new Handler(Looper.getMainLooper());
        mDeviceId = deviceId;
        mHost = host;
        mPort = port;
        mIntervalMs = intervalMs;
    }

    /** Set the current Mumble channel name to attach to subsequent reports (may be null). */
    public void setChannel(String channel) {
        mChannel = channel;
    }

    public void start() {
        if (mRunning || mLocationManager == null) return;
        if (mHost == null || mHost.isEmpty() || mDeviceId == null || mDeviceId.isEmpty()) return;
        mRunning = true;
        Log.i(TAG, "start id=" + mDeviceId + " -> " + mHost + ":" + mPort
                + " every " + (mIntervalMs / 1000) + "s");
        mHandler.post(mCycle);
    }

    public void stop() {
        if (!mRunning) return;
        mRunning = false;
        mHandler.removeCallbacks(mCycle);
        mHandler.removeCallbacks(mTimeout);
        removeListener();
        Log.i(TAG, "stop");
    }

    private final Runnable mCycle = new Runnable() {
        @Override
        public void run() {
            if (!mRunning) return;
            requestSingleFix();
            mHandler.postDelayed(this, mIntervalMs); // schedule the next cycle
        }
    };

    private final Runnable mTimeout = new Runnable() {
        @Override
        public void run() {
            // No fix this cycle — stop listening so the GPS can power down.
            removeListener();
        }
    };

    private void requestSingleFix() {
        try {
            removeListener();
            String provider = LocationManager.GPS_PROVIDER;
            if (!mLocationManager.isProviderEnabled(provider)
                    && mLocationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                provider = LocationManager.NETWORK_PROVIDER;
            }
            mListener = new LocationListener() {
                @Override
                public void onLocationChanged(Location location) {
                    mHandler.removeCallbacks(mTimeout);
                    removeListener();
                    send(location);
                }
                @Override public void onStatusChanged(String p, int s, Bundle extras) {}
                @Override public void onProviderEnabled(String p) {}
                @Override public void onProviderDisabled(String p) {}
            };
            mLocationManager.requestLocationUpdates(provider, 0L, 0f, mListener, Looper.getMainLooper());
            mHandler.postDelayed(mTimeout, FIX_TIMEOUT_MS);
        } catch (SecurityException e) {
            Log.w(TAG, "ACCESS_FINE_LOCATION not granted — stopping", e);
            stop();
        } catch (Exception e) {
            Log.w(TAG, "requestSingleFix failed: " + e.getMessage());
        }
    }

    private void removeListener() {
        if (mListener != null) {
            try {
                mLocationManager.removeUpdates(mListener);
            } catch (Exception ignored) {
            }
            mListener = null;
        }
    }

    private void send(final Location loc) {
        final int batt = batteryPercent();
        new Thread(new Runnable() {
            @Override
            public void run() {
                HttpURLConnection c = null;
                try {
                    // OsmAnd protocol: position in the query string.
                    String url = String.format(Locale.US,
                            "http://%s:%d/?id=%s&lat=%f&lon=%f&timestamp=%d"
                                    + "&speed=%f&bearing=%f&altitude=%f&batt=%d",
                            mHost, mPort, mDeviceId,
                            loc.getLatitude(), loc.getLongitude(),
                            loc.getTime() / 1000L,
                            loc.getSpeed() * 1.943844, // m/s -> knots (Traccar expects knots)
                            loc.getBearing(), loc.getAltitude(), batt);
                    // Attach the current Mumble channel as a Traccar attribute (if any).
                    String channel = mChannel;
                    if (channel != null && !channel.isEmpty()) {
                        url += "&channel=" + URLEncoder.encode(channel, "UTF-8");
                    }
                    c = (HttpURLConnection) new URL(url).openConnection();
                    c.setConnectTimeout(15000);
                    c.setReadTimeout(15000);
                    c.setRequestMethod("POST"); // OsmAnd accepts GET/POST; body stays empty
                    int code = c.getResponseCode();
                    Log.i(TAG, String.format(Locale.US, "sent %.5f,%.5f http %d",
                            loc.getLatitude(), loc.getLongitude(), code));
                } catch (Exception e) {
                    Log.w(TAG, "send failed: " + e.getMessage());
                } finally {
                    if (c != null) c.disconnect();
                }
            }
        }, "traccar-send").start();
    }

    private int batteryPercent() {
        try {
            BatteryManager bm = (BatteryManager) mContext.getSystemService(Context.BATTERY_SERVICE);
            if (bm != null) {
                int p = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY);
                if (p > 0) return p;
            }
        } catch (Exception ignored) {
        }
        return 0;
    }
}
