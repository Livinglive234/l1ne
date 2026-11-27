package com.livenet.l1ne.core

import kotlin.test.Test
import kotlin.test.assertEquals

class OutboundPrefixTest {
    private val a = Account(username = "7001", domain = "pbx.example.com", outboundPrefix = "9")

    @Test fun outsideNumbersGetThePrefix() {
        assertEquals("96125550142", a.dial("6125550142"))
        assertEquals("96125550142", a.dial("(612) 555-0142"))
        assertEquals("916125550142", a.dial("16125550142"))
        assertEquals("916125550142", a.dial("+16125550142"))
    }
    @Test fun extensionsAndCodesAreLeftAlone() {
        for (n in listOf("7001", "2997", "0", "*97", "911")) assertEquals(n, a.dial(n), n)
    }
    @Test fun aNumberThatAlreadyHasThePrefixIsLeftAlone() = assertEquals("96125550142", a.dial("96125550142"))
    @Test fun noPrefixSetChangesNothing() = assertEquals("6125550142", a.copy(outboundPrefix = "").dial("6125550142"))
    @Test fun itWorksTogetherWithTheOtherDialRules() {
        val b = a.copy(formatWithPrefix = true, intlPrefix = "1", plusTo00 = true)
        assertEquals("96125550142", b.dial("6125550142"))          // no country code on top of an outside number
        assertEquals("0044207123456789", b.dial("+44207123456789")) // the other rules still do their job for everything else
    }
    @Test fun historyKeepsTheNumberWithoutThePrefix() {
        assertEquals("6125550142@pbx.example.com", a.withoutOutboundPrefix("96125550142@pbx.example.com"))
        assertEquals("7001@pbx.example.com", a.withoutOutboundPrefix("7001@pbx.example.com"))
        assertEquals("9125550142@pbx.example.com", a.withoutOutboundPrefix("9125550142@pbx.example.com"))   // a real 912 number, not prefixed
        assertEquals("96125550142", a.copy(outboundPrefix = "").withoutOutboundPrefix("96125550142"))
    }
}
