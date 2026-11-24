package com.livenet.l1ne

import com.livenet.l1ne.sip.RingbackTone
import com.livenet.l1ne.ui.T9
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class UiLogicTest {
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
    @Test fun everyRingbackToneIsASaneLoop() {
        for (t in RingbackTone.entries) {
            val pcm = t.pcm()
            if (t == RingbackTone.NONE) { assertEquals(0, pcm.size); continue }
            val seconds = pcm.size / 16000.0
            assertTrue(seconds in 2.5..7.0, "$t lasts $seconds s")
            assertTrue(pcm.maxOf { it.toInt() } in 3000..12000, "$t peak")                  // audible but not loud
            assertTrue(pcm.takeLast(800).all { kotlin.math.abs(it.toInt()) < 200 }, "$t ends in silence, so it loops without a click")
            assertEquals(0, pcm.first().toInt())
        }
    }
    @Test fun classicToneCadenceIsTwoOnFourOff() {
        val pcm = RingbackTone.US.pcm()
        assertEquals(6 * 16000, pcm.size)
        assertTrue(pcm.slice(16000 until 31000).any { kotlin.math.abs(it.toInt()) > 3000 })          // sounding during the first two seconds
        assertTrue(pcm.slice(34000 until 90000).all { it.toInt() == 0 })                               // silent for the rest
    }
}
