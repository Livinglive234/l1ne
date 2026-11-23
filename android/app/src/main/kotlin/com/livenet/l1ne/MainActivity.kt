package com.livenet.l1ne

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.livenet.l1ne.ui.L1neApp
import com.livenet.l1ne.ui.L1neTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent { L1neTheme { L1neApp() } }
    }
}
