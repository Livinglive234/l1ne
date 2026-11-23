package com.livenet.l1ne.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color

/**
 * Colours from the LiveNet website, in a dark and a light version that follow the system setting. Same values as iOS Theme.swift.
 * Brand green stays recognisable in both; light mode uses a slightly deeper green so text and icons stay readable on white.
 */
object L1neColors {
    /** Set by [L1neTheme]; reading it from a composable makes that composable follow the switch. */
    var dark by mutableStateOf(true)

    val Brand get() = if (dark) Color(0xFF22C03C) else Color(0xFF1A9E31)
    val BrandDim get() = if (dark) Color(0xFF178A2B) else Color(0xFF127A24)
    val OnBrand get() = if (dark) Color(0xFF04120A) else Color(0xFFFFFFFF)
    val Bg get() = if (dark) Color(0xFF000000) else Color(0xFFFFFFFF)          // main screens: pure black / white
    val SheetBg get() = if (dark) Color(0xFF0B0F0C) else Color(0xFFF2F6F3)     // sheets and dialogs
    val Surface get() = if (dark) Color(0xFF121814) else Color(0xFFE8EFE9)
    val Border get() = if (dark) Color(0xFF223024) else Color(0xFFCFDAD2)
    val Text get() = if (dark) Color(0xFFE8EFE9) else Color(0xFF0E1A11)
    val Muted get() = if (dark) Color(0xFF94A398) else Color(0xFF5A6B5F)
    val Danger get() = if (dark) Color(0xFFE04646) else Color(0xFFD23A3A)
}

private fun scheme(dark: Boolean) =
    if (dark) darkColorScheme(
        primary = L1neColors.Brand,
        onPrimary = L1neColors.OnBrand,
        background = L1neColors.Bg,
        onBackground = L1neColors.Text,
        surface = L1neColors.Bg,
        onSurface = L1neColors.Text,
        surfaceVariant = L1neColors.Surface,
        onSurfaceVariant = L1neColors.Muted,
        surfaceContainer = L1neColors.Surface,
        surfaceContainerHigh = L1neColors.Surface,
        secondaryContainer = Color(0xFF16301C),        // selected tab pill: brand-tinted
        onSecondaryContainer = L1neColors.Brand,
        outline = L1neColors.Border,
        error = L1neColors.Danger,
    ) else lightColorScheme(
        primary = L1neColors.Brand,
        onPrimary = L1neColors.OnBrand,
        background = L1neColors.Bg,
        onBackground = L1neColors.Text,
        surface = L1neColors.Bg,
        onSurface = L1neColors.Text,
        surfaceVariant = L1neColors.Surface,
        onSurfaceVariant = L1neColors.Muted,
        surfaceContainer = L1neColors.Surface,
        surfaceContainerHigh = L1neColors.Surface,
        secondaryContainer = Color(0xFFD3EBD8),        // selected tab pill: brand-tinted
        onSecondaryContainer = L1neColors.Brand,
        outline = L1neColors.Border,
        error = L1neColors.Danger,
    )

@Composable
fun L1neTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    L1neColors.dark = dark
    MaterialTheme(colorScheme = scheme(dark), content = content)
}
