package com.livenet.l1ne.core

/** How the version is shown in Settings: "0.1.0-beta.9" reads as "0.1.0 beta 9". */
object VersionLabel {
    fun pretty(version: String): String {
        val parts = version.split('-', limit = 2)
        return if (parts.size == 2) parts[0] + " " + parts[1].split('.').joinToString(" ") else version
    }
}
