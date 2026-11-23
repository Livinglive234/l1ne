package com.livenet.l1ne.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** Colours from the LiveNet website (dark theme): green brand on a green-tinted near-black. Same values as iOS Theme.swift. */
object L1neColors {
    val Brand = Color(0xFF22C03C)
    val BrandDim = Color(0xFF178A2B)
    val OnBrand = Color(0xFF04120A)
    val Bg = Color(0xFF0B0F0C)
    val Surface = Color(0xFF121814)
    val Border = Color(0xFF223024)
    val Text = Color(0xFFE8EFE9)
    val Muted = Color(0xFF94A398)
    val Danger = Color(0xFFE04646)
}

private val scheme = darkColorScheme(
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
)

@Composable
fun L1neTheme(content: @Composable () -> Unit) = MaterialTheme(colorScheme = scheme, content = content)
