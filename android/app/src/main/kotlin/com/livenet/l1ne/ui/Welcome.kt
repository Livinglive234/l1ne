package com.livenet.l1ne.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.zIndex
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.livenet.l1ne.R
import com.livenet.l1ne.core.Account
import com.livenet.l1ne.core.Transport
import kotlinx.coroutines.delay

/**
 * What you see before any account exists: sign in with the details a PBX admin hands out, or scan their QR code or
 * open their setup link. It uses the same Account / AccountStore / LinkDialog code as Settings → Accounts, so there
 * is only one way an account gets made. Same layout as the iOS WelcomeView: everything fits on one screen on a normal
 * phone (it scrolls on a small one), and the hills are fixed to the bottom edge of the screen.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WelcomeScreen(signingIn: Boolean, setSigningIn: (Boolean) -> Unit, onClose: (() -> Unit)? = null) {
    val app = LocalApp.current
    // onClose != null means this is "Add account" on top of the tabs: it gets a close button, and it closes itself as soon as an account was added
    val accountList by app.store.accounts.collectAsState()
    val startCount = remember { accountList.size }
    val reg by app.engine.registration.collectAsState()
    val focus = LocalFocusManager.current
    var server by remember { mutableStateOf("") }; var username by remember { mutableStateOf("") }; var displayName by remember { mutableStateOf("") }; var password by remember { mutableStateOf("") }
    var reveal by remember { mutableStateOf(false) }; var transport by remember { mutableStateOf(Transport.TLS) }
    var pending by remember { mutableStateOf<String?>(null) }; var error by remember { mutableStateOf<String?>(null) }
    var showLink by remember { mutableStateOf(false) }; var scanFirst by remember { mutableStateOf(false) }
    var manual by remember { mutableStateOf(false) }; var help by remember { mutableStateOf(false) }
    val canLogin = server.isNotBlank() && username.isNotBlank() && password.isNotEmpty()
    val screenH = LocalConfiguration.current.screenHeightDp
    val compact = screenH < 780            // short or older 16:9 phones: smallest header, no subtitle, tighter fields
    val snug = screenH < 900               // typical phones: slightly tighter, so the form clears the hills

    fun removePending() { pending?.let { app.engine.unregister(it); app.store.remove(it) }; pending = null }
    fun fail(message: String) { removePending(); error = message; setSigningIn(false) }
    // the one way an account gets in: saved, registered, and taken out again if the PBX refuses or doesn't answer (the fields and "More options" both end up here)
    fun submit(acc: Account, pw: String) {
        focus.clearFocus(); error = null
        app.store.save(acc, pw)
        pending = acc.id; setSigningIn(true)                 // keeps this screen up while the PBX answers
        app.engine.register(acc)
    }
    fun login() = submit(Account(username = username.trim(), displayName = displayName.trim()).withTransport(transport).finishedNew(server), password)   // parses "host:port", keeps SRTP only on TLS

    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    val root = remember { androidx.compose.ui.focus.FocusRequester() }
    LaunchedEffect(Unit) { delay(200); root.requestFocus(); keyboard?.hide() }       // some phones put the cursor in the first field on launch; park the focus on the screen itself and start with the keyboard closed
    val status = pending?.let { reg[it] }
    if (onClose != null) {
        androidx.activity.compose.BackHandler(!help && !showLink && !manual) { if (pending != null) { removePending(); error = null; setSigningIn(false) }; onClose() }
        LaunchedEffect(accountList.size, pending) { if (pending == null && accountList.size > startCount) { setSigningIn(false); onClose() } }
    }
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
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) { Text(title, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = L1neColors.Text); content() }
    }
    @Composable fun Input(value: String, onChange: (String) -> Unit, placeholder: String, kb: KeyboardType, ime: ImeAction, secret: Boolean = false,
                          caps: KeyboardCapitalization = KeyboardCapitalization.None, trailing: @Composable (() -> Unit)? = null) {
        var focused by remember { mutableStateOf(false) }
        BasicTextField(value, onChange, Modifier.fillMaxWidth().height(if (compact) 38.dp else if (snug) 42.dp else 46.dp).clip(CircleShape).background(L1neColors.Surface)
            .border(if (focused) 2.dp else 1.dp, if (focused) L1neColors.Brand else L1neColors.Border, CircleShape).onFocusChanged { focused = it.isFocused },
            singleLine = true, textStyle = TextStyle(color = L1neColors.Text, fontSize = 16.sp), cursorBrush = SolidColor(L1neColors.Brand),
            visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
            keyboardOptions = KeyboardOptions(keyboardType = kb, imeAction = ime, capitalization = caps, autoCorrectEnabled = false),
            keyboardActions = KeyboardActions(onNext = { focus.moveFocus(FocusDirection.Down) }, onGo = { if (canLogin) login() }),
            decorationBox = { inner ->
                Row(Modifier.padding(start = 18.dp, end = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) { if (value.isEmpty()) Text(placeholder, color = L1neColors.Muted, fontSize = 16.sp); inner() }
                    trailing?.invoke()
                }
            })
    }

    Box(Modifier.fillMaxSize().focusRequester(root).focusable()) {
        Waves(Modifier.align(Alignment.BottomCenter))           // attached to the bottom edge of the screen, whatever its size
        if (onClose != null) IconButton({ if (pending != null) { removePending(); error = null; setSigningIn(false) }; onClose() }, Modifier.align(Alignment.TopStart).zIndex(1f).systemBarsPadding().padding(4.dp)) { Icon(Icons.Filled.Close, "Close", tint = L1neColors.Text) }
        val scroll = rememberScrollState()
        val imeOpen = androidx.compose.foundation.layout.WindowInsets.ime.getBottom(androidx.compose.ui.platform.LocalDensity.current) > 0
        // only scrolls when it has to: content taller than the screen (a small phone) or the keyboard is up
        Column(Modifier.fillMaxSize().systemBarsPadding().imePadding().verticalScroll(scroll, enabled = scroll.maxValue > 0 || imeOpen), horizontalAlignment = Alignment.CenterHorizontally) {
            Column(Modifier.widthIn(max = 520.dp).padding(start = 24.dp, end = 24.dp, top = if (compact) 10.dp else if (snug) 16.dp else 28.dp, bottom = if (compact) 0.dp else if (snug) 4.dp else 24.dp), verticalArrangement = Arrangement.spacedBy(if (compact) 3.dp else if (snug) 6.dp else 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Image(painterResource(R.drawable.welcome_logo), null, Modifier.size(if (compact) 40.dp else if (snug) 46.dp else 64.dp).clip(RoundedCornerShape(14.dp)))
                Text("Welcome to L1ne", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = L1neColors.Text)
                if (!compact) Text("Sign in to your PBX, or scan its QR code.", textAlign = TextAlign.Center, color = L1neColors.Muted, style = MaterialTheme.typography.bodyMedium)

                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(if (compact) 8.dp else if (snug) 12.dp else 16.dp)) {
                    Labeled("Server") { Input(server, { server = it }, "pbx.example.com", KeyboardType.Uri, ImeAction.Next) }
                    Labeled("Username or extension") { Input(username, { username = it }, "Username", KeyboardType.Text, ImeAction.Next) }
                    Labeled("Display name (optional)") { Input(displayName, { displayName = it }, "Shown to people you call", KeyboardType.Text, ImeAction.Next, caps = KeyboardCapitalization.Words) }
                    Labeled("Password (Secret)") { Input(password, { password = it }, "Password", KeyboardType.Password, ImeAction.Go, secret = !reveal,
                        trailing = { IconButton({ reveal = !reveal }, Modifier.size(36.dp)) { Icon(if (reveal) Icons.Filled.Visibility else Icons.Filled.VisibilityOff, if (reveal) "Hide password" else "Show password", tint = L1neColors.Muted) } }) }
                    Labeled("Transport") {
                        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().height(if (compact) 32.dp else 36.dp)) {
                            Transport.entries.forEachIndexed { i, t ->
                                SegmentedButton(transport == t, { transport = t }, SegmentedButtonDefaults.itemShape(i, Transport.entries.size), icon = {},
                                    colors = SegmentedButtonDefaults.colors(activeContainerColor = L1neColors.Brand.copy(alpha = 0.22f), activeContentColor = L1neColors.Text, inactiveContainerColor = L1neColors.Surface, inactiveContentColor = L1neColors.Text,
                                        activeBorderColor = L1neColors.Brand, inactiveBorderColor = L1neColors.Border)) { Text(t.wire.uppercase()) }
                            }
                        }
                    }
                }
                Spacer(Modifier.height(if (compact) 2.dp else if (snug) 4.dp else 12.dp))
                error?.let { Text(it, color = L1neColors.Danger, textAlign = TextAlign.Center, style = MaterialTheme.typography.bodySmall) }
                Button(::login, Modifier.fillMaxWidth().height(if (compact) 42.dp else 46.dp), enabled = canLogin && pending == null, shape = CircleShape,
                    colors = ButtonDefaults.buttonColors(containerColor = L1neColors.Brand, contentColor = L1neColors.OnBrand, disabledContainerColor = L1neColors.Brand.copy(alpha = 0.4f), disabledContentColor = L1neColors.OnBrand)) {
                    if (pending != null) { CircularProgressIndicator(Modifier.size(18.dp), color = L1neColors.OnBrand, strokeWidth = 2.dp); Spacer(Modifier.width(10.dp)) }
                    Text(if (pending != null) "Signing in…" else "Login", fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.titleMedium)
                }
                if (pending != null) {
                    TextButton({ removePending(); error = null; setSigningIn(false) }) { Text("Cancel", color = L1neColors.Muted) }
                } else {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        HorizontalDivider(Modifier.weight(1f), color = L1neColors.Border); Text("or", color = L1neColors.Muted, fontSize = 14.sp); HorizontalDivider(Modifier.weight(1f), color = L1neColors.Border)
                    }
                    OutlinedButton({ scanFirst = true; showLink = true }, Modifier.fillMaxWidth().height(if (compact) 40.dp else 44.dp), shape = CircleShape, border = BorderStroke(1.5.dp, L1neColors.Brand),
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = L1neColors.Brand)) {
                        Icon(Icons.Filled.QrCodeScanner, null); Spacer(Modifier.width(8.dp)); Text("Scan QR code", fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.titleMedium)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton({ scanFirst = false; showLink = true }, Modifier.heightIn(min = if (compact) 30.dp else 40.dp), contentPadding = PaddingValues(horizontal = 12.dp, vertical = if (compact) 0.dp else 8.dp)) { Icon(Icons.Filled.Link, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("Open a setup link", color = L1neColors.Brand) }
                        TextButton({ manual = true }, Modifier.heightIn(min = if (compact) 30.dp else 40.dp), contentPadding = PaddingValues(horizontal = 12.dp, vertical = if (compact) 0.dp else 8.dp)) { Icon(Icons.Filled.Tune, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("More options", color = L1neColors.Brand) }
                    }
                    TextButton({ help = true }, Modifier.fillMaxWidth().heightIn(min = if (compact) 30.dp else 40.dp), contentPadding = PaddingValues(horizontal = 12.dp, vertical = if (compact) 0.dp else 8.dp)) {
                        Text("Where do I find these?", color = L1neColors.Text, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center)
                    }
                }
            }
        }
        androidx.activity.compose.BackHandler(help) { help = false }
        androidx.compose.animation.AnimatedVisibility(help, enter = androidx.compose.animation.fadeIn(), exit = androidx.compose.animation.fadeOut()) {
            Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.55f))
                .clickable(interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }, indication = null) { help = false })
        }
        androidx.compose.animation.AnimatedVisibility(help, Modifier.align(Alignment.BottomCenter), enter = androidx.compose.animation.slideInVertically { it }, exit = androidx.compose.animation.slideOutVertically { it }) {
            Surface(Modifier.fillMaxWidth().widthIn(max = 640.dp), shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp), color = L1neColors.SheetBg) {
                Column(Modifier.navigationBarsPadding().heightIn(max = (screenH * 0.85f).dp).verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
                    Box(Modifier.padding(top = 10.dp, bottom = 6.dp).size(width = 40.dp, height = 4.dp).clip(CircleShape).background(L1neColors.Border))
                    HelpCard()
                }
            }
        }
    }
    if (showLink) LinkDialog(null, autoScan = scanFirst) { showLink = false }
    if (manual) Surface(Modifier.fillMaxSize(), color = L1neColors.Bg) { AccountEditorScreen(null, onSubmit = ::submit) { manual = false } }
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

/** Soft layered hills in the brand green, drawn to the very bottom of the screen (behind the navigation bar too). */
@Composable
private fun Waves(modifier: Modifier = Modifier) {
    val brand = L1neColors.Brand
    Canvas(modifier.fillMaxWidth().height(96.dp)) {
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

/** The little card that slides up from the bottom (same wording as the iOS one). */
@Composable
private fun HelpCard() {
    @Composable fun Row(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, text: String) =
        androidx.compose.foundation.layout.Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Icon(icon, null, Modifier.size(26.dp), tint = L1neColors.Brand)
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) { Text(title, fontWeight = FontWeight.SemiBold, color = L1neColors.Text); Text(text, style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted) }
        }
    Column(Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, bottom = 24.dp, top = 8.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Where do I find these?", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = L1neColors.Text)
        Row(Icons.Filled.Dns, "Server", "Your PBX's address, like pbx.example.com. Add a port if it isn't the usual one: pbx.example.com:5080.")
        Row(Icons.Filled.Person, "Username or extension", "Your extension number or SIP username.")
        Row(Icons.Filled.Key, "Password (Secret)", "The SIP password for that extension, not your PBX web login.")
        Row(Icons.Filled.QrCode2, "QR code or link", "Your administrator may have one that fills all of this in.")
        Text("L1ne has no sign-up of its own: it connects to a phone system someone runs. Your login stays on this phone.", style = MaterialTheme.typography.bodySmall, color = L1neColors.Muted)
    }
}
