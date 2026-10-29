package tech.plink.flutter_html

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.InterruptedIOException

internal class EmailInputTooLarge : IOException("File is too large to render safely")

/** Bounds even providers with an absent or inaccurate OpenableColumns.SIZE. */
internal fun InputStream.readEmailBytes(maxBytes: Int): ByteArray {
    require(maxBytes >= 0)
    val output = ByteArrayOutputStream(minOf(maxBytes, 8192))
    val buffer = ByteArray(8192)
    var remaining = maxBytes
    while (true) {
        if (Thread.currentThread().isInterrupted) throw InterruptedIOException()
        val chunkSize = if (remaining >= buffer.size) buffer.size else remaining + 1
        val count = read(buffer, 0, chunkSize)
        if (count < 0) return output.toByteArray()
        if (count > remaining) throw EmailInputTooLarge()
        output.write(buffer, 0, count)
        remaining -= count
    }
}
