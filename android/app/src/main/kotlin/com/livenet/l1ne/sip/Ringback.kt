package com.livenet.l1ne.sip

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.min
import kotlin.math.sin

/** The tones L1ne can play itself while the other phone is ringing, for when the PBX sends none. Generated here, no audio files. */
enum class RingbackTone(val label: String, private val cadence: List<Seg>) {
    NONE("None (only what the PBX sends)", emptyList()),
    US("Classic phone (North America)", listOf(Seg(2000, listOf(440.0, 480.0)), Seg(4000))),
    UK("Classic phone (UK)", listOf(Seg(400, listOf(400.0, 450.0)), Seg(200), Seg(400, listOf(400.0, 450.0)), Seg(2000))),
    CHIME("Chime", listOf(Seg(260, listOf(1047.0), true), Seg(260, listOf(1319.0), true), Seg(700, listOf(1568.0), true), Seg(2700))),
    DIGITAL("Digital", listOf(Seg(90, listOf(1000.0)), Seg(90), Seg(90, listOf(1000.0)), Seg(2700))),
    PULSE("Pulse", listOf(Seg(320, listOf(523.0), true), Seg(180), Seg(320, listOf(659.0), true), Seg(2700)));

    /** One full cadence as 16 kHz mono 16-bit samples, for looping. */
    fun pcm(): ShortArray {
        val rate = 16000; val out = ArrayList<Short>()
        for (s in cadence) {
            val n = rate * s.ms / 1000
            for (i in 0 until n) {
                var v = 0.0; for (f in s.hz) v += sin(2 * PI * f * i / rate)
                if (s.hz.isNotEmpty()) v /= s.hz.size
                val t = i.toDouble() / n
                val env = (if (s.decay) exp(-4.0 * t) else 1.0) * min(1.0, i / 160.0) * min(1.0, (n - i) / 160.0)     // 10 ms ramps: no clicks
                out.add((v * env * 0.30 * 32767).toInt().toShort())
            }
        }
        return out.toShortArray()
    }
}
class Seg(val ms: Int, val hz: List<Double> = emptyList(), val decay: Boolean = false)

object Ringback {
    private var track: AudioTrack? = null
    private var playing: RingbackTone? = null
    private val main = Handler(Looper.getMainLooper())
    private val stopLater = Runnable { stop() }

    fun start(tone: RingbackTone) {
        if (tone == RingbackTone.NONE) { stop(); return }
        if (playing == tone && track != null) return
        stop()
        val pcm = tone.pcm()
        val t = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(16000).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
            .setBufferSizeInBytes(pcm.size * 2).setTransferMode(AudioTrack.MODE_STATIC).build()
        t.write(pcm, 0, pcm.size); t.setLoopPoints(0, pcm.size, -1); t.play()
        track = t; playing = tone
    }

    fun stop() {
        main.removeCallbacks(stopLater)
        track?.let { runCatching { it.stop() }; it.release() }; track = null; playing = null
    }

    /** Plays a tone for a few seconds, for the picker. */
    fun preview(tone: RingbackTone) { start(tone); main.removeCallbacks(stopLater); main.postDelayed(stopLater, 4000) }
}
