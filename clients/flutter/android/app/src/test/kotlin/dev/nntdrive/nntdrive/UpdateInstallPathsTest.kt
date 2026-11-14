package dev.nntdrive.nntdrive

import java.io.File
import java.security.MessageDigest
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class UpdateInstallPathsTest {
    private lateinit var cache: File
    private lateinit var outside: File

    @Before
    fun setUp() {
        cache = File(System.getProperty("java.io.tmpdir"), "nntdrive-cache-${System.nanoTime()}")
        outside = File(System.getProperty("java.io.tmpdir"), "nntdrive-outside-${System.nanoTime()}")
        cache.mkdirs()
        outside.mkdirs()
    }

    @After
    fun tearDown() {
        cache.deleteRecursively()
        outside.deleteRecursively()
    }

    private fun staged(name: String = "nntdrive.apk", content: String = "package"): File =
        File(cache, name).apply { writeText(content) }

    @Test
    fun `a regular apk inside the cache is staged`() {
        assertTrue(UpdateInstallPaths.isStagedPackage(staged(), cache))
    }

    @Test
    fun `paths outside the cache or with another extension are refused`() {
        val externalApk = File(outside, "nntdrive.apk").apply { writeText("package") }
        assertFalse(UpdateInstallPaths.isStagedPackage(externalApk, cache))
        assertFalse(UpdateInstallPaths.isStagedPackage(staged("nntdrive.zip"), cache))
        assertFalse(UpdateInstallPaths.isStagedPackage(File(cache, "missing.apk"), cache))
        // A sibling directory sharing the cache prefix is not inside it.
        val sibling = File("${cache.path}-other")
        sibling.mkdirs()
        try {
            val apk = File(sibling, "nntdrive.apk").apply { writeText("package") }
            assertFalse(UpdateInstallPaths.isStagedPackage(apk, cache))
        } finally {
            sibling.deleteRecursively()
        }
    }

    @Test
    fun `matching sha256 is required`() {
        val apk = staged(content = "verified-bytes")
        val digest = MessageDigest.getInstance("SHA-256")
            .digest("verified-bytes".toByteArray())
            .joinToString("") { "%02x".format(it) }
        assertTrue(UpdateInstallPaths.matchesSha256(apk, digest))
        assertTrue(UpdateInstallPaths.matchesSha256(apk, digest.uppercase()))
        assertFalse(UpdateInstallPaths.matchesSha256(apk, "0".repeat(64)))
        assertFalse(UpdateInstallPaths.matchesSha256(apk, ""))
        assertFalse(UpdateInstallPaths.matchesSha256(apk, "not-a-digest"))
        assertFalse(UpdateInstallPaths.matchesSha256(staged(content = "other"), digest))
    }
}
