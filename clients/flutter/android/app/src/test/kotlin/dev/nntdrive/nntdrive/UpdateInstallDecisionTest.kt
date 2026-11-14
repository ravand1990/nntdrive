package dev.nntdrive.nntdrive

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UpdateInstallDecisionTest {
    @Test
    fun `a verified staged package on a permitted device is installable`() {
        for (sdk in intArrayOf(21, 26, 30, 34, 35)) {
            assertEquals(
                UpdateInstallDecision.READY,
                UpdateInstallDecision.decide(
                    sdkInt = sdk,
                    checksumVerified = true,
                    packageStaged = true,
                    canRequestPackageInstalls = true,
                ),
            )
        }
    }

    @Test
    fun `an unverified package is refused before anything else is considered`() {
        assertEquals(
            UpdateInstallDecision.UNVERIFIED,
            UpdateInstallDecision.decide(
                sdkInt = 34,
                checksumVerified = false,
                packageStaged = true,
                canRequestPackageInstalls = true,
            ),
        )
        assertEquals(
            UpdateInstallDecision.UNVERIFIED,
            UpdateInstallDecision.decide(
                sdkInt = 34,
                checksumVerified = false,
                packageStaged = false,
                canRequestPackageInstalls = false,
            ),
        )
    }

    @Test
    fun `a package outside the cache is refused`() {
        assertEquals(
            UpdateInstallDecision.MISSING_PACKAGE,
            UpdateInstallDecision.decide(
                sdkInt = 34,
                checksumVerified = true,
                packageStaged = false,
                canRequestPackageInstalls = true,
            ),
        )
    }

    @Test
    fun `the per-app install switch is only required from Android 8`() {
        // Android 7 and older have a device-wide switch, so refusing is wrong.
        assertEquals(
            UpdateInstallDecision.READY,
            UpdateInstallDecision.decide(
                sdkInt = 25,
                checksumVerified = true,
                packageStaged = true,
                canRequestPackageInstalls = false,
            ),
        )
        for (sdk in intArrayOf(26, 30, 35)) {
            assertEquals(
                UpdateInstallDecision.PERMISSION_REQUIRED,
                UpdateInstallDecision.decide(
                    sdkInt = sdk,
                    checksumVerified = true,
                    packageStaged = true,
                    canRequestPackageInstalls = false,
                ),
            )
        }
        assertTrue(UpdateInstallDecision.needsPermission(UpdateInstallDecision.PERMISSION_REQUIRED))
        assertFalse(UpdateInstallDecision.needsPermission(UpdateInstallDecision.READY))
        assertFalse(UpdateInstallDecision.needsPermission(UpdateInstallDecision.UNVERIFIED))
    }

    @Test
    fun `Android versions without PackageInstaller are unsupported`() {
        assertEquals(
            UpdateInstallDecision.UNSUPPORTED,
            UpdateInstallDecision.decide(
                sdkInt = 20,
                checksumVerified = true,
                packageStaged = true,
                canRequestPackageInstalls = false,
            ),
        )
        assertTrue(UpdateInstallDecision.hasPerAppInstallSwitch(26))
        assertFalse(UpdateInstallDecision.hasPerAppInstallSwitch(25))
    }
}
