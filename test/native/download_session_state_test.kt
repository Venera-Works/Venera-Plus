package com.github.veneraworks.veneraplus

fun main() {
    val state = DownloadSessionState()
    check(state.start("old", 1, 0, false, 0) == null)
    state.bind("old")
    val first = state.start("old", 1, -100, false, 1)!!
    check(first.progress == 0)
    check(state.start("old", 1, 300, true, 2) === first)
    check(first.waiting && first.progress == 300 && first.lastHeartbeat == 2L)
    check(state.update("unknown", 1, 500, false, 3) == null)
    check(state.stop("unknown", 1) == null)
    check(state.stop("old", 1) === first)
    check(state.update("old", 1, 500, false, 3) == null)
    check(state.start("old", 1, 0, false, 4) == null)
    val second = state.start("old", 2, 2000, false, 5)!!
    check(second.progress == 1000)
    check(state.stop("old", 1) == null)
    check(state.start("old", 1, 0, false, 6) == null)
    check(state.active === second)
    state.bind("new")
    check(state.active == null)
    val current = state.start("new", 1, 500, false, 7)!!
    check(!state.dispose("old"))
    check(state.active === current)
    check(state.start("old", 3, 0, false, 8) == null)
    check(state.dispose("new"))
    check(state.active == null && state.owner == null)
    check(state.start("new", 2, 0, false, 9) == null)
    println("Download session ownership: stale start/update/stop, replacement and disposal passed")
}
