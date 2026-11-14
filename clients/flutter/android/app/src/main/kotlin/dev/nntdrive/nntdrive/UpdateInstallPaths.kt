package dev.nntdrive.nntdrive

import java.io.File
import java.io.IOException
import java.security.MessageDigest

/**
 * Confines the staged download to this app's cache directory and re-checks the
 * published checksum on the Android side.
 *
 * The Flutter layer already verified the download; repeating the digest here
 * keeps the decision honest even if the path is substituted between download
 * and install.
 */
object UpdateInstallPaths {
    /**
     * A staged package must be a regular file inside the cache directory whose
     * canonical path stays there. Canonicalisation resolves links, so a symlink
     * pointing outside is rejected.
     */
    fun isStagedPackage(candidate: File, cacheDir: File): Boolean {
        if (!candidate.name.endsWith(".apk")) return false
        if (!candidate.isFile) return false
        val path = canonical(candidate) ?: return false
        val cache = canonical(cacheDir) ?: return false
        return path.startsWith(cache.trimEnd(File.separatorChar) + File.separator)
    }

    /** True only when [expectedSha256] is a hex digest equal to the file's. */
    fun matchesSha256(candidate: File, expectedSha256: String): Boolean {
        val expected = expectedSha256.trim().lowercase()
        if (!HEX_SHA256.matches(expected)) return false
        if (!candidate.isFile) return false
        val actual = try {
            digest(candidate)
        } catch (_: IOException) {
            return null
        } ?: return false
        return actual == expected
    }

    private fun digest(file: File): String? {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                md.update(buffer, 0, read)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun canonical(file: File): String? = try {
        file.canonicalPath
    } catch (_: IOException) {
        null
    }

    private val HEX_SHA256 = Regex("^[a-f0-9]{64}$")
}
