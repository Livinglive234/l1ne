package com.livenet.l1ne.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class T9Test {
    @Test fun lettersMapToTheKeysTheySitOn() {
        assertEquals("5673", T9.digits("Jord")); assertEquals("5246", T9.digits("Kaim")); assertEquals("2223", T9.digits("Abcd"))
        assertEquals("7001", T9.digits("7001")); assertEquals("35", T9.digits("é-k"))               // accents fold, punctuation drops
    }
    @Test fun typedDigitsMatchWordsNamesAndExtensions() {
        assertTrue(T9.matches("5673", "Jordan Lee", "7201@pbx.example.com"))        // start of a word
        assertTrue(T9.matches("533", "Jordan Lee", "7201@pbx.example.com"))         // second word: Lee
        assertTrue(T9.matches("7201", "Jordan Lee", "7201@pbx.example.com"))        // the extension
        assertTrue(T9.matches("56732", "Jordan Lee", "7201@pbx.example.com"))       // more of the first word
        assertFalse(T9.matches("9", "Jordan Lee", "7201@pbx.example.com"))
        assertFalse(T9.matches("", "Jordan Lee", "7201@pbx.example.com"))
        assertFalse(T9.matches("56a", "Jordan Lee", "7201@pbx.example.com"))        // only digits are matched
    }
}
