package dev.nntdrive.nntdrive

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Keeps the password-wrapped keyfile encrypted at rest under a key that never
 * leaves the Android Keystore.
 *
 * The value stored here is already password-wrapped (Argon2id + XChaCha20) by
 * the client; encrypting it again means a device backup or a rooted dump of the
 * preference file yields ciphertext that only this app's Keystore entry can
 * open. The AES key is generated on first write, bound to this app, and is not
 * exportable.
 *
 * Every call may touch the Keystore, which is slow and can block, so callers
 * must run these methods off the UI thread.
 */
class KeyfileCredentialStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(
        KeyfileEnvelope.PREFS_NAME,
        Context.MODE_PRIVATE,
    )

    /** Returns the stored value, or null when nothing is stored for [key]. */
    fun read(key: String): String? {
        val record = prefs.getString(KeyfileEnvelope.prefsEntry(key), null) ?: return null
        val bytes = try {
            Base64.decode(record, Base64.NO_WRAP)
        } catch (_: IllegalArgumentException) {
            throw KeyfileStoreException("stored record is not readable")
        }
        val unpacked = KeyfileEnvelope.unpack(bytes)
            ?: throw KeyfileStoreException("stored record is not readable")
        val (iv, ciphertext) = unpacked
        val plain = try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                existingKey(key),
                GCMParameterSpec(KeyfileEnvelope.GCM_TAG_BITS, iv),
            )
            cipher.doFinal(ciphertext)
        } catch (e: Exception) {
            throw KeyfileStoreException("stored keyfile could not be opened")
        }
        return String(plain, Charsets.UTF_8)
    }

    /** Stores [value] under [key], replacing an existing entry. */
    fun write(key: String, value: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, orCreateKey(key))
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val record = Base64.encodeToString(
            KeyfileEnvelope.pack(cipher.iv, ciphertext),
            Base64.NO_WRAP,
        )
        // commit() rather than apply(): the Dart layer reads the value back
        // immediately to prove the store kept it.
        val stored = prefs.edit().putString(KeyfileEnvelope.prefsEntry(key), record).commit()
        if (!stored) throw KeyfileStoreException("preference file rejected the record")
    }

    /** Removes the entry for [key]; missing entries are not an error. */
    fun delete(key: String) {
        prefs.edit().remove(KeyfileEnvelope.prefsEntry(key)).commit()
        try {
            keyStore().deleteEntry(KeyfileEnvelope.alias(key))
        } catch (_: Exception) {
            // A missing or unreadable alias is already the desired state; the
            // preference entry above is what holds the ciphertext.
        }
    }

    private fun orCreateKey(entry: String): SecretKey {
        val alias = KeyfileEnvelope.alias(entry)
        (keyStore().getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private fun existingKey(entry: String): SecretKey {
        val alias = KeyfileEnvelope.alias(entry)
        val stored = keyStore().getEntry(alias, null) as? KeyStore.SecretKeyEntry
            ?: throw KeyfileStoreException("keystore entry is missing")
        return stored.secretKey
    }

    private fun keyStore(): KeyStore =
        KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}

/** Raised when the Keystore store cannot serve a request. Never carries values. */
class KeyfileStoreException(message: String) : Exception(message)
