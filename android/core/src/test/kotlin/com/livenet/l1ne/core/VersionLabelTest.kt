package com.livenet.l1ne.core

import kotlin.test.Test
import kotlin.test.assertEquals

class VersionLabelTest {
    @Test fun aTagVersionReadsNaturally() {
        assertEquals("0.1.0 beta 9", VersionLabel.pretty("0.1.0-beta.9")); assertEquals("0.1.0 rc1", VersionLabel.pretty("0.1.0-rc1"))
        assertEquals("0.1.0", VersionLabel.pretty("0.1.0")); assertEquals("1.0", VersionLabel.pretty("1.0")); assertEquals("0.0.0 abc1234", VersionLabel.pretty("0.0.0-abc1234"))
    }
}
