package com.livenet.l1ne.core

import java.text.Normalizer

/** Phone-keypad letters, so "5673" finds "Jordan". */
object T9 {
    private val WORD_BREAK = Regex("[^\\p{L}\\p{N}]+")
    private val map: Map<Char, Char> = buildMap { mapOf('2' to "abc", '3' to "def", '4' to "ghi", '5' to "jkl", '6' to "mno", '7' to "pqrs", '8' to "tuv", '9' to "wxyz").forEach { (d, ls) -> ls.forEach { put(it, d) } } }
    fun digits(text: String): String = Normalizer.normalize(text.lowercase(), Normalizer.Form.NFD).mapNotNull { c -> if (c.isDigit()) c else map[c] }.joinToString("")
    /** True when the typed digits start a word of the name, the whole name, or the extension. */
    fun matches(typed: String, name: String, address: String): Boolean {
        if (typed.isEmpty() || !typed.all { it.isDigit() }) return false
        if (name.split(WORD_BREAK).filter { it.isNotEmpty() }.any { digits(it).startsWith(typed) }) return true
        if (digits(name.filter { it.isLetterOrDigit() }).startsWith(typed)) return true
        return address.substringBefore('@').startsWith(typed)
    }
}
