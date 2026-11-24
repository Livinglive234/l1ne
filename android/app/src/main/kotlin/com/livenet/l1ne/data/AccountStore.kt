package com.livenet.l1ne.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.livenet.l1ne.core.Account
import com.livenet.l1ne.core.Media
import com.livenet.l1ne.core.Transport
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec

/** Accounts in SharedPreferences; each password is sealed with an Android Keystore key (it never sits in the file in clear). */
class AccountStore(context: Context) {
    private val prefs = context.getSharedPreferences("accounts", Context.MODE_PRIVATE)
    private val _accounts = MutableStateFlow(load())
    val accounts: StateFlow<List<Account>> = _accounts

    private val _selectedId = MutableStateFlow(prefs.getString("selected", null))
    val selectedId: StateFlow<String?> = _selectedId
    /** The account that dials and whose initials show on the avatar. Falls back to the first account. */
    val selected: Account? get() = _accounts.value.firstOrNull { it.id == _selectedId.value } ?: _accounts.value.firstOrNull()
    fun select(id: String) { _selectedId.value = id; prefs.edit().putString("selected", id).apply() }

    private fun key(): javax.crypto.SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey("l1ne-secrets", null) as? javax.crypto.SecretKey)?.let { return it }
        val g = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        g.init(KeyGenParameterSpec.Builder("l1ne-secrets", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        return g.generateKey()
    }

    fun secret(id: String): String {
        val raw = prefs.getString("secret.$id", null) ?: return ""
        return runCatching {
            val b = Base64.decode(raw, Base64.NO_WRAP)
            val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, b.copyOfRange(0, 12)))
            String(c.doFinal(b, 12, b.size - 12))
        }.getOrDefault("")
    }

    fun save(a: Account, secret: String?) {
        val list = _accounts.value.toMutableList()
        val i = list.indexOfFirst { it.id == a.id }
        if (i >= 0) list[i] = a else list.add(a)
        val e = prefs.edit().putString("list", encode(list))
        e.apply(); _accounts.value = list
        if (secret != null) putSecret(a.id, secret)
    }

    fun putSecretPublic(name: String, v: String) = putSecret(name, v)
    private fun putSecret(name: String, v: String) {
        val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.ENCRYPT_MODE, key())
        prefs.edit().putString("secret.$name", Base64.encodeToString(c.iv + c.doFinal(v.toByteArray()), Base64.NO_WRAP)).apply()
    }

    fun remove(id: String) {
        val list = _accounts.value.filter { it.id != id }
        prefs.edit().putString("list", encode(list)).remove("secret.$id").apply(); _accounts.value = list
    }

    fun turnSecret(id: String) = secret("turn.$id")
    fun saveTurnSecret(id: String, v: String) = putSecret("turn.$id", v)

    private fun encode(l: List<Account>) = JSONArray(l.map { a ->
        JSONObject().put("id", a.id).put("label", a.label).put("displayName", a.displayName).put("domain", a.domain).put("port", a.port)
            .put("transport", a.transport.wire).put("registrarURI", a.registrarURI).put("outboundProxy", a.outboundProxy).put("expires", a.expires)
            .put("enabled", a.enabled).put("media", a.media.wire).put("mediaMandatory", a.mediaMandatory).put("username", a.username)
            .put("authUser", a.authUser).put("contactsUrl", a.contactsUrl).put("dialStripPrefix", a.dialStripPrefix).put("dialAddPrefix", a.dialAddPrefix)
            .put("intlPrefix", a.intlPrefix).put("formatWithPrefix", a.formatWithPrefix).put("plusTo00", a.plusTo00).put("voicemailURI", a.voicemailURI)
            .put("mwiEnabled", a.mwiEnabled).put("iceEnabled", a.iceEnabled).put("turnEnabled", a.turnEnabled).put("stunServer", a.stunServer).put("turnUser", a.turnUser)
    }).toString()

    private fun load(): List<Account> = runCatching {
        val arr = JSONArray(prefs.getString("list", "[]"))
        val d = Account()
        (0 until arr.length()).map { arr.getJSONObject(it).let { o ->
            Account(id = o.getString("id"), label = o.optString("label"), displayName = o.optString("displayName"), domain = o.optString("domain"),
                port = o.optInt("port", 5061), transport = Transport.of(o.optString("transport")) ?: Transport.TLS,
                registrarURI = o.optString("registrarURI"), outboundProxy = o.optString("outboundProxy"), expires = o.optInt("expires", d.expires),
                enabled = o.optBoolean("enabled", true), media = Media.entries.firstOrNull { m -> m.wire == o.optString("media") } ?: Media.SRTP_SDES,
                mediaMandatory = o.optBoolean("mediaMandatory", true), username = o.optString("username"), authUser = o.optString("authUser"),
                contactsUrl = o.optString("contactsUrl"), dialStripPrefix = o.optString("dialStripPrefix"), dialAddPrefix = o.optString("dialAddPrefix"),
                intlPrefix = o.optString("intlPrefix"), formatWithPrefix = o.optBoolean("formatWithPrefix"), plusTo00 = o.optBoolean("plusTo00"),
                voicemailURI = o.optString("voicemailURI", "*97"), mwiEnabled = o.optBoolean("mwiEnabled", true), iceEnabled = o.optBoolean("iceEnabled"),
                turnEnabled = o.optBoolean("turnEnabled"), stunServer = o.optString("stunServer"), turnUser = o.optString("turnUser"))
        } }
    }.getOrDefault(emptyList())
}
