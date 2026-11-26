package com.livenet.l1ne.ui

import android.app.Activity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.geometry.Rect
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker
import androidx.window.layout.WindowLayoutInfo

/**
 * Layout rules for big and folding screens. The panes depend on the window's width only: a foldable (folded, half open or open) and a tablet
 * are treated the same, so a half-open Fold or Pixel Fold looks exactly like an open one. The one exception is below: a flip phone
 * (the fold runs left to right) standing half open, like a small laptop.
 */
const val TWO_PANE_MIN_DP = 700

/** Two panes side by side (list and detail, or keys and matches) from this window width. */
fun useTwoPanes(windowWidthDp: Int) = windowWidthDp >= TWO_PANE_MIN_DP

/** The list pane: 40% of the window, kept between 300 and 380 dp. */
fun listPaneWidthDp(windowWidthDp: Int): Float = (windowWidthDp * 0.4f).coerceIn(300f, 380f)

/** The keypad pane: 480 dp, but never more than 60% of the window. */
fun keypadPaneWidthDp(windowWidthDp: Int): Float = 480f.coerceAtMost(windowWidthDp * 0.6f)

/**
 * Tabletop: half open with a horizontal fold, so one half of the screen is above the fold and one below, standing on a table.
 * Returns where the fold is (window pixels), or null for every other situation (a flat or closed screen, or any vertical fold:
 * a book-style foldable half open keeps its normal layout).
 */
fun tabletopHinge(halfOpen: Boolean, horizontal: Boolean, left: Float, top: Float, right: Float, bottom: Float): Rect? =
    if (halfOpen && horizontal) Rect(left, top, right, bottom) else null

/** Where the fold is while the phone stands half open on a horizontal fold, otherwise null. */
val LocalTabletopHinge = compositionLocalOf<Rect?> { null }

@Composable
fun rememberTabletopHinge(activity: Activity): Rect? {
    val flow = remember(activity) { WindowInfoTracker.getOrCreate(activity).windowLayoutInfo(activity) }
    val info by flow.collectAsState(initial = WindowLayoutInfo(emptyList()))
    val f = info.displayFeatures.filterIsInstance<FoldingFeature>().firstOrNull() ?: return null
    val b = f.bounds
    return tabletopHinge(f.state == FoldingFeature.State.HALF_OPENED, f.orientation == FoldingFeature.Orientation.HORIZONTAL,
        b.left.toFloat(), b.top.toFloat(), b.right.toFloat(), b.bottom.toFloat())
}
