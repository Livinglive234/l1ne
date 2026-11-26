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
 * What a folding screen is doing, as far as the layouts care. Everything is in window pixels; a phone that does not fold
 * (or a window that does not touch the fold) gives [None].
 */
data class FoldInfo(
    val hinge: Rect? = null,          // where the fold is
    val vertical: Boolean = false,    // the fold runs top to bottom: two screens side by side ("book")
    val halfOpen: Boolean = false,    // bent partway, so it can stand on its own
    val separating: Boolean = false,  // the fold splits the window into two areas worth treating separately
    val occluding: Boolean = false,   // the hinge itself hides part of the screen (a physical gap, as on dual-screen phones)
) {
    /** Half open with a horizontal fold, like a small laptop: one half above the fold, one below, standing on a table. */
    val tabletop get() = halfOpen && hinge != null && !vertical
    /** Fold runs top to bottom and splits the window: the list goes on one side, the detail on the other. */
    val book get() = hinge != null && vertical && separating

    companion object { val None = FoldInfo() }
}

val LocalFold = compositionLocalOf { FoldInfo.None }

/** The activity's current fold, updated as the phone is folded, unfolded, rotated or moved to split screen. */
@Composable
fun rememberFold(activity: Activity): FoldInfo {
    val flow = remember(activity) { WindowInfoTracker.getOrCreate(activity).windowLayoutInfo(activity) }
    val info by flow.collectAsState(initial = WindowLayoutInfo(emptyList()))
    val f = info.displayFeatures.filterIsInstance<FoldingFeature>().firstOrNull() ?: return FoldInfo.None
    val b = f.bounds
    return FoldInfo(
        hinge = Rect(b.left.toFloat(), b.top.toFloat(), b.right.toFloat(), b.bottom.toFloat()),
        vertical = f.orientation == FoldingFeature.Orientation.VERTICAL,
        halfOpen = f.state == FoldingFeature.State.HALF_OPENED,
        separating = f.isSeparating,
        occluding = f.occlusionType == FoldingFeature.OcclusionType.FULL,
    )
}

/** Two panes side by side are worth it from this width, or whenever a vertical fold already splits the window in two. */
const val TWO_PANE_MIN_DP = 700

fun useTwoPanes(windowWidthDp: Int, fold: FoldInfo) = windowWidthDp >= TWO_PANE_MIN_DP || fold.book

/**
 * How wide the first (left) pane is, in dp: [preferredDp] on an ordinary screen, but never more than 60% of the window,
 * and exactly up to the fold when a vertical fold splits the window, so nothing is drawn across the hinge.
 */
fun leadingPaneWidthDp(windowWidthDp: Float, density: Float, fold: FoldInfo, preferredDp: Float): Float {
    val hinge = fold.hinge
    if (fold.book && hinge != null) return hinge.left / density
    return preferredDp.coerceAtMost(windowWidthDp * 0.6f)
}

/** The gap to leave at the fold, in dp: the hinge's own width when it hides part of the screen, otherwise nothing. */
fun hingeGapDp(density: Float, fold: FoldInfo): Float {
    val hinge = fold.hinge ?: return 0f
    return if (fold.book && fold.occluding) hinge.width / density else 0f
}
