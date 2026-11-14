package dev.nntdrive.nntdrive

/**
 * Plain decision table for storage permission outcomes.
 *
 * Kept free of Android framework calls so the branches can be unit-tested
 * without a device. The caller supplies whether access is granted, whether a
 * prompt was already shown, and whether the OS still offers a rationale.
 */
object StoragePermissionDecision {
    const val GRANTED = "granted"
    const val DENIED = "denied"
    const val PERMANENTLY_DENIED = "permanently_denied"
    const val SETTINGS_REQUIRED = "settings_required"

    /**
     * All-files access (API 30+) has no runtime dialog: the user toggles it in
     * system settings, so a refusal always needs the Settings link and must
     * never be turned into another automatic prompt.
     */
    fun afterRequest(
        sdkInt: Int,
        granted: Boolean,
        askedBefore: Boolean,
        showRationale: Boolean,
    ): String = when {
        granted -> GRANTED
        sdkInt >= 30 -> SETTINGS_REQUIRED
        // A legacy runtime permission is permanently denied only once a prompt
        // was shown and the OS no longer offers a rationale for it.
        askedBefore && !showRationale -> PERMANENTLY_DENIED
        else -> DENIED
    }

    /** True when the only remaining way to grant access is system settings. */
    fun needsSettings(outcome: String): Boolean =
        outcome == PERMANENTLY_DENIED || outcome == SETTINGS_REQUIRED
}
