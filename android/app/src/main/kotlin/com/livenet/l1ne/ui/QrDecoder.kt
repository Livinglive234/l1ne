package com.livenet.l1ne.ui

import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.ChecksumException
import com.google.zxing.DecodeHintType
import com.google.zxing.FormatException
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import java.nio.ByteBuffer

/**
 * Reads a QR code from one camera frame, using the open-source ZXing decoder (no Google library, works offline, about 0.5 MB).
 * It works on the brightness plane of the frame (the "Y" bytes of a YUV image), so colour is not needed.
 */
object QrDecoder {
    private val hints = mapOf<DecodeHintType, Any>(
        DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
        DecodeHintType.TRY_HARDER to true,
    )

    /** [luma] is width x height brightness bytes, row after row with no padding. Returns the code's text, or null if none is readable. */
    fun decode(luma: ByteArray, width: Int, height: Int): String? {
        val source = PlanarYUVLuminanceSource(luma, width, height, 0, 0, width, height, false)
        return attempt(BinaryBitmap(HybridBinarizer(source)))
            ?: attempt(BinaryBitmap(HybridBinarizer(source.invert())))      // light code on a dark background
    }

    private fun attempt(bitmap: BinaryBitmap): String? =
        try { QRCodeReader().decode(bitmap, hints).text }
        catch (_: NotFoundException) { null }
        catch (_: ChecksumException) { null }
        catch (_: FormatException) { null }

    /** Copies the brightness plane of a camera image into a tightly packed array; cameras often pad each row ([rowStride] >= [width]). */
    fun packLuma(plane: ByteBuffer, width: Int, height: Int, rowStride: Int): ByteArray {
        val out = ByteArray(width * height)
        val buffer = plane.duplicate()
        for (row in 0 until height) {
            buffer.position(row * rowStride)
            buffer.get(out, row * width, width)
        }
        return out
    }
}
