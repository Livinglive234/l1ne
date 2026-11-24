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
        if (secret != null) {
            val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.ENCRYPT_MODE, key())
            e.putString("secret.${a.id}", Base64.encodeToString(c.iv + c.doFinal(secret.toByteArray()), Base64.NO_WRAP))
        }
        e.apply(); _accounts.value = list
    }

    fun remove(id: String) {
        val list = _accounts.value.filter { it.id != id }
        prefs.edit().putString("list", encode(list)).remove("secret.$id").apply(); _accounts.value = list
    }

    private fun encode(l: List<Account>) = JSONArray(l.map { a ->
        JSONObject().put("id", a.id).put("label", a.label).put("domain", a.domain).put("port", a.port).put("transport", a.transport.wire)
            .put("media", a.media.wire).put("username", a.username).put("authUser", a.authUser).put("contactsUrl", a.contactsUrl)
            .put("dialStripPrefix", a.dialStripPrefix).put("dialAddPrefix", a.dialAddPrefix)
    }).toString()

    private fun load(): List<Account> = runCatching {
        val arr = JSONArray(prefs.getString("list", "[]"))
        (0 until arr.length()).map { arr.getJSONObject(it).let { o ->
            Account(id = o.getString("id"), label = o.optString("label"), domain = o.optString("domain"), port = o.optInt("port", 5061),
                transport = Transport.of(o.optString("transport")) ?: Transport.TLS, media = Media.entries.firstOrNull { it.wire == o.optString("media") } ?: Media.SRTP_SDES,
                username = o.optString("username"), authUser = o.optString("authUser"), contactsUrl = o.optString("contactsUrl"),
                dialStripPrefix = o.optString("dialStripPrefix"), dialAddPrefix = o.optString("dialAddPrefix"))
        } }
    }.getOrDefault(emptyList())
}
