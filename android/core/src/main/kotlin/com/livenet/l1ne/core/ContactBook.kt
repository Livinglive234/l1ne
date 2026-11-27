package com.livenet.l1ne.core

import java.util.UUID

data class Contact(val id: String = UUID.randomUUID().toString(), val name: String, val address: String, val accountID: String? = null,
                   val imported: Boolean = false, val source: String? = null) {
    val user: String get() = address.substringBefore('@')
}
data class ImportSummary(var added: Int = 0, var updated: Int = 0, var kept: Int = 0, var skipped: Int = 0, var removed: Int = 0)

/** The address book's rules as plain functions over a list (the store around it only keeps the list and saves it). */
object ContactBook {
    /** Entries you typed in win over imported ones with the same address; an import only renames earlier imports. */
    fun merge(contacts: List<Contact>, result: VCard.Result, account: String?, source: String): Pair<List<Contact>, ImportSummary> {
        val s = ImportSummary(skipped = result.skipped)
        return upsert(contacts, result.entries, account, source, s) { it.imported } to s
    }

    /** Makes one synced directory's contacts match it exactly (new added, renamed, gone removed); others' entries are never touched. */
    fun replaceSource(contacts: List<Contact>, tag: String, result: VCard.Result, account: String?): Pair<List<Contact>, ImportSummary> {
        val s = ImportSummary(skipped = result.skipped)
        val wanted = result.entries.associateBy { it.address.lowercase() }
        val kept = contacts.filterNot { it.source == tag && wanted[it.address.lowercase()] == null }
        s.removed = contacts.size - kept.size
        return upsert(kept, wanted.values.toList(), account, tag, s) { it.source == tag } to s
    }

    /** An existing contact with the address is renamed when [mayRename] allows it and counted as kept otherwise; a new address is added. One lookup table, so a big directory is not searched once per entry. */
    private fun upsert(contacts: List<Contact>, entries: List<VCard.Entry>, account: String?, source: String, s: ImportSummary, mayRename: (Contact) -> Boolean): List<Contact> {
        val list = contacts.toMutableList()
        val index = HashMap<String, Int>()
        list.forEachIndexed { i, c -> index.putIfAbsent(c.address.lowercase(), i) }
        for (e in entries) {
            val key = e.address.lowercase(); val i = index[key]
            if (i != null) { if (mayRename(list[i]) && list[i].name != e.name) { list[i] = list[i].copy(name = e.name); s.updated++ } else s.kept++ }
            else { list.add(Contact(name = e.name, address = e.address, accountID = account, imported = true, source = source)); index[key] = list.size - 1; s.added++ }
        }
        return list
    }

    /** Who a call was with: same extension on the same server; the same extension anywhere (if only one contact has it); a number by its last ten digits. */
    fun name(all: List<Contact>, rawUser: String, rawDomain: String? = null): String? {
        val user = rawUser.lowercase().removePrefix("sip:"); val domain = rawDomain?.lowercase()?.substringBefore(':')
        fun dom(c: Contact) = c.address.substringAfter('@', "").lowercase()
        all.firstOrNull { it.user.lowercase() == user && (domain == null || dom(it) == domain) }?.let { return it.name }
        all.filter { it.user.lowercase() == user }.takeIf { it.size == 1 }?.let { return it[0].name }
        val digits = user.filter { it.isDigit() }
        if (digits.length >= 7) {
            val tail = digits.takeLast(10)
            all.filter { c -> c.user.filter { it.isDigit() }.let { it.length >= 7 && it.takeLast(10) == tail } }.takeIf { it.size == 1 }?.let { return it[0].name }
        }
        return null
    }

    /** What to show for a "user@domain" peer: the contact's name, else the number nicely formatted. */
    fun nameOrNumber(all: List<Contact>, address: String): String {
        val user = address.substringBefore('@')
        return name(all, user, address.substringAfter('@', "").ifEmpty { null }) ?: PhoneFormat.pretty(user)
    }
}
