package io.legado.app.model

import io.legado.app.data.entities.Book

/** Shared shelf/API state only. Pagination and display live entirely in KOReader. */
object ReadBook {
    @Volatile var book: Book? = null
    @Volatile var durChapterIndex = 0
    @Volatile var changeChapter: ((Int) -> Unit)? = null
    fun moveToPrevChapter(toLast: Boolean = false) { changeChapter?.invoke(-1) }
    fun moveToNextChapter(toFirst: Boolean = false) { changeChapter?.invoke(1) }
}
