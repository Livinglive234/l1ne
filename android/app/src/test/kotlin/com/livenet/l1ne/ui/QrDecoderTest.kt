package com.livenet.l1ne.ui

import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import java.nio.ByteBuffer
import kotlin.test.assertEquals
import kotlin.test.assertNull
import org.junit.Test

/** The QR reader, checked with codes made by ZXing's own writer and then bent the ways a real camera frame is. */
class QrDecoderTest {
    /** A square frame of brightness bytes holding the code: black 0, white 255. */
    private fun frame(text: String, size: Int = 300): ByteArray {
        val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size)
        return ByteArray(size * size) { i -> if (m.get(i % size, i / size)) 0 else 255.toByte() }
    }
    private fun rotate90(a: ByteArray, n: Int) = ByteArray(n * n).also { for (y in 0 until n) for (x in 0 until n) it[x * n + (n - 1 - y)] = a[y * n + x] }
    private fun invert(a: ByteArray) = ByteArray(a.size) { (255 - (a[it].toInt() and 0xFF)).toByte() }

    private val setupLink = "https://pbx.example.com/provisioning/l1ne.xml?user=7201&token=0123456789abcdef0123456789abcdef&lang=en&secure=1&ref=qr-setup-sheet"

    @Test fun readsAShortCode() = assertEquals("l1ne-config:https://pbx.example.com/c.xml", QrDecoder.decode(frame("l1ne-config:https://pbx.example.com/c.xml"), 300, 300))

    @Test fun readsALongSetupLink() = assertEquals(setupLink, QrDecoder.decode(frame(setupLink, 420), 420, 420))

    @Test fun readsACodeTurnedAnyWay() {
        var f = frame(setupLink, 420)
        repeat(4) { assertEquals(setupLink, QrDecoder.decode(f, 420, 420)); f = rotate90(f, 420) }
    }

    @Test fun readsALightCodeOnADarkBackground() = assertEquals(setupLink, QrDecoder.decode(invert(frame(setupLink, 420)), 420, 420))

    @Test fun readsASmallCodeInsideABiggerFrame() {
        val code = frame("sip:7201@pbx.example.com", 160)
        val w = 640; val h = 480
        val big = ByteArray(w * h) { 128.toByte() }
        for (y in 0 until 160) System.arraycopy(code, y * 160, big, (y + 200) * w + 300, 160)    // somewhere off to the side
        assertEquals("sip:7201@pbx.example.com", QrDecoder.decode(big, w, h))
    }

    @Test fun packLumaDropsTheRowPaddingCamerasAdd() {
        val n = 300; val stride = n + 40
        val code = frame(setupLink.take(60), n)
        val padded = ByteArray(stride * n) { 77 }
        for (y in 0 until n) System.arraycopy(code, y * n, padded, y * stride, n)
        val packed = QrDecoder.packLuma(ByteBuffer.wrap(padded), n, n, stride)
        assertEquals(code.toList(), packed.toList())
        assertEquals(setupLink.take(60), QrDecoder.decode(packed, n, n))
    }

    @Test fun anEmptyFrameOrNoiseGivesNothing() {
        assertNull(QrDecoder.decode(ByteArray(300 * 300) { 255.toByte() }, 300, 300))
        val rnd = java.util.Random(7)
        assertNull(QrDecoder.decode(ByteArray(300 * 300).also { rnd.nextBytes(it) }, 300, 300))
    }
}
