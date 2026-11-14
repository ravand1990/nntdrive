package dev.nntdrive.nntdrive

/**
 * Plain decision table for handing an APK to the Android installer.
 *
 * Free of Android framework calls so the branches can be unit-tested without a
 * device. The caller supplies whether the staged package matched its published
 * checksum, whether it is inside this app's cache, and whether Android will let
 * this app request an install.
 */
object UpdateInstallDecision {
    const val READY = "ready"
    const val PERMISSION_REQUIRED = "permission_required"
    const val UNVERIFIED = "unverified"
    const val MISSING_PACKAGE = "missing_package"
    const val UNSUPPORTED = "unsupported"

    /** PackageInstaller sessions exist from API 21. */
    const val MIN_SDK = 21

    /** Android 8 introduced the per-app "install unknown apps" switch. */
    const val PER_APP_INSTALL_SWITCH_SDK = 26

    fun decide(
        sdkInt: Int,
        checksumVerified: Boolean,
        packageStaged: Boolean,
        canRequestPackageInstalls: Boolean,
    ): String = when {
        // An unverified package never reaches the installer, whatever else is true.
        !checksumVerified -> UNVERIFIED
        !packageStaged -> MISSING_PACKAGE
        sdkInt < MIN_SDK -> UNSUPPORTED
        // Before Android 8 "unknown sources" is a device-wide setting with no
        // per-app switch, so there is nothing to check here.
        sdkInt >= PER_APP_INSTALL_SWITCH_SDK && !canRequestPackageInstalls ->
            PERMISSION_REQUIRED
        else -> READY
    }

    /** True when the only remaining step is the user enabling the app's switch. */
    fun needsPermission(outcome: String): Boolean = outcome == PERMISSION_REQUIRED

    /** True when the OS exposes a per-app install switch worth opening. */
    fun hasPerAppInstallSwitch(sdkInt: Int): Boolean =
        sdkInt >= PER_APP_INSTALL_SWITCH_SDK
}
