package dev.nntdrive.nntdrive

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {
    private var storageChannel: MethodChannel? = null
    private var pendingStorageRequest: MethodChannel.Result? = null
    // Keep OS admission separate from the engine's result lifetime: detaching
    // an engine cannot dismiss a settings screen/runtime permission dialog.
    private var storageRequestActive = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        storageChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.nntdrive/storage_access",
        ).also { it.setMethodCallHandler(::handleStorageAccess) }
    }

    private fun handleStorageAccess(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "status" -> {
                    val arguments = call.arguments as? Map<*, *>
                    val path = StorageAccessPaths.canonicalDirectoryPath(arguments?.get("path") as? String)
                    // A not-yet-created directory is valid: denied shared storage
                    // can also appear nonexistent before the explicit grant.
                    result.success(!StorageAccessPaths.isAppPrivate(path, privateRoots()) && !hasSharedAccess())
                }
                "request" -> requestSharedAccess(result)
                "privateFolder" -> {
                    // path_provider application support is filesDir. Keep user
                    // data outside filesDir/sync, which holds live journals.
                    val folder = File(filesDir, "private-sync-data")
                    if (!StorageAccessPaths.isAppPrivate(folder, listOf(filesDir)) ||
                        (!folder.isDirectory && !folder.mkdirs())) {
                        result.error("private_folder_unavailable", "The private sync folder is unavailable.", null)
                    } else {
                        result.success(folder.canonicalPath)
                    }
                }
                else -> result.notImplemented()
            }
        } catch (_: IllegalArgumentException) {
            result.error("invalid_path", "An absolute filesystem directory path is required.", null)
        } catch (_: IOException) {
            result.error("storage_unavailable", "Storage access could not be checked.", null)
        } catch (_: SecurityException) {
            result.error("storage_unavailable", "Storage access could not be checked.", null)
        }
    }

    private fun privateRoots(): List<File> = buildList {
        add(filesDir)
        add(cacheDir)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) add(noBackupFilesDir)
        addAll(getExternalFilesDirs(null).filterNotNull())
        addAll(externalCacheDirs.filterNotNull())
    }

    private fun hasSharedAccess(): Boolean = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> Environment.isExternalStorageManager()
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ->
            checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED &&
                checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        else -> true // Install-time permissions on older Android versions.
    }

    private fun requestSharedAccess(result: MethodChannel.Result) {
        if (storageRequestActive) {
            result.error("request_in_progress", "A storage access request is already in progress.", null)
            return
        }
        if (isFinishing || isDestroyed) {
            result.success(false)
            return
        }
        if (hasSharedAccess()) {
            result.success(true)
            return
        }
        pendingStorageRequest = result
        storageRequestActive = true
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // Only explicit user action reaches here. Never open the global
                // settings list as a fallback, nor infer success from resultCode.
                startActivityForResult(
                    Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                        data = Uri.parse("package:$packageName")
                    },
                    STORAGE_SETTINGS_REQUEST,
                )
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                requestPermissions(
                    arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE),
                    STORAGE_LEGACY_REQUEST,
                )
            } else {
                completeStorageRequest(true)
            }
        } catch (_: ActivityNotFoundException) {
            completeStorageRequest(false)
        } catch (_: SecurityException) {
            completeStorageRequest(false)
        }
    }

    private fun completeStorageRequest(granted: Boolean, clearAdmission: Boolean = true) {
        if (clearAdmission) storageRequestActive = false
        val result = pendingStorageRequest ?: return
        pendingStorageRequest = null
        result.success(granted)
    }

    @Deprecated("The Android settings permission screen uses the activity-result callback.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == STORAGE_SETTINGS_REQUEST) {
            // Settings commonly returns RESULT_CANCELED even after a grant.
            // A canceled/denied attempt without a grant therefore returns false.
            completeStorageRequest(hasSharedAccess())
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == STORAGE_LEGACY_REQUEST) {
            completeStorageRequest(grantResults.isNotEmpty() && hasSharedAccess())
        }
    }

    private fun disposeStorageAccess() {
        storageChannel?.setMethodCallHandler(null)
        storageChannel = null
        completeStorageRequest(false, clearAdmission = false)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        disposeStorageAccess()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        disposeStorageAccess()
        super.onDestroy()
    }

    private companion object {
        const val STORAGE_SETTINGS_REQUEST = 6901
        const val STORAGE_LEGACY_REQUEST = 6902
    }
}
