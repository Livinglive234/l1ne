package com.livenet.l1ne

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID

/** A context whose files and preferences live in a throwaway folder, so tests never touch the real app's data. */
class TestContext(base: Context = InstrumentationRegistry.getInstrumentation().targetContext) : ContextWrapper(base) {
    private val id = UUID.randomUUID().toString().take(8)
    private val dir = File(base.cacheDir, "test-$id").apply { mkdirs() }
    override fun getFilesDir(): File = dir
    override fun getSharedPreferences(name: String, mode: Int): SharedPreferences = baseContext.getSharedPreferences("test-$id-$name", mode)
    override fun getApplicationContext(): Context = this
    fun cleanup() { dir.deleteRecursively() }
}
