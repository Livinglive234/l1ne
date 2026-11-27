package com.livenet.l1ne.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ContactBookTest {
    private fun c(name: String, address: String, imported: Boolean = false, source: String? = null) = Contact(name = name, address = address, imported = imported, source = source)
    /** name, address, name, address, ... */
    private fun result(vararg e: String, skipped: Int = 0) = VCard.Result(e.toList().chunked(2) { VCard.Entry(it[0], it[1]) }, skipped)

    @Test fun anImportAddsNewAddressesAndOnlyRenamesEarlierImports() {
        val start = listOf(c("Typed", "7001@pbx"), c("Old name", "7002@pbx", imported = true, source = "link"))
        val (list, s) = ContactBook.merge(start, result("Other", "7001@PBX", "New name", "7002@pbx", "Fresh", "7003@pbx", skipped = 2), "acc", "link")
        assertEquals(listOf("Typed", "New name", "Fresh"), list.map { it.name })
        assertEquals(1, s.added); assertEquals(1, s.updated); assertEquals(1, s.kept); assertEquals(2, s.skipped)
        assertEquals("acc", list.last().accountID); assertTrue(list.last().imported)
    }

    @Test fun aDuplicateInsideOneImportHitsTheEntryJustAdded() {
        val (list, s) = ContactBook.merge(emptyList(), result("First", "7005@pbx", "Second", "7005@pbx"), null, "link")
        assertEquals(1, list.size); assertEquals(1, s.added); assertEquals(1, s.updated)            // the second entry renames the import that was just added
        assertEquals("Second", list.single().name)
    }

    @Test fun aDirectorySyncMakesItsOwnContactsMatchAndLeavesOthersAlone() {
        val start = listOf(c("Mine", "7001@pbx"), c("Gone", "7002@pbx", imported = true, source = "dir:a"), c("Renamed", "7003@pbx", imported = true, source = "dir:a"), c("Other dir", "7004@pbx", imported = true, source = "dir:b"))
        val (list, s) = ContactBook.replaceSource(start, "dir:a", result("Typed elsewhere", "7001@pbx", "New 3", "7003@pbx", "Added", "7009@pbx", "Theirs", "7004@pbx"), null)
        assertEquals(setOf("Mine", "New 3", "Added", "Other dir"), list.map { it.name }.toSet())
        assertEquals(1, s.removed); assertEquals(1, s.updated); assertEquals(1, s.added); assertEquals(2, s.kept)
    }

    @Test fun namesAreFoundByServerThenByUserThenByTheLastTenDigits() {
        val all = listOf(c("Alice", "7001@pbx"), c("Bob", "7001@other"), c("Carol", "7002@pbx"), c("Dan", "16125550142@pbx"))
        assertEquals("Bob", ContactBook.name(all, "7001", "other")); assertEquals("Alice", ContactBook.name(all, "7001", "pbx"))
        assertEquals("Carol", ContactBook.name(all, "7002", "elsewhere")); assertNull(ContactBook.name(all, "7001", "elsewhere"))   // two people share 7001, so it is not guessed
        assertEquals("Dan", ContactBook.name(all, "+1 612 555 0142".filter { it.isDigit() || it == '+' }, null)); assertNull(ContactBook.name(all, "9999", null))
        assertEquals("Alice", ContactBook.nameOrNumber(all, "7001@pbx")); assertEquals("(651) 760-4266", ContactBook.nameOrNumber(all, "6517604266@pbx"))
    }
}
