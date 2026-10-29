@file:Suppress("unused", "UNUSED_PARAMETER", "DEPRECATION")
package io.legado.app.ui.book.read

import android.app.NativeActivity
import android.app.Dialog
import android.content.*
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.ColorDrawable
import android.net.ConnectivityManager
import android.net.Uri
import android.os.*
import android.provider.Settings
import android.util.Log
import android.util.DisplayMetrics
import android.view.WindowManager
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import io.legado.app.BuildConfig
import io.legado.app.ko.KoChapterAdapter
import io.legado.app.ko.KoRuntime
import io.legado.app.model.ReadBook
import io.legado.app.ko.KoChangeSourceActivity
import io.legado.app.ui.book.toc.TocActivity
import java.io.File

/** Same application/process; KO's NativeActivity/BlitBuffer path owns the reading surface. */
class ReadBookActivity : NativeActivity() {
    private lateinit var chapters: KoChapterAdapter
    @Volatile private var resumed = false
    @Volatile private var lightDialogState = -1
    init { System.loadLibrary("luajit") }

    override fun onCreate(savedInstanceState: Bundle?) {
        chapters = KoChapterAdapter(this)
        window.setFormat(PixelFormat.RGBA_8888)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        super.onCreate(savedInstanceState)
        ReadBook.changeChapter = { chapters.relative(it) }
        chapters.open(intent)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        chapters.open(intent)
    }
    override fun onResume() { super.onResume(); resumed = true }
    override fun onPause() { resumed = false; chapters.persist(); super.onPause() }
    override fun onDestroy() {
        ReadBook.changeChapter = null
        chapters.close()
        super.onDestroy()
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode == RESULT_OK && data != null) {
            when (requestCode) {
                42 -> chapters.request(data.getIntExtra("index", ReadBook.durChapterIndex))
                43 -> data.getStringExtra("bookUrl")?.let {
                    chapters.open(Intent().putExtra("bookUrl", it))
                }
            }
        }
    }

    // Minimal in-process chapter bridge, called by KO's existing JNI helpers.
    fun koPoll(): String = chapters.poll()
    fun koChapter(direction: Int) = chapters.relative(direction)
    fun koPosition(chapter: Int, percent: Int) = chapters.updatePosition(chapter, percent)
    fun koChangeSource() = runOnUiThread {
        chapters.book?.let { startActivityForResult(Intent(this, KoChangeSourceActivity::class.java)
            .putExtra("bookUrl", it.bookUrl), 43) }
    }
    fun koToc() = runOnUiThread {
        chapters.book?.let { startActivityForResult(Intent(this, TocActivity::class.java)
            .putExtra("bookUrl", it.bookUrl), 42) }
    }
    fun onNativeError(message: String) {
        Log.e("LegadoKO", message)
        showToast("KO 阅读器：$message", true)
    }

    // KO Android host API. Unused file import, updater and launcher features stay disabled.
    fun extractAssets(): Boolean = try { KoRuntime.install(this); true }
        catch (e: Exception) { onNativeError(e.toString()); false }
    fun getName() = "阅读D · KO"
    fun getFlavor() = "legado"
    fun getProduct(): String = Build.PRODUCT
    fun getPlatformName(): String = Build.HARDWARE
    fun getVersion() = BuildConfig.VERSION_NAME
    fun isDebuggable() = BuildConfig.DEBUG
    fun hasRuntimeChanges() = false
    fun hasBrokenLifecycle() = false
    fun hasRequiredPermissions() = true
    fun isActivityResumed() = resumed
    fun getExternalPath(): String = File(filesDir, "koreader/state").absolutePath
    fun getExternalSdPath() = ""
    fun getFilePathFromIntent(): String? = null
    fun getLastImportedPath(): String? = null
    private fun realMetrics() = DisplayMetrics().also { windowManager.defaultDisplay.getRealMetrics(it) }
    fun getScreenWidth(): Int = realMetrics().widthPixels
    fun getScreenHeight(): Int = realMetrics().heightPixels
    fun getScreenAvailableWidth() = DisplayMetrics().also { windowManager.defaultDisplay.getMetrics(it) }.widthPixels
    fun getScreenAvailableHeight() = DisplayMetrics().also { windowManager.defaultDisplay.getMetrics(it) }.heightPixels
    fun getStatusBarHeight() = 0
    fun getScreenOrientation() = windowManager.defaultDisplay.rotation
    fun setScreenOrientation(orientation: Int) = runOnUiThread { requestedOrientation = orientation }
    fun isFullscreen() = true
    fun setFullscreen(enabled: Boolean) = Unit
    fun setIgnoreInput(enabled: Boolean) = Unit
    fun isColorScreen() = false
    fun isEink() = false // CracKDroid submits to its system compositor; no vendor Android EPD API.
    fun isEinkFull() = false
    fun getEinkPlatform() = "none"
    fun getEinkConstants() = ""
    fun einkUpdate(mode: Int) = Unit
    fun einkUpdate(mode: Int, delay: Long, x: Int, y: Int, width: Int, height: Int) = Unit
    fun isChromeOS() = false
    fun isTv() = false
    fun hasNativeRotation() = false
    fun hasOTAUpdates() = false
    fun hasLights() = true
    fun isWarmthDevice() = false
    fun enableFrontlightSwitch() = false
    fun getLightDialogState() = lightDialogState
    fun getScreenBrightness(): Int {
        val level = window.attributes.screenBrightness
        return if (level >= 0f) (1 + level * 254).toInt().coerceIn(1, 255)
        else Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS, 128).coerceIn(1, 255)
    }
    fun getScreenMinBrightness() = 1
    fun getScreenMaxBrightness() = 255
    fun getScreenMinWarmth() = 0
    fun getScreenMaxWarmth() = 0
    fun getScreenWarmth() = 0
    private fun applyBrightness(brightness: Int) {
        val params = window.attributes
        params.screenBrightness = (brightness.coerceIn(1, 255) - 1) / 254f
        window.attributes = params
    }
    fun setScreenBrightness(brightness: Int) = runOnUiThread { applyBrightness(brightness) }
    fun setScreenWarmth(warmth: Int) = Unit
    fun setScreenOffTimeout(ms: Int) = Unit
    fun showFrontlightDialog(title: String, dim: String, warmth: String, ok: String, cancel: String) {
        lightDialogState = 0
        runOnUiThread {
            val original = getScreenBrightness()
            val dialog = Dialog(this)
            val heading = TextView(this).apply { text = title; textSize = 22f; setTextColor(Color.BLACK) }
            val label = TextView(this).apply { text = dim; textSize = 18f; setTextColor(Color.BLACK) }
            val slider = SeekBar(this).apply {
                max = 255
                progress = original
                setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                    override fun onStartTrackingTouch(bar: SeekBar?) = Unit
                    override fun onStopTrackingTouch(bar: SeekBar?) = Unit
                    override fun onProgressChanged(bar: SeekBar?, value: Int, fromUser: Boolean) {
                        if (fromUser) applyBrightness(value)
                    }
                })
            }
            val content = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(32, 24, 32, 24)
                setBackgroundColor(Color.WHITE)
                addView(heading)
                addView(label)
                addView(slider)
            }
            val actions = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            actions.addView(Button(this).apply {
                text = cancel
                setTextColor(Color.BLACK)
                setBackgroundColor(Color.WHITE)
                setOnClickListener { applyBrightness(original); lightDialogState = 1; dialog.dismiss() }
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            actions.addView(Button(this).apply {
                text = ok
                setTextColor(Color.BLACK)
                setBackgroundColor(Color.WHITE)
                setOnClickListener { lightDialogState = 2; dialog.dismiss() }
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            content.addView(actions)
            dialog.setContentView(content)
            dialog.setOnCancelListener { applyBrightness(original); lightDialogState = 1 }
            dialog.show()
            dialog.window?.setBackgroundDrawable(ColorDrawable(Color.WHITE))
            dialog.window?.setLayout((getScreenWidth() * 0.88f).toInt(), ViewGroup.LayoutParams.WRAP_CONTENT)
        }
    }
    private fun battery() = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
    fun getBatteryLevel(): Int {
        val info = battery() ?: return 0
        return info.getIntExtra(BatteryManager.EXTRA_LEVEL, 0) * 100 / info.getIntExtra(BatteryManager.EXTRA_SCALE, 100).coerceAtLeast(1)
    }
    fun isCharging() = (battery()?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
    fun getNetworkInfo(): String = (getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager)
        .activeNetworkInfo?.let { (if (it.isConnected) "1;" else "0;") + it.type } ?: "0;-1"
    fun openWifiSettings() = runOnUiThread { startActivity(Intent(Settings.ACTION_WIFI_SETTINGS)) }
    fun openLink(url: String): Boolean = try { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))); true } catch (_: Exception) { false }
    fun isPathInsideSandbox(path: String) = File(path).canonicalPath.startsWith(filesDir.canonicalPath + "/")
    fun isPackageEnabled(pkg: String): Boolean = try { packageManager.getApplicationInfo(pkg, 0).enabled } catch (_: Exception) { false }
    fun hasClipboardText() = (getSystemService(CLIPBOARD_SERVICE) as ClipboardManager).hasPrimaryClip()
    fun getClipboardText() = (getSystemService(CLIPBOARD_SERVICE) as ClipboardManager).primaryClip?.getItemAt(0)?.coerceToText(this)?.toString() ?: ""
    fun setClipboardText(text: String) = runOnUiThread { (getSystemService(CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("", text)) }
    fun showToast(message: String, longTimeout: Boolean) = runOnUiThread { Toast.makeText(this, message, if (longTimeout) Toast.LENGTH_LONG else Toast.LENGTH_SHORT).show() }
    fun needsWakelocks() = false
    fun canIgnoreBatteryOptimizations() = false
    fun canWriteSystemSettings() = false
    fun hasWriteSettingsPermission() = false
    fun requestIgnoreBatteryOptimizations(rationale: String, ok: String, cancel: String) = Unit
    fun requestWriteSystemSettings(rationale: String, ok: String, cancel: String) = Unit
    fun safFilePicker(path: String?) = false
    fun installApk() = Unit
    fun download(url: String, name: String) = -1
    fun untar(filePath: String, outputPath: String) = false
    fun dumpLogs() = Unit
    fun onNativeCrash() = onNativeError("原生运行时异常")
    fun startTestActivity() = Unit
    fun performHapticFeedback(constant: Int, force: Int) = Unit
    fun dictLookup(text: String?, action: String?, pkg: String?) = Unit
    fun sendText(text: String, reason: String?, title: String?, mimetype: String?) = Unit
}
