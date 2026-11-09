package dev.nntdrive.nntdrive

import java.io.File
import java.io.IOException

/** Pure filesystem policy; no Android APIs and no path-bearing diagnostics. */
internal object StorageAccessPaths {
    fun canonicalDirectoryPath(path: String?): File {
        require(!path.isNullOrBlank() && '\u0000' !in path && File(path).isAbsolute) {
            "An absolute filesystem directory path is required."
        }
        return try {
            val directory = File(path).canonicalFile
            require(!directory.exists() || directory.isDirectory) {
                "A filesystem directory path is required."
            }
            directory
        } catch (_: IOException) {
            throw IllegalArgumentException("The filesystem path cannot be resolved.")
        } catch (_: SecurityException) {
            throw IllegalArgumentException("The filesystem path cannot be resolved.")
        }
    }

    fun isAppPrivate(path: File, privateRoots: List<File>): Boolean =
        privateRoots.any { root ->
            // Canonicalize BOTH sides: Android's /data/data and /sdcard aliases
            // must work, while a link escaping a private directory must not.
            val canonicalRoot = root.canonicalPath
            val canonicalPath = path.canonicalPath
            canonicalPath == canonicalRoot ||
                canonicalPath.startsWith(canonicalRoot.trimEnd(File.separatorChar) + File.separator)
        }
}
