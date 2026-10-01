package se.lublin.mumla.preference;

import android.os.Bundle;
import se.lublin.mumla.R;

/** GPS -> Traccar position-reporting settings (additive to upstream Mumla). */
public class TrackingSettingsFragment extends MumlaPreferenceFragment {
    @Override
    public void onCreatePreferences(Bundle savedInstanceState, String rootKey) {
        setPreferencesFromResource(R.xml.settings_tracking, rootKey);
    }
}
