package app.orb.android

import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import app.orb.android.ui.OrbRoot
import app.orb.android.ui.OrbTheme
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning

class MainActivity : FragmentActivity() {
    private var externalLink by mutableStateOf<String?>(null)
    private var reduceMotion by mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val repo = OrbRepository.get(this)
        handleIntent(intent, repo)
        setContent {
            OrbTheme(reduceMotion) {
                OrbRoot(
                    repo = repo,
                    externalLink = externalLink,
                    onExternalLinkHandled = { externalLink = null },
                    onScan = ::scanQr,
                    authenticate = ::authenticate,
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent, OrbRepository.get(this))
    }

    private fun handleIntent(intent: Intent?, repo: OrbRepository) {
        intent ?: return
        intent.dataString?.takeIf { intent.action == Intent.ACTION_VIEW }?.let { externalLink = it }
        intent.getStringExtra(EXTRA_BOT)?.let {
            repo.openChat(it)
            repo.notifier?.let { n -> (n as? Notifier)?.cancelFor(it) }
            intent.removeExtra(EXTRA_BOT)
        }
    }

    override fun onStart() {
        super.onStart()
        // "Remover animações" sets the animator scale to 0; honour it for our own infinite animations.
        reduceMotion = Settings.Global.getFloat(contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
        OrbRepository.get(this).onAppStarted()
    }

    override fun onStop() {
        OrbRepository.get(this).onAppStopped()
        super.onStop()
    }

    /** Google's code scanner runs in Play services, so the app needs no camera permission. */
    private fun scanQr(onLink: (String) -> Unit, onError: (String) -> Unit) {
        val options = GmsBarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .enableAutoZoom()
            .build()
        GmsBarcodeScanning.getClient(this, options).startScan()
            .addOnSuccessListener { code -> code.rawValue?.let(onLink) ?: onError("Esse QR code está vazio.") }
            .addOnCanceledListener { }
            .addOnFailureListener { onError("Não foi possível abrir o leitor de QR code. Use “Colar link”.") }
    }

    private fun authenticate(onOk: () -> Unit) {
        val allowed = BIOMETRIC_WEAK or DEVICE_CREDENTIAL
        if (BiometricManager.from(this).canAuthenticate(allowed) != BiometricManager.BIOMETRIC_SUCCESS) {
            OrbRepository.get(this).showMessage("Ative a senha ou a digital do celular para permitir ações arriscadas.")
            return
        }
        val prompt = BiometricPrompt(
            this, ContextCompat.getMainExecutor(this),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = onOk()
            },
        )
        prompt.authenticate(
            BiometricPrompt.PromptInfo.Builder()
                .setTitle("Confirme que é você")
                .setSubtitle("Essa ação é arriscada")
                .setAllowedAuthenticators(allowed)
                .build(),
        )
    }
}
