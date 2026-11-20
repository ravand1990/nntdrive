package dev.nntdrive.nntdrive

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyfileEnvelopeTest {
    private val iv = ByteArray(KeyfileEnvelope.IV_BYTES) { it.toByte() }

    @Test
    fun `entry names become safe aliases`() {
        assertEquals("nntdrive.keyfile.keyfile", KeyfileEnvelope.alias("keyfile"))
        assertEquals(
            "nntdrive.keyfile.account_1_keyfile",
            KeyfileEnvelope.alias("account/1 keyfile"),
        )
        assertEquals("nntdrive.keyfile._", KeyfileEnvelope.alias(""))
        assertEquals("entry_keyfile", KeyfileEnvelope.prefsEntry("keyfile"))
        // Different accounts must never share one Keystore key.
        assertNotEquals(
            KeyfileEnvelope.alias("account-1"),
            KeyfileEnvelope.alias("account-2"),
        )
    }

    @Test
    fun `long entry names are bounded`() {
        val alias = KeyfileEnvelope.alias("k".repeat(500))
        assertEquals(
            "nntdrive.keyfile.".length + KeyfileEnvelope.MAX_KEY_LENGTH,
            alias.length,
        )
        assertEquals(
            "entry_".length + KeyfileEnvelope.MAX_KEY_LENGTH,
            KeyfileEnvelope.prefsEntry("k".repeat(500)).length,
        )
    }

    @Test
    fun `pack and unpack round trip`() {
        val ciphertext = ByteArray(32) { (it * 3).toByte() }
        val packed = KeyfileEnvelope.pack(iv, ciphertext)
        val unpacked = KeyfileEnvelope.unpack(packed)
        assertTrue(unpacked != null)
        assertArrayEquals(iv, unpacked!!.first)
        assertArrayEquals(ciphertext, unpacked.second)
    }

    @Test
    fun `only one exact record layout is accepted`() {
        val ciphertext = ByteArray(16) { 1 }
        val packed = KeyfileEnvelope.pack(iv, ciphertext)

        assertNull("empty", KeyfileEnvelope.unpack(ByteArray(0)))
        // Fewer bytes than header + IV + one ciphertext byte.
        assertNull(
            "truncated",
            KeyfileEnvelope.unpack(packed.copyOf(KeyfileEnvelope.IV_BYTES)),
        )
        assertNull(
            "future version",
            KeyfileEnvelope.unpack(packed.clone().also { it[0] = 2 }),
        )
        assertNull(
            "wrong iv length",
            KeyfileEnvelope.unpack(packed.clone().also { it[1] = 8 }),
        )
        // Header without any ciphertext byte is not a stored value.
        assertNull(KeyfileEnvelope.unpack(packed.copyOf(2 + KeyfileEnvelope.IV_BYTES)))
    }

    @Test
    fun `packing refuses a wrong iv or empty ciphertext`() {
        assertFalse(
            runCatching { KeyfileEnvelope.pack(ByteArray(8), ByteArray(16)) }.isSuccess,
        )
        assertFalse(
            runCatching { KeyfileEnvelope.pack(iv, ByteArray(0)) }.isSuccess,
        )
    }
}
