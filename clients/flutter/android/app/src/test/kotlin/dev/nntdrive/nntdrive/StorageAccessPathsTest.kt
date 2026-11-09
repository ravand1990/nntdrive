package dev.nntdrive.nntdrive

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class StorageAccessPathsTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private fun isPrivate(path: File, vararg roots: File): Boolean =
        StorageAccessPaths.isAppPrivate(StorageAccessPaths.canonicalDirectoryPath(path.path), roots.toList())

    @Test
    fun recognizesEachPrivateRootAndDescendants() {
        val roots = listOf("files", "cache", "no_backup", "external_files", "external_cache")
            .map { temporary.newFolder(it) }
        roots.forEach { root ->
            assertTrue(isPrivate(root, *roots.toTypedArray()))
            assertTrue(isPrivate(File(root, "sync/nested"), *roots.toTypedArray()))
        }
    }

    @Test
    fun doesNotConfuseSiblingPrefixOrParentWithPrivateRoot() {
        val root = temporary.newFolder("files")
        assertFalse(isPrivate(temporary.newFolder("files_other"), root))
        assertFalse(isPrivate(root.parentFile, root))
        assertFalse(isPrivate(temporary.newFolder("shared"), root))
        assertFalse(isPrivate(root))
    }

    @Test
    fun canonicalizesTraversalBeforeClassifying() {
        val root = temporary.newFolder("files")
        File(root, "child").mkdir()
        assertTrue(isPrivate(File(root, "child/../sync"), root))
        assertFalse(isPrivate(File(root, "../shared"), root))
    }

    @Test
    fun escapingSymlinkIsNotPrivate() {
        val root = temporary.newFolder("files")
        val shared = temporary.newFolder("shared")
        Files.createSymbolicLink(File(root, "escape").toPath(), shared.toPath())
        assertFalse(isPrivate(File(root, "escape"), root))
        assertFalse(isPrivate(File(root, "escape/new/subdir"), root))
    }

    @Test
    fun canonicalAliasesIntoPrivateRootArePrivate() {
        val root = temporary.newFolder("files")
        val alias = File(temporary.root, "alias")
        Files.createSymbolicLink(alias.toPath(), root.toPath())
        assertTrue(isPrivate(File(alias, "sync"), root))
        assertTrue(isPrivate(File(root, "sync"), alias))
    }

    @Test
    fun siblingSymlinkDoesNotGainPrivateStatusByPrefix() {
        val root = temporary.newFolder("files")
        val sibling = temporary.newFolder("files_other")
        val alias = File(root, "escape")
        Files.createSymbolicLink(alias.toPath(), sibling.toPath())
        assertFalse(isPrivate(alias, root))
    }

    @Test
    fun rejectsAbsentBlankRelativeAndUriArguments() {
        listOf(null, "", " ", "sync", "../sync", "content://provider/tree/secret", "file:///storage/sync", "/invalid\u0000path")
            .forEach { path ->
                val error = assertThrows(IllegalArgumentException::class.java) {
                    StorageAccessPaths.canonicalDirectoryPath(path)
                }
                assertEquals("An absolute filesystem directory path is required.", error.message)
            }
    }

    @Test
    fun rejectsExistingRegularFileWithoutIncludingItsName() {
        val file = temporary.newFile("sensitive-name")
        val error = assertThrows(IllegalArgumentException::class.java) {
            StorageAccessPaths.canonicalDirectoryPath(file.path)
        }
        assertEquals("A filesystem directory path is required.", error.message)
    }

    @Test
    fun permitsNotYetCreatedDirectoriesWithoutCreatingThem() {
        val root = temporary.newFolder("files")
        val path = File(root, "sync/new directory")
        assertEquals(path.canonicalFile, StorageAccessPaths.canonicalDirectoryPath(path.path))
        assertTrue(isPrivate(path, root))
        assertFalse(path.exists())
    }

    @Test
    fun sharedStorageAliasRemainsShared() {
        val root = temporary.newFolder("files")
        val shared = temporary.newFolder("shared")
        val alias = File(temporary.root, "sdcard")
        Files.createSymbolicLink(alias.toPath(), shared.toPath())
        assertFalse(isPrivate(File(alias, "sync"), root))
    }
}
