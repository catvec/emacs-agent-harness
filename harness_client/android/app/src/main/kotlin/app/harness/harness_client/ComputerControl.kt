package app.harness.harness_client

import android.content.Context
import android.util.DisplayMetrics
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The channel a harness agent's pointer and keyboard calls arrive on.
 *
 * Every call is forwarded to the person's own accessibility service and
 * answers with a machine reason (`ok`, `service-off`, `no-focus`,
 * `unsupported`, `unavailable`), which the Dart side turns into a tool result.
 * A coordinate is given in the pixel space of the screenshot the agent saw;
 * [displaySize] lets the caller scale it to the screen before it is sent.
 */
object ComputerControl {
    const val CHANNEL = "app.harness/computer_control"

    fun handle(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
        metrics: DisplayMetrics?,
    ) {
        when (call.method) {
            "perform" -> {
                val action = call.argument<String>("action") ?: ""
                val arguments = mutableMapOf<String, Any?>()
                for (name in listOf("x", "y", "toX", "toY", "amount")) {
                    arguments[name] = call.argument<Double>(name)
                }
                for (name in listOf("text", "key", "direction")) {
                    arguments[name] = call.argument<String>(name)
                }
                result.success(HarnessControlService.perform(action, arguments))
            }
            "displaySize" -> {
                if (metrics == null) {
                    result.success(null)
                } else {
                    result.success(
                        mapOf(
                            "width" to metrics.widthPixels,
                            "height" to metrics.heightPixels,
                            "density" to metrics.density,
                        ),
                    )
                }
            }
            "enabled" -> result.success(HarnessControlService.isEnabled(context))
            else -> result.notImplemented()
        }
    }
}
