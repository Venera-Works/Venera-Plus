package com.github.veneraworks.veneraplus

import org.junit.Assert.*
import org.junit.Test

class DownloadSessionStateTest {
    @Test
    fun sessionUpdatesRejectStaleGenerationsAndClampProgress() {
        val state = DownloadSessionState()
        assertNull(state.start("old", 1, 0, false, 0))
        state.bind("old")
        val first = state.start("old", 1, -100, false, 1)!!
        assertEquals(0, first.progress)
        assertSame(first, state.start("old", 1, 300, true, 2))
        assertTrue(first.waiting)
        assertEquals(300, first.progress)
        assertEquals(2L, first.lastHeartbeat)
        assertNull(state.update("unknown", 1, 500, false, 3))
        assertNull(state.stop("unknown", 1))
        assertSame(first, state.stop("old", 1))
        assertNull(state.update("old", 1, 500, false, 3))
        assertNull(state.start("old", 1, 0, false, 4))
        val second = state.start("old", 2, 2000, false, 5)!!
        assertEquals(1000, second.progress)
        assertNull(state.stop("old", 1))
        assertNull(state.start("old", 1, 0, false, 6))
        assertSame(second, state.active)
    }

    @Test
    fun replacingAndDisposingOwnerRejectsLateCallbacks() {
        val state = DownloadSessionState()
        state.bind("old")
        assertNotNull(state.start("old", 1, 500, false, 1))
        state.bind("new")
        assertNull(state.active)
        val current = state.start("new", 1, 500, false, 7)!!
        assertFalse(state.dispose("old"))
        assertSame(current, state.active)
        assertNull(state.start("old", 3, 0, false, 8))
        assertNull(state.update("old", 1, 500, false, 8))
        assertNull(state.stop("old", 1))
        assertSame(current, state.active)
        assertTrue(state.dispose("new"))
        assertNull(state.active)
        assertNull(state.owner)
        assertNull(state.start("new", 2, 0, false, 9))
    }
}
