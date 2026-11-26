package com.livenet.l1ne.ui

/**
 * Width rules for the two-pane layouts. They look at the window's width and nothing else: a foldable (folded, half open or open)
 * and a tablet are treated the same, so half open always looks exactly like open.
 */
const val TWO_PANE_MIN_DP = 700

/** Two panes side by side (list and detail, or keys and matches) from this window width. */
fun useTwoPanes(windowWidthDp: Int) = windowWidthDp >= TWO_PANE_MIN_DP

/** The list pane: 40% of the window, kept between 300 and 380 dp. */
fun listPaneWidthDp(windowWidthDp: Int): Float = (windowWidthDp * 0.4f).coerceIn(300f, 380f)

/** The keypad pane: 480 dp, but never more than 60% of the window. */
fun keypadPaneWidthDp(windowWidthDp: Int): Float = 480f.coerceAtMost(windowWidthDp * 0.6f)
