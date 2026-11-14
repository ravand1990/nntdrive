package dev.nntdrive.nntdrive

import android.Manifest
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageInstaller
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
    private var updateChannel: MethodChannel? = null
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
        updateChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.nntdrive/update_install",
        ).also { it.setMethodCallHandler(::handleUpdateInstall) }
    }

    /**
     * The staged package and its checksum arrive from the Flutter layer; both are
     * re-validated here (cache confinement plus a fresh digest) before Android is
     * asked to install anything. Success means the installer session was
     * committed, not that the user finished the upgrade.
     */
    private fun handleUpdateInstall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "readiness" -> result.success(
                    mapOf(
                        "supported" to (Build.VERSION.SDK_INT >= UpdateInstallDecision.MIN_SDK),
                        "canRequestPackageInstalls" to canRequestPackageInstalls(),
                        "sdkInt" to Build.VERSION.SDK_INT,
                    ),
                )
                "openSettings" -> {
                    // Only reached from an explicit user action on the permission note.
                    startActivity(installSettingsIntent())
                    result.success(true)
                }
                "install" -> {
                    val arguments = call.arguments as? Map<*, *>
                    result.success(
                        startPackageInstall(
                            path = arguments?.get("path") as? String ?: "",
                            expectedSha256 = arguments?.get("sha256") as? String ?: "",
                        ),
                    )
                }
                else -> result.notImplemented()
            }
        } catch (_: ActivityNotFoundException) {
            result.error("settings_unavailable", "Android settings could not be opened.", null)
        } catch (_: SecurityException) {
            result.error("install_unavailable", "Android refused the app update.", null)
        } catch (_: IOException) {
            result.error("install_unavailable", "The downloaded package could not be read.", null)
        } catch (_: IllegalArgumentException) {
            result.error("install_unavailable", "The downloaded package could not be used.", null)
        }
    }

    private fun canRequestPackageInstalls(): Boolean = when {
        // Before Android 8 the switch is device-wide, so there is nothing to
        // read per app.
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> packageManager.canRequestPackageInstalls()
        else -> true
    }

    private fun installSettingsIntent(): Intent =
        if (UpdateInstallDecision.hasPerAppInstallSwitch(Build.VERSION.SDK_INT)) {
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            )
        } else {
            // Before Android 8 the switch is device-wide.
            Intent(Settings.ACTION_SECURITY_SETTINGS)
        }

    private fun startPackageInstall(path: String, expectedSha256: String): Map<String, Any> {
        val candidate = File(path)
        val outcome = UpdateInstallDecision.decide(
            sdkInt = Build.VERSION.SDK_INT,
            checksumVerified = UpdateInstallPaths.matchesSha256(candidate, expectedSha256),
            packageStaged = UpdateInstallPaths.isStagedPackage(candidate, cacheDir),
            canRequestPackageInstalls = canRequestPackageInstalls(),
        )
        return when (outcome) {
            UpdateInstallDecision.READY -> {
                commitInstallerSession(candidate)
                mapOf("started" to true, "needsPermission" to false, "outcome" to outcome)
            }
            UpdateInstallDecision.PERMISSION_REQUIRED ->
                mapOf("started" to false, "needsPermission" to true, "outcome" to outcome)
            else ->
                mapOf("started" to false, "needsPermission" to false, "outcome" to outcome)
        }
    }

    private fun commitInstallerSession(apk: File) {
        val installer = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(packageName)
        val sessionId = installer.createSession(params)
        installer.openSession(sessionId).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("nntdrive-update.apk", 0, apk.length()).use { output ->
                    input.copyTo(output)
                    session.fsync(output)
                }
            }
            val statusIntent = Intent(this, UpdateInstallReceiver::class.java)
                .setAction(UpdateInstallReceiver.ACTION_INSTALL_STATUS)
                .setPackage(packageName)
            // Android 12+ requires an explicit mutability flag; the installer
            // fills in the status extras.
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
            session.commit(
                PendingIntent.getBroadcast(this, sessionId, statusIntent, flags).intentSender,
            )
        }
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
                "openSettings" -> {
                    // Only reached from an explicit user action on a denial.
                    startActivity(
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:$packageName"),
                        ),
                    )
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (_: IllegalArgumentException) {
            result.error("invalid_path", "An absolute filesystem directory path is required.", null)
        } catch (_: IOException) {
            result.error("storage_unavailable", "Storage access could not be checked.", null)
        } catch (_: SecurityException) {
            result.error("storage_unavailable", "Storage access could not be checked.", null)
        } catch (_: ActivityNotFoundException) {
            result.error("settings_unavailable", "System settings could not be opened.", null)
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
            pendingStorageRequest = result
            completeStorageRequest(false)
            return
        }
        if (hasSharedAccess()) {
            pendingStorageRequest = result
            completeStorageRequest(true)
            return
        }
        // A permanently denied runtime permission would ignore another prompt,
        // so report the Settings path instead of asking (and looping) again.
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.R &&
            permissionAsked() &&
            !hasRationale()
        ) {
            pendingStorageRequest = result
            storageRequestActive = true
            completeStorageRequest(false)
            return
        }
        pendingStorageRequest = result
        storageRequestActive = true
        markPermissionAsked()
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

    private fun hasRationale(): Boolean = when {
        // Runtime permissions and their rationale only exist from API 23.
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M -> false
        else -> try {
            shouldShowRequestPermissionRationale(Manifest.permission.READ_EXTERNAL_STORAGE)
        } catch (_: SecurityException) {
            false
        }
    }

    private fun permissionAsked(): Boolean =
        getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(KEY_PERMISSION_ASKED, false)

    private fun markPermissionAsked() {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putBoolean(KEY_PERMISSION_ASKED, true).apply()
    }

    private fun completeStorageRequest(granted: Boolean, clearAdmission: Boolean = true) {
        if (clearAdmission) storageRequestActive = false
        val result = pendingStorageRequest ?: return
        pendingStorageRequest = null
        // Report why access was refused so the client can offer the Settings
        // link only when another prompt cannot work.
        result.success(
            mapOf(
                "granted" to granted,
                "outcome" to StoragePermissionDecision.afterRequest(
                    sdkInt = Build.VERSION.SDK_INT,
                    granted = granted,
                    askedBefore = permissionAsked(),
                    showRationale = hasRationale(),
                ),
            ),
        )
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
        disposeUpdateInstall()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        disposeStorageAccess()
        disposeUpdateInstall()
        super.onDestroy()
    }

    private fun disposeUpdateInstall() {
        updateChannel?.setMethodCallHandler(null)
        updateChannel = null
    }

    private companion object {
        const val STORAGE_SETTINGS_REQUEST = 6901
        const val STORAGE_LEGACY_REQUEST = 6902
        const val PREFS = "storage_access"
        const val KEY_PERMISSION_ASKED = "permission_asked"
    }
}
