package com.livenet.l1ne.core

import kotlin.test.Test
import kotlin.test.assertEquals

class PhoneFormatTest {
    @Test fun bareUsNumbersGetFormatted() {
        assertEquals("(651) 760-4266", PhoneFormat.pretty("6517604266"))
        assertEquals("(651) 760-4266", PhoneFormat.pretty("16517604266"))
        assertEquals("(651) 760-4266", PhoneFormat.pretty("+16517604266"))
        assertEquals("(612) 354-0645", PhoneFormat.pretty(" 6123540645 "))
    }
    @Test fun everythingElseIsLeftAlone() {
        for (s in listOf("7001", "2993", "5550142", "(612) 354-0645", "Max Example", "kai-phone", "+442071234567", "0123456789", "61235406451", "612354064", ""))
            assertEquals(s, PhoneFormat.pretty(s), s)
    }

    @Test fun outsideNumbersAreTold() {
        for (s in listOf("6125550142", "16125550142", "+16125550142")) assertEquals(true, PhoneFormat.isOutside(s), s)
        for (s in listOf("7001", "2993", "0", "*97", "96125550142", "061255501", "+442071234567", "")) assertEquals(false, PhoneFormat.isOutside(s), s)
    }
}
