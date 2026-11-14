package dev.nntdrive.nntdrive

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StoragePermissionDecisionTest {
    @Test
    fun `granted access never asks again`() {
        assertEquals(
            StoragePermissionDecision.GRANTED,
            StoragePermissionDecision.afterRequest(
                sdkInt = 29,
                granted = true,
                askedBefore = true,
                showRationale = true,
            ),
        )
        assertFalse(StoragePermissionDecision.needsSettings(StoragePermissionDecision.GRANTED))
    }

    @Test
    fun `all files access needs settings instead of another prompt`() {
        for (sdk in intArrayOf(30, 33, 35)) {
            assertEquals(
                StoragePermissionDecision.SETTINGS_REQUIRED,
                StoragePermissionDecision.afterRequest(
                    sdkInt = sdk,
                    granted = false,
                    askedBefore = false,
                    showRationale = false,
                ),
            )
        }
        assertTrue(
            StoragePermissionDecision.needsSettings(StoragePermissionDecision.SETTINGS_REQUIRED),
        )
    }

    @Test
    fun `legacy first refusal is a normal denial that may be retried`() {
        assertEquals(
            StoragePermissionDecision.DENIED,
            StoragePermissionDecision.afterRequest(
                sdkInt = 29,
                granted = false,
                askedBefore = false,
                showRationale = false,
            ),
        )
        assertEquals(
            StoragePermissionDecision.DENIED,
            StoragePermissionDecision.afterRequest(
                sdkInt = 29,
                granted = false,
                askedBefore = true,
                showRationale = true,
            ),
        )
        assertFalse(StoragePermissionDecision.needsSettings(StoragePermissionDecision.DENIED))
    }

    @Test
    fun `legacy permanent denial offers settings`() {
        assertEquals(
            StoragePermissionDecision.PERMANENTLY_DENIED,
            StoragePermissionDecision.afterRequest(
                sdkInt = 28,
                granted = false,
                askedBefore = true,
                showRationale = false,
            ),
        )
        assertTrue(
            StoragePermissionDecision.needsSettings(StoragePermissionDecision.PERMANENTLY_DENIED),
        )
    }
}
