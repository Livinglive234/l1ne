package com.livenet.l1ne.core

import kotlin.test.Test
import kotlin.test.assertEquals

class AccountTitleTest {
    @Test fun twoAccountsOnOneServerAreToldApart() {
        assertEquals("pbx.example.com (7001)", Account(username = "7001", domain = "pbx.example.com").titleWithUser)
        assertEquals("pbx.example.com (7002)", Account(username = "7002", domain = "pbx.example.com").titleWithUser)
    }
    @Test fun aLabelIsKeptAndNoUserMeansNoBrackets() {
        assertEquals("Work (7001)", Account(username = "7001", domain = "pbx.example.com", label = "Work").titleWithUser)
        assertEquals("pbx.example.com", Account(domain = "pbx.example.com").titleWithUser)
    }
}
