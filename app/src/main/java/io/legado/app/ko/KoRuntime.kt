package io.legado.app.ko

import android.content.Context
import java.io.File
import java.util.zip.ZipInputStream

/** Installed code/fonts only. Chapter content always stays in the existing book_cache. */
object KoRuntime {
    @Synchronized fun install(context: Context) {
        val root = File(context.filesDir, "koreader")
        val version = context.assets.open("ko-runtime.version").bufferedReader().use { it.readText().trim() }
        val marker = File(root, ".installed")
        if (marker.isFile && marker.readText() == version) return
        check(root.isDirectory || root.mkdirs())
        val prefix = root.canonicalPath + File.separator
        ZipInputStream(context.assets.open("ko-runtime.zip")).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val file = File(root, entry.name)
                check(file.canonicalPath.startsWith(prefix)) { "Invalid KO runtime path" }
                if (entry.isDirectory) check(file.isDirectory || file.mkdirs())
                else {
                    file.parentFile?.mkdirs()
                    file.outputStream().use { zip.copyTo(it) }
                }
                zip.closeEntry()
            }
        }
        marker.writeText(version)
    }
}
