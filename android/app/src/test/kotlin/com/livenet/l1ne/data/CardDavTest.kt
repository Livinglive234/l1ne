package com.livenet.l1ne.data

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.assertFailsWith

class CardDavTest {
    private val card = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Ada Lovelace\r\nIMPP:sip:7201@pbx.example.com\r\nEND:VCARD"

    @Test fun oneReportReturnsEveryCard() {
        MockWebServer().use { srv ->
            srv.enqueue(MockResponse().setResponseCode(207).setBody("""<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:carddav"><d:response><d:propstat><d:prop><c:address-data>$card</c:address-data></d:prop></d:propstat></d:response></d:multistatus>"""))
            val r = CardDav.fetch(srv.url("/book/").toString(), "u", "p")
            val req = srv.takeRequest()
            assertEquals("REPORT", req.method); assertEquals("Basic dTpw", req.getHeader("Authorization")); assertTrue(req.body.readUtf8().contains("addressbook-query"))
            assertEquals(1, r.entries.size); assertEquals("Ada Lovelace", r.entries[0].name)
        }
    }

    @Test fun aServerThatRefusesReportGetsAPropfindListAndOneGetPerCard() {
        MockWebServer().use { srv ->
            srv.enqueue(MockResponse().setResponseCode(405))
            srv.enqueue(MockResponse().setResponseCode(207).setBody("""<d:multistatus xmlns:d="DAV:"><d:response><d:href>/book/ada.vcf</d:href></d:response><d:response><d:href>/book/</d:href></d:response></d:multistatus>"""))
            srv.enqueue(MockResponse().setResponseCode(200).setBody(card))
            val r = CardDav.fetch(srv.url("/book/").toString(), "", "")
            assertEquals(listOf("REPORT", "PROPFIND", "GET"), listOf(srv.takeRequest().method, srv.takeRequest().method, srv.takeRequest().method))
            assertEquals(1, r.entries.size)
        }
    }

    @Test fun wrongPasswordAndMissingBookSayWhat() {
        MockWebServer().use { srv ->
            srv.enqueue(MockResponse().setResponseCode(401)); srv.enqueue(MockResponse().setResponseCode(404))
            assertTrue(assertFailsWith<IllegalStateException> { CardDav.fetch(srv.url("/").toString(), "u", "x") }.message!!.contains("401"))
            assertTrue(assertFailsWith<IllegalStateException> { CardDav.fetch(srv.url("/").toString(), "u", "x") }.message!!.contains("404"))
        }
    }
}
