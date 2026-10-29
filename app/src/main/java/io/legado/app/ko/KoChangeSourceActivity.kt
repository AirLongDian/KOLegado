package io.legado.app.ko

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import io.legado.app.data.appDb
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookSource
import io.legado.app.ui.book.changesource.ChangeSourceDialog
import io.legado.app.ui.book.info.BookInfoViewModel
import io.legado.app.utils.showDialogFragment
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** A translucent host for Legado's existing source picker; KO remains behind it. */
class KoChangeSourceActivity : AppCompatActivity(), ChangeSourceDialog.CallBack {
    private val viewModel by viewModels<BookInfoViewModel>()
    private var targetBookUrl: String? = null

    override val oldBook: Book?
        get() = viewModel.bookData.value

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)
        viewModel.chapterListData.observe(this) { chapters ->
            val target = targetBookUrl ?: return@observe
            if (chapters.firstOrNull()?.bookUrl == target) {
                setResult(RESULT_OK, Intent().putExtra("bookUrl", target))
                finish()
            } else if (chapters.isEmpty()) {
                targetBookUrl = null
                // The existing ViewModel reports the source error; keep the picker usable.
                oldBook?.let { showDialogFragment(ChangeSourceDialog(it.name, it.author)) }
            }
        }
        lifecycleScope.launch {
            val url = intent.getStringExtra("bookUrl")
            val book = withContext(Dispatchers.IO) {
                url?.let { appDb.bookDao.getBook(it) }
            }
            if (book == null) {
                finish()
                return@launch
            }
            viewModel.inBookshelf = true
            viewModel.bookData.value = book
            if (savedInstanceState == null) {
                showDialogFragment(ChangeSourceDialog(book.name, book.author))
            }
        }
    }

    override fun changeTo(source: BookSource, book: Book) {
        targetBookUrl = book.bookUrl
        viewModel.changeTo(source, book)
    }

    override fun onChangeSourceDialogClosed() {
        if (targetBookUrl == null && !isFinishing) finish()
    }
}
