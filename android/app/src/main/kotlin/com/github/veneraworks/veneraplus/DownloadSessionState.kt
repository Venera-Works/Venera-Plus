package com.github.veneraworks.veneraplus

/** Main-thread state shared by the channel and service. Retired starts/updates
 * cannot resurrect a paused transfer, even if Android delivers an old Intent. */
class DownloadSessionState {
    data class Session(
        val owner: String,
        val id: Int,
        var progress: Int,
        var waiting: Boolean,
        var lastHeartbeat: Long,
    )

    var owner: String? = null
        private set
    var active: Session? = null
        private set
    private var newestId = 0

    fun bind(owner: String) {
        require(owner.isNotBlank())
        if (this.owner == owner) return
        this.owner = owner
        active = null
        newestId = 0
    }

    fun start(owner: String, id: Int, progress: Int, waiting: Boolean, now: Long): Session? {
        if (this.owner != owner || id <= 0) return null
        if (active?.id == id) return update(owner, id, progress, waiting, now)
        if (id <= newestId) return null
        newestId = id
        return Session(owner, id, progress.coerceIn(0, 1000), waiting, now).also { active = it }
    }

    fun update(owner: String, id: Int, progress: Int, waiting: Boolean, now: Long): Session? {
        val session = active ?: return null
        if (session.owner != owner || session.id != id) return null
        session.progress = progress.coerceIn(0, 1000)
        session.waiting = waiting
        session.lastHeartbeat = now
        return session
    }

    fun stop(owner: String, id: Int): Session? {
        val session = active ?: return null
        if (session.owner != owner || session.id != id) return null
        active = null
        return session
    }

    fun dispose(owner: String): Boolean {
        if (this.owner != owner) return false
        active = null
        this.owner = null
        return true
    }
}
