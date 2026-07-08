"""
Manifest of the 5 packageable Android (Element) bugs, sourced from bm_instrument/README.md's
per-bug version/commit table and `element-bugs/<bug>/round*/` folder listings.

Unlike the server-side manifest, there's no per-bug software *version* matrix to build — every bug
shares the same offline dex2jar+CommandLine toolchain (android-common/); what varies per bug is
the target APK, the element-android branch/commit it was built from, and its round plans.
"""

BUGS = [
    dict(
        id="element-516",
        title="Sent message not removed from local cache",
        folder="element516",
        branch="516",
        commit="2c2cd47993",
        element_version="1.6.8",
        rounds=[1, 2],
        apk="results/vector-gplay-arm64-v8a-debug.apk",
        package="im.vector.app.debug",
        symptom_class="org.matrix.android.sdk.internal.session.sync.handler.room.RoomSyncHandler",
        symptom_method="deleteLocalEchosIfNeeded",
    ),
    dict(
        id="element-5038",
        title="Notifications updated faster than database",
        folder="element5038",
        branch="5038",
        commit="b4078012e4",
        element_version="1.6.8",
        rounds=[1, 2, 3, 4],
        apk="results/vector-gplay-arm64-v8a-debug.apk",
        package="im.vector.app.debug",
        symptom_class="im.vector.app.features.notifications.NotifiableEventProcessor",
        symptom_method="process",
        notes="Results-table issue number is **5132** (the upstream PR that got reverted to cause "
              "this bug) — the bug/branch/folder are all '5038'. Don't go looking for 'element5132'.",
    ),
    dict(
        id="element-6782",
        title="Foreground service not restarted",
        folder="element6782",
        branch="6782",
        commit="42d29da3a6",
        element_version="1.4.34",
        rounds=[1, 2],
        apk="results/vector-gplay-arm64-v8a-debug.apk",
        package="im.vector.app.debug",
        symptom_class="im.vector.app.core.di.ActiveSessionHolder",
        symptom_method="getOrInitializeSession",
    ),
    dict(
        id="element-7516",
        title="Connection failure to old server version",
        folder="element7516",
        branch="7516",
        commit="9db0a10a8a",
        element_version="1.5.6",
        rounds=[1, 2],
        apk="results/vector-gplay-arm64-v8a-debug.apk",
        package="im.vector.app.debug",
        symptom_class="org.matrix.android.sdk.internal.session.sync.DefaultSyncTask",
        symptom_method="downloadInitSyncResponse",
    ),
    dict(
        id="element-7643",
        title="Notifications are automatically dismissed",
        folder="element7643",
        branch="7643",
        commit="adaf68eb7c",
        element_version="1.6.8",
        rounds=[1, 2, 3, 5, 7, 9],  # NB: non-consecutive, no round 4/6/8
        apk="results/vector-gplay-arm64-v8a-debug.apk",
        package="im.vector.app.debug",
        symptom_class="im.vector.app.features.notifications.NotifiableEventProcessor",
        symptom_method="process",
        notes="Round numbers are non-consecutive (1,2,3,5,7,9 — no 4/6/8) — this is copied "
              "verbatim from the checked-in round* folders, not an error.",
    ),
]

# element2143 (Background service killed by Android): README states explicitly this bug is
# "— (not in this repo)" — no folder, no APK, nothing to package.
UNPACKAGEABLE = [
    dict(id="element-2143", jira="2143", title="Background service killed by Android",
         reason="Det=Y, Succ=N — explicitly noted in bm_instrument/README.md as 'not in this repo'; "
                "no folder, no APK, no plans exist anywhere in this checkout."),
]
