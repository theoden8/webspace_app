// JVM unit tests for ScreenShareService.fit: the size a share's frames are
// taken at, from the screen, the page's caps and the app's long-side cap
// (SHARE-018).
package org.codeberg.theoden8.webspace

import org.junit.Assert.assertEquals
import org.junit.Test

class ScreenShareFitTest {

    private fun request(maxWidth: Int = 0, maxHeight: Int = 0, maxLongSide: Int = 1280) =
        ShareRequest(maxWidth, maxHeight, maxLongSide, fps = 10, title = "", text = "", stop = "")

    @Test
    fun scalesAPhoneDownToTheLongSideCap() {
        assertEquals(Pair(576, 1280), ScreenShareService.fit(1080, 2400, request()))
        assertEquals(Pair(1280, 576), ScreenShareService.fit(2400, 1080, request()))
    }

    @Test
    fun neverScalesUp() {
        assertEquals(Pair(720, 1280), ScreenShareService.fit(720, 1280, request()))
        assertEquals(Pair(480, 800), ScreenShareService.fit(480, 800, request(maxWidth = 1920)))
    }

    @Test
    fun theTighterCapWinsAndTheShapeIsKept() {
        assertEquals(Pair(400, 888), ScreenShareService.fit(1080, 2400, request(maxWidth = 400)))
        assertEquals(Pair(270, 600), ScreenShareService.fit(1080, 2400, request(maxHeight = 600)))
    }

    @Test
    fun sidesAreEvenAndNeverZero() {
        val (w, h) = ScreenShareService.fit(1081, 2401, request(maxLongSide = 3))
        assertEquals(0, w % 2)
        assertEquals(0, h % 2)
        assertEquals(2, w)
    }
}
