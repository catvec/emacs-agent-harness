package app.harness.harness_client

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * What the phone's own OS says about the permissions a computer registration
 * needs, where its durable private files are, and how a secret is sealed.
 *
 * Nothing here captures anything: the answers are facts the registration
 * advertises, and the capture itself belongs to the media module.  A
 * permission is asked for only when the person turns that capability on,
 * never at start-up and never for a call that arrives from the harness.
 */
object ComputerPlatform {
    const val CHANNEL = "app.harness/computer_platform"

    private const val REQUEST_CODE = 4711
    private const val PREFS = "harness_computer_secure"
    private const val KEY_ALIAS = "harness.computer.secret"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128

    /** A permission request waiting for `onRequestPermissionsResult`. */
    private class Pending(val permission: String, val result: MethodChannel.Result)

    private var pending: Pending? = null

    fun handle(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "permissions" -> result.success(permissions(activity))
            "requestPermission" -> request(activity, call.argument<String>("name"), result)
            "storageRoot" -> result.success(storageRoot(activity).absolutePath)
            "secureWrite" -> secureWrite(activity, call, result)
            "secureRead" -> secureRead(activity, call, result)
            "secureDelete" -> {
                val key = call.argument<String>("key")
                if (key != null) prefs(activity).edit().remove(key).apply()
                result.success(true)
            }
            "controlSettings" -> {
                openControlSettings(activity)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** What this build and this OS can offer, without asking for anything. */
    private fun permissions(context: Context): Map<String, Any?> = mapOf(
        "sdk" to Build.VERSION.SDK_INT,
        "camera" to state(context, Manifest.permission.CAMERA),
        "microphone" to state(context, Manifest.permission.RECORD_AUDIO),
        // MediaProjection consent is per session and cannot be pre-granted;
        // what can be said without asking is whether the platform has it.
        "screen" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            "available"
        } else {
            "unavailable"
        },
        "screenForegroundService" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            "available"
        } else {
            "unavailable"
        },
        "control" to if (HarnessControlService.isEnabled(context)) "available" else "disabled",
    )

    private fun declared(context: Context, permission: String): Boolean =
        try {
            context.packageManager.getPackageInfo(
                context.packageName,
                PackageManager.GET_PERMISSIONS,
            ).requestedPermissions?.contains(permission) ?: false
        } catch (_: Exception) {
            false
        }

    private fun state(context: Context, permission: String): String = when {
        !declared(context, permission) -> "unavailable"
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED -> "available"
        // A permission the system already asked for and the person refused is
        // denied; one never asked is still grantable and reads available, so
        // the first tool call can ask.  The two are told apart by a flag this
        // app set when it asked, not by guessing.
        prefs(context).getBoolean("asked.$permission", false) -> "denied"
        else -> "available"
    }

    private fun request(activity: Activity, name: String?, result: MethodChannel.Result) {
        val permission = when (name) {
            "camera" -> Manifest.permission.CAMERA
            "microphone" -> Manifest.permission.RECORD_AUDIO
            else -> {
                result.error("bad-argument", "unknown permission ${name ?: ""}", null)
                return
            }
        }
        if (!declared(activity, permission)) {
            result.success("unavailable")
            return
        }
        if (activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            result.success("available")
            return
        }
        if (pending != null) {
            // One prompt at a time; a second ask is refused rather than both
            // results settling on one callback.
            result.success("denied")
            return
        }
        pending = Pending(permission, result)
        try {
            prefs(activity).edit().putBoolean("asked.$permission", true).apply()
            activity.requestPermissions(arrayOf(permission), REQUEST_CODE)
        } catch (failure: Exception) {
            pending = null
            result.error("request-failed", "${failure.javaClass.simpleName}", null)
        }
    }

    /** Called from the activity when the person answers the OS dialog. */
    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val current = pending ?: return true
        pending = null
        val granted = permissions.indices.any { index ->
            permissions[index] == current.permission &&
                grantResults.getOrNull(index) == PackageManager.PERMISSION_GRANTED
        }
        current.result.success(if (granted) "available" else "denied")
        return true
    }

    /**
     * The app's own durable directory.  `filesDir` is private to the app and
     * is not reclaimed the way a cache is, which is what lets the identity and
     * the imported files outlive a run.
     */
    private fun storageRoot(context: Context): File =
        File(context.filesDir, "harness-computer").apply { mkdirs() }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun secureWrite(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        val key = call.argument<String>("key")
        val value = call.argument<String>("value")
        if (key == null || value == null) {
            result.error("bad-arguments", "key and value are required", null)
            return
        }
        try {
            write(activity, key, value)
            result.success(true)
        } catch (failure: Exception) {
            result.error("seal-failed", failure.javaClass.simpleName, null)
        }
    }

    private fun secureRead(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        val key = call.argument<String>("key")
        if (key == null) {
            result.error("bad-arguments", "key is required", null)
            return
        }
        // A key the OS dropped (the lock screen changed, app data was restored
        // elsewhere) reads as absent rather than as a crash; the caller then
        // seals a fresh secret.
        result.success(try {
            read(activity, key)
        } catch (_: Exception) {
            null
        })
    }

    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
        if (existing != null) return existing.secretKey
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore",
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return generator.generateKey()
    }

    private fun write(context: Context, name: String, value: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val sealed = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val packed = Base64.encodeToString(cipher.iv, Base64.NO_WRAP) +
            ":" + Base64.encodeToString(sealed, Base64.NO_WRAP)
        prefs(context).edit().putString(name, packed).apply()
    }

    private fun read(context: Context, name: String): String? {
        val packed = prefs(context).getString(name, null) ?: return null
        val parts = packed.split(":")
        if (parts.size != 2) return null
        val iv = Base64.decode(parts[0], Base64.NO_WRAP)
        val sealed = Base64.decode(parts[1], Base64.NO_WRAP)
        if (iv.size != IV_BYTES) return null
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_BITS, iv))
        return String(cipher.doFinal(sealed), Charsets.UTF_8)
    }

    /**
     * The OS's own accessibility page, where a person turns the control
     * service on.  This app cannot grant the service itself and never tries
     * to: the switch is the system's.
     */
    private fun openControlSettings(context: Context) {
        try {
            context.startActivity(
                Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (_: Exception) {
            // A build without a settings screen: the toggle stays off.
        }
    }
}
