package com.livenet.l1ne.ui

import androidx.compose.ui.geometry.Rect
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The layout rules for folding screens: plain functions, no device needed. Pixels in, dp out (density 2 = 2 px per dp). */
class FoldTest {
    private val none = FoldInfo.None
    // a foldable held like a book: the fold runs top to bottom at x = 600 px, half open
    private val book = FoldInfo(hinge = Rect(600f, 0f, 600f, 1600f), vertical = true, halfOpen = true, separating = true)
    // the same phone held like a small laptop: the fold runs left to right at y = 800 px
    private val tabletop = FoldInfo(hinge = Rect(0f, 800f, 1200f, 800f), vertical = false, halfOpen = true, separating = true)
    // a dual-screen phone: a vertical hinge 40 px wide that hides part of the screen
    private val dual = FoldInfo(hinge = Rect(580f, 0f, 620f, 1600f), vertical = true, halfOpen = false, separating = true, occluding = true)

    @Test fun phonesAndNarrowWindowsStaySinglePane() { assertFalse(useTwoPanes(360, none)); assertFalse(useTwoPanes(699, none)); assertTrue(useTwoPanes(700, none)) }
    @Test fun aVerticalFoldMakesTwoPanesEvenInANarrowWindow() { assertTrue(useTwoPanes(360, book)); assertTrue(book.book); assertFalse(book.tabletop) }
    @Test fun aHorizontalFoldIsTabletopNotTwoPanes() { assertTrue(tabletop.tabletop); assertFalse(tabletop.book); assertFalse(useTwoPanes(360, tabletop)) }
    @Test fun aFlatScreenIsNeitherPosture() { assertFalse(none.tabletop); assertFalse(none.book) }

    @Test fun theListPaneEndsAtTheFoldWhenHeldLikeABook() { assertEquals(300f, leadingPaneWidthDp(windowWidthDp = 600f, density = 2f, fold = book, preferredDp = 380f)) }
    @Test fun theListPaneKeepsItsPreferredWidthOnAnOrdinaryScreen() { assertEquals(380f, leadingPaneWidthDp(1280f, 2f, none, 380f)) }
    @Test fun theListPaneNeverTakesMoreThanSixtyPercent() { assertEquals(420f, leadingPaneWidthDp(700f, 2f, none, 480f), 0.01f) }
    @Test fun tabletopDoesNotChangeThePaneWidth() { assertEquals(380f, leadingPaneWidthDp(1000f, 2f, tabletop, 380f)) }

    @Test fun aHingeThatHidesPartOfTheScreenLeavesAGap() { assertEquals(20f, hingeGapDp(2f, dual)) }
    @Test fun aHingeThatHidesNothingLeavesNoGap() { assertEquals(0f, hingeGapDp(2f, book)); assertEquals(0f, hingeGapDp(2f, none)); assertEquals(0f, hingeGapDp(2f, tabletop)) }
    @Test fun aDualScreenPhoneSplitsAtTheLeftEdgeOfTheHinge() { assertEquals(290f, leadingPaneWidthDp(600f, 2f, dual, 380f)) }
}
