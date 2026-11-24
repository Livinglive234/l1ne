package com.livenet.l1ne.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

enum class Appearance(val label: String) { SYSTEM("System"), LIGHT("Light"), DARK("Dark") }

/** App-wide settings (not tied to one account), kept in SharedPreferences. Same list as iOS's AppSettings. */
class AppSettings(context: Context) {
    private val p = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private fun bool(key: String, def: Boolean) = MutableStateFlow(p.getBoolean(key, def))
    private fun <T> StateFlow<T>.save(key: String, v: T) { (this as MutableStateFlow<T>).value = v
        p.edit().apply { when (v) { is Boolean -> putBoolean(key, v); is String -> putString(key, v); else -> {} } }.apply() }

    val autoRecordF = bool("autoRecord", false); var autoRecord get() = autoRecordF.value; set(v) = autoRecordF.save("autoRecord", v)
    val acceptEarlyMediaF = bool("acceptEarlyMedia", true); var acceptEarlyMedia get() = acceptEarlyMediaF.value; set(v) { acceptEarlyMediaF.save("acceptEarlyMedia", v); com.livenet.l1ne.sip.Native.nEarlyMedia(v) }
    val outEarlyMediaF = bool("outEarlyMedia", false); var allowOutgoingEarlyMedia get() = outEarlyMediaF.value; set(v) = outEarlyMediaF.save("outEarlyMedia", v)
    val wifiOnlyF = bool("wifiOnly", false); var wifiOnly get() = wifiOnlyF.value; set(v) = wifiOnlyF.save("wifiOnly", v)
    val allowIPv6F = bool("allowIPv6", true); var allowIPv6 get() = allowIPv6F.value; set(v) = allowIPv6F.save("allowIPv6", v)
    val keepAliveF = bool("keepAlive", true); var keepAlive get() = keepAliveF.value; set(v) = keepAliveF.save("keepAlive", v)
    val vmTabF = bool("vmTab", false); var showVoicemailTab get() = vmTabF.value; set(v) = vmTabF.save("vmTab", v)
    val vmKeypadF = bool("vmKeypad", true); var showKeypadVoicemail get() = vmKeypadF.value; set(v) = vmKeypadF.save("vmKeypad", v)
    val vmNotifyF = bool("vmNotify", false); var voicemailNotify get() = vmNotifyF.value; set(v) = vmNotifyF.save("vmNotify", v)
    val provisioningF = MutableStateFlow(p.getString("provisioningURL", "") ?: ""); var provisioningURL get() = provisioningF.value; set(v) = provisioningF.save("provisioningURL", v)
    val appearanceF = MutableStateFlow(Appearance.entries.firstOrNull { it.name == p.getString("appearance", "") } ?: Appearance.SYSTEM)
    var appearance get() = appearanceF.value; set(v) { appearanceF.value = v; p.edit().putString("appearance", v.name).apply() }

    /** Codec ids ("PCMU/8000/1") in the order they are offered, and the ones switched off. */
    val codecOrderF = MutableStateFlow(p.getString("codecOrder", "")!!.split(",").filter { it.isNotEmpty() })
    val codecsOffF = MutableStateFlow(p.getString("codecsOff", "")!!.split(",").filter { it.isNotEmpty() }.toSet())
    var codecOrder get() = codecOrderF.value; set(v) { codecOrderF.value = v; p.edit().putString("codecOrder", v.joinToString(",")).apply() }
    var codecsOff get() = codecsOffF.value; set(v) { codecsOffF.value = v; p.edit().putString("codecsOff", v.joinToString(",")).apply() }
}
