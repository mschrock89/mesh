package com.mitchellschrock.mesh

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.FileProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

private const val APK_NAME = "Mesh.apk"

private data class AndroidRelease(val commit: String, val assetID: Long)

class AppUpdateController(private val activity: Activity) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val preferences = activity.getSharedPreferences("mesh-update", Activity.MODE_PRIVATE)
    private var release: AndroidRelease? = null
    private var pendingAPK: File? = null
    private var installRequested = false

    var statusText by mutableStateOf("Installed ${short(BuildConfig.MESH_COMMIT)}")
        private set
    var buttonTitle by mutableStateOf("Check for Updates")
        private set
    var tokenDraft by mutableStateOf("")
    var askingForToken by mutableStateOf(false)
        private set
    var isBusy by mutableStateOf(false)
        private set
    var canInstall by mutableStateOf(false)
        private set
    var failed by mutableStateOf(false)
        private set

    fun refreshOnOpen() {
        if (!isBusy && !askingForToken) check(interactive = false)
    }

    fun perform() {
        if (isBusy) return
        if (askingForToken) {
            val token = normalizeToken(tokenDraft)
            if (token.isEmpty()) return
            preferences.edit().putString("github-token", token).apply()
            tokenDraft = ""
            askingForToken = false
            check(interactive = true)
        } else if (canInstall) {
            install()
        } else {
            check(interactive = true)
        }
    }

    fun onResume() {
        if (installRequested && activity.packageManager.canRequestPackageInstalls()) {
            installRequested = false
            pendingAPK?.let(::openInstaller)
        }
    }

    fun close() {
        scope.cancel()
    }

    private fun check(interactive: Boolean) {
        isBusy = true
        failed = false
        if (interactive) {
            statusText = "Checking GitHub…"
            buttonTitle = "Checking…"
        }
        scope.launch {
            try {
                val found = withContext(Dispatchers.IO) {
                    GitHubAndroidClient(savedToken()).latestRelease()
                }
                val relation = withContext(Dispatchers.IO) {
                    relationTo(found.commit, savedToken())
                }
                when (relation) {
                    "same" -> {
                        release = null
                        canInstall = false
                        statusText = "Up to date · ${short(BuildConfig.MESH_COMMIT)}"
                    }
                    "newer" -> {
                        release = null
                        canInstall = false
                        statusText = "Installed ${short(BuildConfig.MESH_COMMIT)} is newer than the published update."
                    }
                    "missing" -> {
                        release = null
                        canInstall = false
                        statusText = "Push this install to GitHub before it can be compared."
                    }
                    else -> {
                        release = found
                        canInstall = true
                        statusText = "Update ready · ${short(found.commit)}"
                    }
                }
                buttonTitle = if (canInstall) "Install Update" else "Check for Updates"
            } catch (error: UpdateFailure) {
                if (error.needsToken) {
                    askingForToken = true
                    statusText = if (savedToken().isEmpty()) {
                        "Paste a GitHub token that can read ${BuildConfig.MESH_REPO}. It stays on this Android."
                    } else {
                        "GitHub rejected that token. Paste one that can read ${BuildConfig.MESH_REPO}."
                    }
                } else if (interactive) {
                    failed = true
                    statusText = error.message ?: "Mesh couldn't reach GitHub."
                }
                buttonTitle = "Check for Updates"
            } catch (_: Exception) {
                if (interactive) {
                    failed = true
                    statusText = "Mesh couldn't reach GitHub."
                }
                buttonTitle = "Check for Updates"
            } finally {
                isBusy = false
            }
        }
    }

    private suspend fun relationTo(remote: String, token: String): String {
        val local = normalize(BuildConfig.MESH_COMMIT)
        if (local == remote) return "same"
        if (local.isEmpty() || local == "unknown") return "update"
        return when (GitHubAndroidClient(token).compare(local, remote)) {
            "identical" -> "same"
            "behind" -> "newer"
            "ahead", "diverged" -> "update"
            else -> "missing"
        }
    }

    private fun install() {
        val found = release ?: return
        isBusy = true
        failed = false
        buttonTitle = "Installing…"
        statusText = "Downloading the published update…"
        scope.launch {
            try {
                val apk = withContext(Dispatchers.IO) {
                    GitHubAndroidClient(savedToken()).download(found.assetID, activity.cacheDir)
                }
                pendingAPK = apk
                if (activity.packageManager.canRequestPackageInstalls()) {
                    openInstaller(apk)
                } else {
                    installRequested = true
                    statusText = "Allow Mesh to install updates, then return here."
                    activity.startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:${activity.packageName}")
                        )
                    )
                }
            } catch (error: UpdateFailure) {
                failed = true
                statusText = error.message ?: "Mesh couldn't install the update."
            } catch (_: Exception) {
                failed = true
                statusText = "Mesh couldn't install the update."
            } finally {
                isBusy = false
                buttonTitle = if (canInstall) "Install Update" else "Check for Updates"
            }
        }
    }

    private fun openInstaller(apk: File) {
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", apk)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        activity.startActivity(intent)
        statusText = "Finish installing the update in Android."
    }

    private fun savedToken(): String = normalizeToken(preferences.getString("github-token", "") ?: "")

    private fun short(commit: String): String {
        val value = normalize(commit)
        return if (value.isEmpty() || value == "unknown") "unknown" else value.take(7)
    }
}

private class UpdateFailure(message: String, val needsToken: Boolean = false) : Exception(message)

private class GitHubAndroidClient(private val token: String) {
    fun latestRelease(): AndroidRelease {
        val response = request("/repos/${BuildConfig.MESH_REPO}/releases/latest")
        if (response.code == 401 || response.code == 403 || response.code == 404) {
            throw UpdateFailure("GitHub couldn't open the Mesh releases.", needsToken = true)
        }
        if (response.code != 200) throw UpdateFailure("Mesh couldn't read the update list.")
        val json = JSONObject(response.body)
        val tag = normalize(json.getString("tag_name")).removePrefix("mesh-")
        val assets = json.getJSONArray("assets")
        for (index in 0 until assets.length()) {
            val asset = assets.getJSONObject(index)
            if (asset.getString("name") == APK_NAME) {
                return AndroidRelease(tag, asset.getLong("id"))
            }
        }
        throw UpdateFailure("The published update is missing $APK_NAME.")
    }

    fun compare(local: String, remote: String): String? {
        val response = request("/repos/${BuildConfig.MESH_REPO}/compare/$local...$remote")
        if (response.code == 404) return null
        if (response.code != 200) throw UpdateFailure("Mesh couldn't compare this copy with GitHub.")
        return JSONObject(response.body).optString("status").ifEmpty { null }
    }

    fun download(assetID: Long, cache: File): File {
        val directory = File(cache, "updates").apply { mkdirs() }
        val destination = File(directory, APK_NAME)
        val connection = open(
            URL("https://api.github.com/repos/${BuildConfig.MESH_REPO}/releases/assets/$assetID"),
            "application/octet-stream"
        )
        try {
            if (connection.responseCode != 200) throw UpdateFailure("Mesh couldn't download the update.")
            destination.outputStream().use { output ->
                connection.inputStream.use { input -> input.copyTo(output) }
            }
        } finally {
            connection.disconnect()
        }
        return destination
    }

    private fun request(path: String): Response {
        val connection = open(URL("https://api.github.com$path"), "application/vnd.github+json")
        return try {
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            Response(code, stream?.bufferedReader()?.use { it.readText() } ?: "")
        } finally {
            connection.disconnect()
        }
    }

    private fun open(initial: URL, accept: String): HttpURLConnection {
        var url = initial
        repeat(6) {
            val connection = (url.openConnection() as HttpURLConnection).apply {
                instanceFollowRedirects = false
                connectTimeout = 30_000
                readTimeout = 300_000
                requestMethod = "GET"
                setRequestProperty("Accept", accept)
                setRequestProperty("User-Agent", "Mesh-Android")
                setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
                if (token.isNotEmpty() && url.host.equals("api.github.com", ignoreCase = true)) {
                    setRequestProperty("Authorization", "Bearer $token")
                }
            }
            val code = connection.responseCode
            if (code !in 300..399) return connection
            val location = connection.getHeaderField("Location")
                ?: throw UpdateFailure("Mesh couldn't download the update.")
            connection.disconnect()
            url = URL(url, location)
        }
        throw UpdateFailure("Mesh couldn't download the update.")
    }

    private data class Response(val code: Int, val body: String)
}

private fun normalize(value: String): String =
    value.trim().lowercase()

private fun normalizeToken(value: String): String {
    val token = value.trim()
    return if (token.startsWith("bearer ", ignoreCase = true)) token.drop(7).trim() else token
}
