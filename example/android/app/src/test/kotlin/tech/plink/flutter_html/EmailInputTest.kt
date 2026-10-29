package tech.plink.flutter_html

import java.io.ByteArrayInputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class EmailInputTest {
    @Test
    fun acceptsEmptyAndExactLimit() {
        assertArrayEquals(byteArrayOf(), ByteArrayInputStream(byteArrayOf()).readEmailBytes(0))
        val input = ByteArray(20) { it.toByte() }
        assertArrayEquals(input, ByteArrayInputStream(input).readEmailBytes(input.size))
    }

    @Test
    fun rejectsOversizeWithoutConsumingTheWholeStream() {
        val stream = ByteArrayInputStream(ByteArray(100000))
        assertThrows(EmailInputTooLarge::class.java) { stream.readEmailBytes(20) }
        assertEquals(100000 - 21, stream.available())
    }

    @Test
    fun acceptsStreamsThatReturnShortChunks() {
        val input = ByteArray(17000) { (it % 251).toByte() }
        val stream = object : ByteArrayInputStream(input) {
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
                super.read(buffer, offset, minOf(length, 3))
        }
        assertArrayEquals(input, stream.readEmailBytes(input.size))
    }
}
