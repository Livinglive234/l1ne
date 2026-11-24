package com.livenet.l1ne.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.livenet.l1ne.R
import com.livenet.l1ne.core.Account
import com.livenet.l1ne.core.Transport
import kotlinx.coroutines.delay

/**
 * What you see before any account exists: sign in with the three things a PBX admin hands out, or scan their QR code
 * or open their setup link. It uses the same Account / AccountStore / LinkDialog code as Settings → Accounts, so there
 * is only one way an account gets made. Same layout as the iOS WelcomeView.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WelcomeScreen(signingIn: Boolean, setSigningIn: (Boolean) -> Unit) {
    val app = LocalApp.current
    val reg by app.engine.registration.collectAsState()
    val focus = LocalFocusManager.current
    var server by remember { mutableStateOf("") }; var username by remember { mutableStateOf("") }; var password by remember { mutableStateOf("") }
    var reveal by remember { mutableStateOf(false) }; var transport by remember { mutableStateOf(Transport.TLS) }
    var pending by remember { mutableStateOf<String?>(null) }; var error by remember { mutableStateOf<String?>(null) }
    var showLink by remember { mutableStateOf(false) }; var scanFirst by remember { mutableStateOf(false) }
    var manual by remember { mutableStateOf(false) }; var help by remember { mutableStateOf(false) }
    val canLogin = server.isNotBlank() && username.isNotBlank() && password.isNotEmpty()

    fun removePending() { pending?.let { app.engine.unregister(it); app.store.remove(it) }; pending = null }
    fun fail(message: String) { removePending(); error = message; setSigningIn(false) }
    fun login() {
        focus.clearFocus(); error = null
        val acc = Account(username = username.trim()).withTransport(transport).finishedNew(server)   // parses "host:port", keeps SRTP only on TLS
        app.store.save(acc, password)
        pending = acc.id; setSigningIn(true)                 // keeps this screen up while the PBX answers
        app.engine.register(acc)
    }

    val status = pending?.let { reg[it] }
    LaunchedEffect(pending, status) {
        if (pending == null || status == null) return@LaunchedEffect
        when {
            status == "Registered" -> { pending = null; setSigningIn(false) }
            status.startsWith("Not registered") || status.startsWith("Could not add") -> fail(explainRegistration(status))
        }
    }
    LaunchedEffect(pending) {       // a PBX that never answers: give up after 25 s rather than spin forever
        val id = pending ?: return@LaunchedEffect
        delay(25_000)
        if (pending == id) fail("${server.trim()} didn't answer. Check the server name and your connection.")
    }

    @Composable fun Labeled(title: String, content: @Composable () -> Unit) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) { Text(title, fontWeight = FontWeight.SemiBold, color = L1neColors.Text); content() }
    }
    @Composable fun Input(value: String, onChange: (String) -> Unit, placeholder: String, kb: KeyboardType, ime: ImeAction, secret: Boolean = false, trailing: @Composable (() -> Unit)? = null) =
        OutlinedTextField(value, onChange, Modifier.fillMaxWidth(), singleLine = true, shape = CircleShape, placeholder = { Text(placeholder, color = L1neColors.Muted) },
            visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None, trailingIcon = trailing,
            keyboardOptions = KeyboardOptions(keyboardType = kb, imeAction = ime, autoCorrectEnabled = false),
            keyboardActions = KeyboardActions(onNext = { focus.moveFocus(FocusDirection.Down) }, onGo = { if (canLogin) login() }),
            colors = OutlinedTextFieldDefaults.colors(focusedContainerColor = L1neColors.Surface, unfocusedContainerColor = L1neColors.Surface,
                focusedBorderColor = L1neColors.Brand, unfocusedBorderColor = L1neColors.Border, cursorColor = L1neColors.Brand))

    BoxWithConstraints(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).imePadding().heightIn(min = maxHeight).systemBarsPadding(), verticalArrangement = Arrangement.SpaceBetween) {
            Column(Modifier.widthIn(max = 520.dp).align(Alignment.CenterHorizontally).padding(horizontal = 24.dp, vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(14.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Image(painterResource(R.drawable.welcome_logo), null, Modifier.size(76.dp).clip(RoundedCornerShape(18.dp)))
                Text("Welcome to L1ne", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, color = L1neColors.Text)
                Text("Sign in with the details your PBX administrator gave you, or scan their QR code.", textAlign = TextAlign.Center, color = L1neColors.Muted, style = MaterialTheme.typography.bodyMedium)

                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Labeled("Server") { Input(server, { server = it }, "pbx.example.com", KeyboardType.Uri, ImeAction.Next) }
                    Labeled("Username or extension") { Input(username, { username = it }, "Username", KeyboardType.Text, ImeAction.Next) }
                    Labeled("Password") { Input(password, { password = it }, "Password", KeyboardType.Password, ImeAction.Go, secret = !reveal,
                        trailing = { IconButton({ reveal = !reveal }) { Icon(if (reveal) Icons.Filled.Visibility else Icons.Filled.VisibilityOff, if (reveal) "Hide password" else "Show password", tint = L1neColors.Muted) } }) }
                    Labeled("Transport") {
                        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                            Transport.entries.forEachIndexed { i, t ->
                                SegmentedButton(transport == t, { transport = t }, SegmentedButtonDefaults.itemShape(i, Transport.entries.size),
                                    colors = SegmentedButtonDefaults.colors(activeContainerColor = L1neColors.Brand.copy(alpha = 0.22f), activeContentColor = L1neColors.Text, inactiveContainerColor = L1neColors.Surface, inactiveContentColor = L1neColors.Text,
                                        activeBorderColor = L1neColors.Brand, inactiveBorderColor = L1neColors.Border)) { Text(t.wire.uppercase()) }
                            }
                        }
                    }
                }
                error?.let { Text(it, color = L1neColors.Danger, textAlign = TextAlign.Center, style = MaterialTheme.typography.bodySmall) }
                Button(::login, Modifier.fillMaxWidth().height(50.dp), enabled = canLogin && pending == null, shape = CircleShape,
                    colors = ButtonDefaults.buttonColors(containerColor = L1neColors.Brand, contentColor = L1neColors.OnBrand, disabledContainerColor = L1neColors.Brand.copy(alpha = 0.4f), disabledContentColor = L1neColors.OnBrand)) {
                    if (pending != null) { CircularProgressIndicator(Modifier.size(18.dp), color = L1neColors.OnBrand, strokeWidth = 2.dp); Spacer(Modifier.width(10.dp)) }
                    Text(if (pending != null) "Signing in…" else "Login", fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.titleMedium)
                }
                if (pending != null) {
                    TextButton({ removePending(); error = null; setSigningIn(false) }) { Text("Cancel", color = L1neColors.Muted) }
                } else {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        HorizontalDivider(Modifier.weight(1f), color = L1neColors.Border); Text("or", color = L1neColors.Muted); HorizontalDivider(Modifier.weight(1f), color = L1neColors.Border)
                    }
                    OutlinedButton({ scanFirst = true; showLink = true }, Modifier.fillMaxWidth().height(50.dp), shape = CircleShape, border = BorderStroke(1.5.dp, L1neColors.Brand),
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = L1neColors.Brand)) {
                        Icon(Icons.Filled.QrCodeScanner, null); Spacer(Modifier.width(8.dp)); Text("Scan QR code", fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.titleMedium)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton({ scanFirst = false; showLink = true }) { Icon(Icons.Filled.Link, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("Open a setup link", color = L1neColors.Brand) }
                        TextButton({ manual = true }) { Icon(Icons.Filled.Tune, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("More options", color = L1neColors.Brand) }
                    }
                    Column(Modifier.fillMaxWidth()) {
                        TextButton({ help = !help }, Modifier.fillMaxWidth(), contentPadding = PaddingValues(horizontal = 4.dp)) {
                            Text("Where do I find these?", Modifier.weight(1f), color = L1neColors.Text, fontWeight = FontWeight.Medium)
                            Icon(if (help) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, null, tint = L1neColors.Muted)
                        }
                        if (help) Column(Modifier.padding(horizontal = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            for (line in listOf(
                                "Server is your PBX's address, like pbx.example.com. Add a port if it isn't the usual one: pbx.example.com:5080.",
                                "Username is your extension number or SIP username, and Password is the SIP password, not your PBX web login.",
                                "Your administrator may also have a QR code or a link that fills all of this in.",
                                "L1ne has no sign-up of its own: it connects to a phone system someone runs. Your login stays on this phone."))
                                Text(line, style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted)
                        }
                    }
                }
            }
            Waves()
        }
    }
    if (showLink) LinkDialog(null, autoScan = scanFirst) { showLink = false }
    if (manual) Surface(Modifier.fillMaxSize(), color = L1neColors.Bg) { AccountEditorScreen(null) { manual = false } }
}

/** Plain words for the usual ways a first login goes wrong. */
private fun explainRegistration(status: String): String {
    val code = Regex("""\b(\d{3})\b""").find(status)?.value?.toIntOrNull() ?: 0
    return when (code) {
        401, 403 -> "The PBX refused that username or password. Check them and try again."
        404 -> "The PBX doesn't know that username or extension."
        408, 503, 504 -> "Couldn't reach the PBX. Check the server name and your connection."
        else -> "Couldn't sign in: ${status.removePrefix("Not registered: ")}"
    }
}

/** Soft layered hills along the bottom edge, in the brand green. */
@Composable
private fun Waves() {
    val brand = L1neColors.Brand
    Canvas(Modifier.fillMaxWidth().height(90.dp)) {
        fun hills(a: Float, b: Float, c: Float, alpha: Float) {
            val w = size.width; val h = size.height
            val p = Path().apply {
                moveTo(0f, h); lineTo(0f, h * (1 - a))
                cubicTo(w * 0.2f, h * (1 - a - 0.25f), w * 0.35f, h * (1 - b + 0.1f), w * 0.5f, h * (1 - b))
                cubicTo(w * 0.68f, h * (1 - b - 0.2f), w * 0.85f, h * (1 - c + 0.1f), w, h * (1 - c))
                lineTo(w, h); close()
            }
            drawPath(p, brand.copy(alpha = alpha))
        }
        hills(0.55f, 0.35f, 0.75f, 0.10f); hills(0.45f, 0.30f, 0.55f, 0.16f); hills(0.30f, 0.45f, 0.40f, 0.26f)
    }
}
