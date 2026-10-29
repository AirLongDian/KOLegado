package io.legado.app.ko

import android.content.Context
import android.content.Intent
import android.util.Log
import io.legado.app.data.appDb
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.help.BookHelp
import io.legado.app.model.ReadBook
import io.legado.app.model.webBook.WebBook
import kotlinx.coroutines.*
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.ConcurrentHashMap

/** Only paths and chapter-relative positions cross JNI. No exported book or second cache. */
class KoChapterAdapter(context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val prefs = context.getSharedPreferences("ko_position", Context.MODE_PRIVATE)
    private val generation = AtomicInteger()
    private val result = AtomicReference<String?>(null)
    private val saveOrder = AtomicInteger()
    private val latestSave = ConcurrentHashMap<String, Int>()
    private val saveLock = Any()
    private var loading: Job? = null
    private var prefetch: Job? = null
    @Volatile var book: Book? = null
        private set
    @Volatile private var chapters: List<BookChapter> = emptyList()
    @Volatile private var index = -1
    @Volatile private var percent = 0

    fun open(intent: Intent) {
        persist()
        val token = generation.incrementAndGet()
        loading?.cancel()
        prefetch?.cancel()
        result.set(null)
        book = null
        chapters = emptyList()
        index = -1
        loading = scope.launch {
            try {
                val url = intent.getStringExtra("bookUrl")
                val selected = (if (url.isNullOrEmpty()) appDb.bookDao.lastReadBook
                    else appDb.bookDao.getBook(url)) ?: ReadBook.book
                    ?: error("没有可阅读的书籍")
                var list = appDb.bookChapterDao.getChapterList(selected.bookUrl)
                if (list.isEmpty()) {
                    val source = appDb.bookSourceDao.getBookSource(selected.origin)
                        ?: error("书源不存在，请先在阅读中导入书源")
                    if (selected.tocUrl.isEmpty())
                        WebBook.getBookInfoAwait(this, source, selected, false)
                    list = WebBook.getChapterListAwait(this, source, selected)
                    ensureActive()
                    appDb.bookChapterDao.insert(*list.toTypedArray())
                }
                check(list.isNotEmpty()) { "目录为空" }
                ensureActive()
                if (token != generation.get()) return@launch
                book = selected
                chapters = list
                index = -1
                val chapter = selected.durChapterIndex.coerceIn(0, list.lastIndex)
                val key = selected.bookUrl
                val position = if (prefs.getInt("$key.chapter", -1) == chapter)
                    prefs.getInt("$key.percent", 0) else 0
                load(token, chapter, position)
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { publishError(token, e) }
        }
    }

    fun request(chapter: Int, position: Int = 0) {
        if (book == null || chapters.isEmpty()) return
        if (chapter !in chapters.indices) {
            result.set(JSONObject().put("message", if (chapter < 0) "已到第一章" else "已到最后一章").toString())
            return
        }
        persist()
        val token = generation.incrementAndGet()
        loading?.cancel()
        prefetch?.cancel()
        result.set(null)
        loading = scope.launch {
            try { load(token, chapter, position) }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) { publishError(token, e) }
        }
    }

    private suspend fun CoroutineScope.load(token: Int, chapter: Int, position: Int) {
        val selected = book ?: return
        val entry = chapters[chapter]
        val path = BookHelp.getContentFile(selected, entry)
        if (!path.isFile || path.length() == 0L) {
            val source = appDb.bookSourceDao.getBookSource(selected.origin)
                ?: error("本章尚未缓存，且书源不可用")
            WebBook.getContentAwait(this, source, selected, entry, chapters.getOrNull(chapter + 1)?.url)
        }
        ensureActive()
        check(path.isFile && path.length() > 0) { "章节缓存为空，请检查书源正文规则" }
        if (token != generation.get()) return
        index = chapter
        percent = position.coerceIn(0, 10000)
        ReadBook.book = selected
        ReadBook.durChapterIndex = chapter
        selected.durChapterIndex = chapter
        selected.durChapterTitle = entry.title
        selected.durChapterPos = 0 // Old reader's character offsets are not percentages.
        result.set(JSONObject().put("path", path.absolutePath).put("title", entry.title)
            .put("index", chapter).put("percent", percent).toString())
        persist()
        // One chapter ahead, into Legado's existing cache only. No KO render-cache file.
        prefetch = scope.launch {
            val next = chapters.getOrNull(chapter + 1) ?: return@launch
            if (BookHelp.getContentFile(selected, next).isFile) return@launch
            val source = appDb.bookSourceDao.getBookSource(selected.origin) ?: return@launch
            try { WebBook.getContentAwait(this, source, selected, next, chapters.getOrNull(chapter + 2)?.url) }
            catch (e: CancellationException) { throw e }
            catch (_: Exception) { /* A failed prefetch must not interrupt reading. */ }
        }
    }

    private fun publishError(token: Int, e: Exception) {
        Log.e("LegadoKO", "chapter load failed", e)
        if (token == generation.get()) result.set(JSONObject().put("error", e.localizedMessage ?: e.toString()).toString())
    }
    fun poll(): String = result.getAndSet(null) ?: ""
    fun relative(direction: Int) { request(index + direction, if (direction < 0) 10000 else 0) }
    fun updatePosition(chapter: Int, value: Int) {
        if (chapter == index) percent = value.coerceIn(0, 10000)
    }

    fun persist(): Job? {
        val selected = book ?: return null
        val chapter = index
        if (chapter < 0) return null
        val position = percent
        prefs.edit().putInt("${selected.bookUrl}.chapter", chapter)
            .putInt("${selected.bookUrl}.percent", position).apply()
        val snapshot = selected.copy().apply {
            durChapterIndex = chapter
            durChapterTitle = chapters.getOrNull(chapter)?.title ?: durChapterTitle
            durChapterPos = 0
            durChapterTime = System.currentTimeMillis()
        }
        val serial = saveOrder.incrementAndGet()
        latestSave[snapshot.bookUrl] = serial
        return scope.launch { synchronized(saveLock) {
            if (serial == latestSave[snapshot.bookUrl]) appDb.bookDao.update(snapshot)
        } }
    }

    fun close() {
        generation.incrementAndGet()
        loading?.cancel()
        prefetch?.cancel()
        val saved = persist()
        if (saved == null) scope.cancel() else saved.invokeOnCompletion { scope.cancel() }
    }
}
