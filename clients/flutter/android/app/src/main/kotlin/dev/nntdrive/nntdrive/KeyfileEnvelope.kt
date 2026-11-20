package dev.nntdrive.nntdrive

/**
 * Pure record handling for the Keystore-encrypted keyfile copy.
 *
 * A stored record is `version (1 byte) | iv length (1 byte) | iv | ciphertext`,
 * where the ciphertext includes the GCM tag. The bytes are base64-encoded before
 * they reach shared preferences, so the on-disk value is never the keyfile JSON.
 * Kept free of Android types so JVM unit tests can prove the validation rules.
 */
object KeyfileEnvelope {
    /** Private preference file; separate from the legacy `keyfile` entry. */
    const val PREFS_NAME = "nntdrive_secure_credentials"

    const val VERSION: Int = 1
    const val IV_BYTES: Int = 12
    const val GCM_TAG_BITS: Int = 128
    const val MAX_KEY_LENGTH: Int = 48

    private const val ALIAS_PREFIX = "nntdrive.keyfile."
    private val UNSAFE = Regex("[^A-Za-z0-9._-]")

    /** Keystore alias for one credential entry. Never derived from a value. */
    fun alias(key: String): String = ALIAS_PREFIX + sanitize(key)

    /** Preference entry for one credential entry. */
    fun prefsEntry(key: String): String = "entry_" + sanitize(key)

    /**
     * Keeps an entry name usable as a Keystore alias and preference key: only
     * letters, digits, dot, dash and underscore survive, bounded in length.
     * A value-free name is replaced rather than producing an empty alias.
     */
    fun sanitize(key: String): String {
        val cleaned = UNSAFE.replace(key, "_").take(MAX_KEY_LENGTH)
        return cleaned.ifEmpty { "_" }
    }

    /** Packs an IV and GCM ciphertext (tag included) into the stored layout. */
    fun pack(iv: ByteArray, ciphertext: ByteArray): ByteArray {
        require(iv.size == IV_BYTES) { "GCM IV must be $IV_BYTES bytes" }
        require(ciphertext.isNotEmpty()) { "ciphertext must not be empty" }
        val out = ByteArray(2 + iv.size + ciphertext.size)
        out[0] = VERSION.toByte()
        out[1] = iv.size.toByte()
        iv.copyInto(out, destinationOffset = 2)
        ciphertext.copyInto(out, destinationOffset = 2 + iv.size)
        return out
    }

    /**
     * Unpacks a stored record. Returns null for anything that is not exactly one
     * of our records: a future version, a wrong IV length, or a truncated value.
     */
    fun unpack(record: ByteArray): Pair<ByteArray, ByteArray>? {
        if (record.size < 2 + IV_BYTES + 1) return null
        if (record[0].toInt() != VERSION) return null
        val ivLength = record[1].toInt()
        if (ivLength != IV_BYTES) return null
        val iv = record.copyOfRange(2, 2 + ivLength)
        val ciphertext = record.copyOfRange(2 + ivLength, record.size)
        if (ciphertext.isEmpty()) return null
        return iv to ciphertext
    }
}
