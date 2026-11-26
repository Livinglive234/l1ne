package com.livenet.l1ne

import android.content.res.Configuration
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onLast
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.livenet.l1ne.core.Account
import com.livenet.l1ne.data.Appearance
import com.livenet.l1ne.data.CallRecord
import com.livenet.l1ne.data.Direction
import com.livenet.l1ne.data.Message
import com.livenet.l1ne.ui.L1neApp
import com.livenet.l1ne.ui.L1neTheme
import com.livenet.l1ne.ui.LocalApp
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.test.assertTrue

/**
 * Screen tests: the real app screens on a device or emulator, at different window widths (a phone, a tablet, a foldable's inner screen),
 * with a few contacts, chats and calls in place. No PBX is needed. The width is faked through the configuration the layouts read, so the
 * same test runs on any emulator. These check the two-pane layouts and what happens as the window changes size.
 */
@RunWith(AndroidJUnit4::class)
class ScreenTest {
    @get:Rule val compose = createComposeRule()

    private lateinit var app: L1neApplication
    private lateinit var account: Account
    private val width = mutableIntStateOf(1000)

    @Before fun seed() {
        app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as L1neApplication
        wipe()
        account = Account(label = "screen test", domain = "pbx.test", username = "7100").also { app.store.save(it, "x") }       // an account, so the welcome screen is not shown
        app.contacts.add("Alice Archer", "alice@pbx.test", null); app.contacts.add("Bob Brandt", "bob@pbx.test", null)
        app.messages.add(Message(outgoing = false, text = "Are we still on for lunch?"), account.id, "alice@pbx.test")
        app.callLog.add(CallRecord(peer = "alice@pbx.test", accountID = account.id, direction = Direction.INCOMING, duration = 120))
    }
    @After fun clean() = wipe()
    private fun wipe() {
        app.store.accounts.value.toList().forEach { app.store.remove(it.id) }
        app.contacts.removeAll(); app.messages.removeAll(); app.callLog.removeAll()
    }

    private fun show(widthDp: Int) {
        width.intValue = widthDp
        compose.setContent {
            val cfg = Configuration(LocalConfiguration.current).apply { screenWidthDp = width.intValue }
            CompositionLocalProvider(LocalConfiguration provides cfg, LocalApp provides app) { L1neTheme(Appearance.LIGHT) { L1neApp() } }
        }
    }
    private fun tab(name: String) { compose.onAllNodesWithText(name).onLast().performClick(); compose.waitForIdle() }      // the bottom bar's label comes last (the top bar repeats the name)
    private fun back() = compose.onNodeWithContentDescription("Back")

    // ---- wide windows: the list on the left, the person or conversation on the right ----

    @Test fun aWideWindowShowsContactsAsTwoPanes() {
        show(1000); tab("Contacts")
        compose.onNodeWithText("Nobody selected").assertIsDisplayed()
        compose.onAllNodesWithText("Alice Archer")[0].performClick(); compose.waitForIdle()
        compose.onNodeWithText("SIP address").assertIsDisplayed()
        compose.onAllNodesWithText("Nobody selected").assertCountEquals(0)
        assertTrue(compose.onAllNodesWithText("Alice Archer").fetchSemanticsNodes().size >= 2, "the list row and the card both show the name")
        compose.onAllNodesWithContentDescription("Back").assertCountEquals(0)                 // beside the list there is nothing to go back to
    }
    @Test fun aWideWindowShowsChatsAsTwoPanes() {
        show(1000); tab("Chats")
        compose.onNodeWithText("No chat selected").assertIsDisplayed()
        compose.onAllNodesWithText("Alice Archer")[0].performClick(); compose.waitForIdle()
        assertTrue(compose.onAllNodesWithText("Are we still on for lunch?").fetchSemanticsNodes().size >= 2, "the list preview and the conversation both show the text")
        compose.onAllNodesWithText("No chat selected").assertCountEquals(0)
    }
    @Test fun aWideWindowShowsRecentCallsBesideTheKeypad() {
        show(1000); tab("Keypad")
        compose.onNodeWithText("Recent calls").assertIsDisplayed()
        compose.onNodeWithText("2").performClick(); compose.waitForIdle()                       // 2 = A, B, C: Alice and Bob match
        compose.onNodeWithText("Matching contacts").assertIsDisplayed()
        compose.onAllNodesWithText("Recent calls").assertCountEquals(0)
    }
    @Test fun aWideWindowShowsRecentsAsTwoPanes() {
        show(1000); tab("Recents")
        compose.onNodeWithText("Nobody selected").assertIsDisplayed()
        compose.onAllNodesWithText("Alice Archer")[0].performClick(); compose.waitForIdle()
        compose.onNodeWithText("SIP address").assertIsDisplayed()
    }

    // ---- narrow windows stay as they were ----

    @Test fun aNarrowWindowKeepsContactsAsOneColumnWithAPage() {
        show(400); tab("Contacts")
        compose.onAllNodesWithText("Nobody selected").assertCountEquals(0)
        compose.onAllNodesWithText("Alice Archer")[0].performClick(); compose.waitForIdle()
        compose.onNodeWithText("SIP address").assertIsDisplayed(); back().assertIsDisplayed()
        back().performClick(); compose.waitForIdle()
        compose.onAllNodesWithText("SIP address").assertCountEquals(0)
    }
    @Test fun aNarrowWindowKeepsTheKeypadAlone() {
        show(400); tab("Keypad")
        compose.onAllNodesWithText("Recent calls").assertCountEquals(0)
    }
    @Test fun startingAChatWithSomeoneNewOpensIt() {                                           // the bug where the sheet closed and no chat appeared
        show(400); tab("Chats")
        compose.onNodeWithContentDescription("New message").performClick(); compose.waitForIdle()
        compose.onNodeWithText("Bob Brandt").performClick(); compose.waitForIdle()
        back().assertIsDisplayed()                                                              // the chat page is open, with its back arrow
        compose.onNodeWithText("Message").assertIsDisplayed()
    }

    // ---- the window changing size (folding, unfolding, rotating, split screen) ----

    @Test fun theOpenPersonFollowsTheWindowBetweenPaneAndPage() {
        show(1000); tab("Contacts")
        compose.onAllNodesWithText("Alice Archer")[0].performClick(); compose.waitForIdle()
        compose.onAllNodesWithContentDescription("Back").assertCountEquals(0)                  // in the right-hand pane
        width.intValue = 400; compose.waitForIdle()                                              // the window gets narrow: the card becomes a page
        compose.onNodeWithText("SIP address").assertIsDisplayed(); back().assertIsDisplayed()
        width.intValue = 1000; compose.waitForIdle()                                             // wide again: back into the pane
        compose.onNodeWithText("SIP address").assertIsDisplayed()
        compose.onAllNodesWithContentDescription("Back").assertCountEquals(0)
    }
}
