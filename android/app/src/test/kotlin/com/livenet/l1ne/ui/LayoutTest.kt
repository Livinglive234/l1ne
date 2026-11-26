package com.livenet.l1ne.ui

import kotlin.test.Test
import androidx.compose.ui.geometry.Rect
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The two-pane rules depend on the window width only, so a half-open foldable can never look different from an open one. */
class LayoutTest {
    @Test fun phonesAndNarrowWindowsStaySinglePane() { assertFalse(useTwoPanes(360)); assertFalse(useTwoPanes(699)); assertTrue(useTwoPanes(700)) }
    @Test fun aFoldablesInnerScreenInPortraitGetsTwoPanes() { assertTrue(useTwoPanes(701)) }      // a Pixel Fold's inner screen is about 701 dp wide
    @Test fun theListPaneIsFortyPercentWithinLimits() { assertEquals(300f, listPaneWidthDp(700)); assertEquals(320f, listPaneWidthDp(800)); assertEquals(380f, listPaneWidthDp(1280)) }
    @Test fun theKeypadPaneNeverTakesMoreThanSixtyPercent() { assertEquals(420f, keypadPaneWidthDp(700), 0.01f); assertEquals(480f, keypadPaneWidthDp(1280)) }

    // tabletop (the flip phone's call screen) is the only posture that changes anything
    @Test fun aHalfOpenHorizontalFoldIsTabletop() { assertEquals(Rect(0f, 1320f, 1080f, 1320f), tabletopHinge(halfOpen = true, horizontal = true, 0f, 1320f, 1080f, 1320f)) }
    @Test fun aHalfOpenVerticalFoldIsNotTabletop() { assertNull(tabletopHinge(halfOpen = true, horizontal = false, 1104f, 0f, 1104f, 1840f)) }     // a Fold or Pixel Fold held like a book keeps its normal layout
    @Test fun aFlatOrClosedFoldIsNotTabletop() { assertNull(tabletopHinge(halfOpen = false, horizontal = true, 0f, 1320f, 1080f, 1320f)); assertNull(tabletopHinge(halfOpen = false, horizontal = false, 0f, 0f, 0f, 0f)) }
}
