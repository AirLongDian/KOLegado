package io.legado.app.ui.book.read.page.delegate

import android.graphics.Canvas
import android.os.SystemClock
import android.util.Log
import io.legado.app.BuildConfig
import io.legado.app.ui.book.read.page.ReadView
import io.legado.app.ui.book.read.page.entities.PageDirection

class NoAnimPageDelegate(readView: ReadView) : HorizontalPageDelegate(readView) {

    override fun setDirection(direction: PageDirection) {
        // No-animation rendering uses the PageViews directly, not bitmap snapshots.
        mDirection = direction
    }

    override fun onAnimStart(animationSpeed: Int) {
        if (!isCancel) {
            val started = SystemClock.uptimeMillis()
            readView.fillPage(mDirection)
            if (BuildConfig.DEBUG) {
                Log.d("PagePerf", "fillPage=${SystemClock.uptimeMillis() - started}ms")
            }
        }
        // fillPage invalidates the visible page. Posting another full redraw from
        // stopScroll() is unnecessary for a delegate with no animation.
        isStarted = false
        isMoved = false
        isRunning = false
    }

    override fun onDraw(canvas: Canvas) {
        // nothing
    }

    override fun onAnimStop() {
        // nothing
    }


}
