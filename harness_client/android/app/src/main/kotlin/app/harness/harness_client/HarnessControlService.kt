package app.harness.harness_client

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ComponentName
import android.content.Context
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.text.TextUtils
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeInfo.AccessibilityAction

/**
 * The opt-in system control a person can give this app.
 *
 * Android offers no public API for an app to inject touch or keys into other
 * apps.  The one supported route is an AccessibilityService the person
 * enables themselves in the OS settings; Android then draws its own warning
 * and lists the service, and this app can neither enable nor keep it without
 * that.  The service is `exported=false` and its metadata says it performs
 * gestures, so it can do nothing but dispatch a touch, a scroll, a drag and
 * text into the field that currently has input focus.
 *
 * It is a service of the app, not a background daemon: while it is off, the
 * app advertises no pointer or keyboard capability and the tools refuse.
 * Nothing here reads screen content except the node that has input focus, and
 * no event is stored.
 */
class HarnessControlService : AccessibilityService() {
    companion object {
        /** The service instance while it is running, or null. */
        @Volatile
        private var instance: HarnessControlService? = null

        fun isRunning(): Boolean = instance != null

        /** Whether a person has enabled this service in the OS settings. */
        fun isEnabled(context: Context): Boolean {
            val expected = ComponentName(context, HarnessControlService::class.java)
            val enabled = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            ) ?: return false
            val splitter = TextUtils.SimpleStringSplitter(':')
            splitter.setString(enabled)
            while (splitter.hasNext()) {
                val component = ComponentName.unflattenFromString(splitter.next())
                if (component != null && component == expected) return true
            }
            return false
        }

        /**
         * Dispatch one gesture, or text, with the person's service.
         *
         * Returns a reason rather than throwing so the Dart side can put it in
         * a tool result: `service-off` when the person has not enabled it,
         * `unsupported` on an OS without gestures, `busy` when a gesture is
         * still running.
         */
        fun perform(action: String, arguments: Map<String, Any?>): String {
            val service = instance ?: return "service-off"
            return service.dispatch(action, arguments)
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Events are what wake an accessibility service; this one acts only
        // when the app asks, so nothing is read from them and nothing is kept.
    }

    override fun onInterrupt() {}

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    private fun dispatch(action: String, arguments: Map<String, Any?>): String = when (action) {
        "tap" -> tap(
            x = number(arguments["x"]),
            y = number(arguments["y"]),
        )
        "scroll" -> scroll(
            x = number(arguments["x"]),
            y = number(arguments["y"]),
            direction = arguments["direction"] as? String ?: "down",
            amount = number(arguments["amount"]).toInt().coerceIn(1, 5),
        )
        "drag" -> drag(
            x = number(arguments["x"]),
            y = number(arguments["y"]),
            toX = number(arguments["toX"]),
            toY = number(arguments["toY"]),
        )
        "type" -> typeText(arguments["text"] as? String ?: "")
        "key" -> pressKey(arguments["key"] as? String ?: "")
        else -> "unsupported"
    }

    private fun number(value: Any?): Float = when (value) {
        is Number -> value.toFloat()
        is String -> value.toFloatOrNull() ?: 0f
        else -> 0f
    }

    private fun tap(x: Float, y: Float): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return "unsupported"
        val path = Path().apply { moveTo(x, y) }
        return gesture(path, 0, 60)
    }

    private fun drag(x: Float, y: Float, toX: Float, toY: Float): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return "unsupported"
        val path = Path().apply {
            moveTo(x, y)
            lineTo(toX, toY)
        }
        return gesture(path, 0, 400)
    }

    /** A scroll is a short swipe from the point the caller names. */
    private fun scroll(x: Float, y: Float, direction: String, amount: Int): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return "unsupported"
        val distance = 220f * amount
        val (toX, toY) = when (direction) {
            "up" -> x to y + distance
            "down" -> x to y - distance
            "left" -> x + distance to y
            else -> x - distance to y
        }
        val path = Path().apply {
            moveTo(x, y)
            lineTo(toX.coerceAtLeast(1f), toY.coerceAtLeast(1f))
        }
        return gesture(path, 0, 180)
    }

    private fun gesture(path: Path, start: Long, duration: Long): String {
        val stroke = GestureDescription.StrokeDescription(path, start, duration)
        val description = GestureDescription.Builder().addStroke(stroke).build()
        val dispatched = dispatchGesture(description, null, null)
        return if (dispatched) "ok" else "unavailable"
    }

    /**
     * Type into the field that has input focus.  This is the only content the
     * service reads: the focused editable node's own text, so it can append or
     * replace it.  Nothing else on screen is inspected or sent anywhere.
     */
    private fun typeText(text: String): String {
        val focused = focusedEditable() ?: return "no-focus"
        val arguments = Bundle()
        arguments.putCharSequence(
            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
            "${focused.text?.toString() ?: ""}$text",
        )
        return if (focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)) {
            "ok"
        } else {
            "unavailable"
        }
    }

    /**
     * The keys an injected gesture cannot do.  Backspace is the focused
     * field's own text without its last character; Return is the IME's enter
     * action, which exists from Android 11.  Anything else is refused rather
     * than approximated, so a call never reports a key it did not press.
     */
    private fun pressKey(key: String): String {
        val focused = focusedEditable()
        return when (key.lowercase()) {
            "delete", "backspace" -> {
                val current = focused?.text?.toString() ?: return "no-focus"
                if (current.isEmpty()) return "ok"
                val arguments = Bundle()
                arguments.putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    current.dropLast(1),
                )
                if (focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)) {
                    "ok"
                } else {
                    "unavailable"
                }
            }
            "enter", "return" -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return "unsupported"
                val node = focused ?: return "no-focus"
                // The enter action is an AccessibilityAction, not one of the
                // int action constants; it arrived in API 30 with R.
                if (node.performAction(AccessibilityAction.ACTION_IME_ENTER.id)) {
                    "ok"
                } else {
                    "unavailable"
                }
            }
            else -> "unsupported"
        }
    }

    private fun focusedEditable(): AccessibilityNodeInfo? {
        val root = rootInActiveWindow ?: return null
        val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return null
        return if (focused.isEditable) focused else null
    }
}
