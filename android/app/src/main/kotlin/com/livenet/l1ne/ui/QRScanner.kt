package com.livenet.l1ne.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.Executors

/** Camera preview that reports the first QR code it sees. The camera is only on while this is on screen. */
@Composable
fun QRScanner(onCode: (String) -> Unit, onCancel: () -> Unit) {
    val ctx = LocalContext.current
    val owner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(ctx, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it }
    LaunchedEffect(Unit) { if (!granted) ask.launch(Manifest.permission.CAMERA) }

    Surface(Modifier.fillMaxSize(), color = L1neColors.Bg) {
        Column(Modifier.fillMaxSize().systemBarsPadding(), horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Scan the QR code from your PBX setup page", Modifier.padding(16.dp), style = MaterialTheme.typography.titleMedium)
            if (granted) {
                val executor = remember { Executors.newSingleThreadExecutor() }
                val scanner = remember { BarcodeScanning.getClient(com.google.mlkit.vision.barcode.BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()) }
                var done by remember { mutableStateOf(false) }
                AndroidView(modifier = Modifier.weight(1f).fillMaxWidth(), factory = { c ->
                    val view = PreviewView(c)
                    ProcessCameraProvider.getInstance(c).addListener({
                        val provider = ProcessCameraProvider.getInstance(c).get()
                        val preview = Preview.Builder().build().also { it.setSurfaceProvider(view.surfaceProvider) }
                        val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
                        analysis.setAnalyzer(executor) { proxy ->
                            val media = proxy.image
                            if (media == null || done) { proxy.close(); return@setAnalyzer }
                            scanner.process(InputImage.fromMediaImage(media, proxy.imageInfo.rotationDegrees))
                                .addOnSuccessListener { codes -> codes.firstNotNullOfOrNull { it.rawValue }?.let { if (!done) { done = true; onCode(it) } } }
                                .addOnCompleteListener { proxy.close() }
                        }
                        provider.unbindAll()
                        provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                    }, ContextCompat.getMainExecutor(c))
                    view
                })
                DisposableEffect(Unit) { onDispose { runCatching { ProcessCameraProvider.getInstance(ctx).get().unbindAll() }; executor.shutdown() } }
            } else {
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    Text("L1ne needs the camera only to read the QR code. Nothing is recorded.", Modifier.padding(32.dp), color = L1neColors.Muted)
                }
            }
            TextButton(onCancel, Modifier.padding(16.dp)) { Text("Cancel") }
        }
    }
}
