package com.lexora.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import java.util.Locale

class VocabWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val LAUNCH_ACTION = "es.antonborri.home_widget.action.LAUNCH"
        private const val KEY_WORD_KEY = "widget_word_key"
        private const val KEY_WORD_DISPLAY = "widget_word_display"
        private const val KEY_LEVEL = "widget_level"
        private const val KEY_IPA = "widget_ipa"
        private const val KEY_MEANING = "widget_meaning"
        private const val KEY_WIDGET_ACTIVE = "widget_active"
    }

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        HomeWidgetPlugin.getData(context).edit().putBoolean(KEY_WIDGET_ACTIVE, true).apply()
    }

    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        HomeWidgetPlugin.getData(context).edit().putBoolean(KEY_WIDGET_ACTIVE, false).apply()
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val prefs = HomeWidgetPlugin.getData(context)
        prefs.edit().putBoolean(KEY_WIDGET_ACTIVE, true).apply()

        val wordKey = prefs.getString(KEY_WORD_KEY, "") ?: ""
        val wordDisplay = prefs.getString(KEY_WORD_DISPLAY, "") ?: ""
        val level = prefs.getString(KEY_LEVEL, "") ?: ""
        val ipa = prefs.getString(KEY_IPA, "") ?: ""
        val meaning = prefs.getString(KEY_MEANING, "") ?: ""

        for (appWidgetId in appWidgetIds) {
            val views = buildRemoteViews(
                context = context,
                appWidgetId = appWidgetId,
                wordKey = wordKey,
                wordDisplay = wordDisplay,
                level = level,
                ipa = ipa,
                meaning = meaning
            )
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }

    private fun buildRemoteViews(
        context: Context,
        appWidgetId: Int,
        wordKey: String,
        wordDisplay: String,
        level: String,
        ipa: String,
        meaning: String
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.vocab_widget_layout)

        val normalizedLevel = level.trim().uppercase(Locale.US)
        val bgRes = when (normalizedLevel) {
            "B1" -> R.drawable.bg_widget_b1
            "B2" -> R.drawable.bg_widget_b2
            "C1" -> R.drawable.bg_widget_c1
            "C2" -> R.drawable.bg_widget_c2
            else -> R.drawable.bg_widget_neutral
        }
        views.setInt(R.id.widget_root, "setBackgroundResource", bgRes)

        if (wordKey.isBlank()) {
            // Setup / placement pending state
            views.setTextViewText(R.id.widget_word, "Lexora")
            views.setTextViewTextSize(R.id.widget_word, TypedValue.COMPLEX_UNIT_SP, 20f)
            views.setViewVisibility(R.id.widget_level, View.GONE)
            views.setViewVisibility(R.id.widget_ipa, View.GONE)
            views.setViewVisibility(R.id.widget_refresh, View.GONE)
            views.setTextViewText(
                R.id.widget_meaning,
                if (meaning.isNotBlank()) meaning else "Kurulumu tamamlamak için dokun"
            )

            val launchIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = PendingIntent.getActivity(
                context,
                appWidgetId,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)
            return views
        }

        val displayTitle = if (wordDisplay.isNotBlank()) wordDisplay else wordKey
        val wordSp = when {
            displayTitle.length <= 10 -> 20f
            displayTitle.length <= 14 -> 17f
            displayTitle.length <= 18 -> 15f
            else -> 13f
        }
        views.setTextViewText(R.id.widget_word, displayTitle)
        views.setTextViewTextSize(R.id.widget_word, TypedValue.COMPLEX_UNIT_SP, wordSp)

        if (normalizedLevel.isNotBlank()) {
            val badgeRes = when (normalizedLevel) {
                "B1" -> R.drawable.bg_badge_b1
                "B2" -> R.drawable.bg_badge_b2
                "C1" -> R.drawable.bg_badge_c1
                "C2" -> R.drawable.bg_badge_c2
                else -> R.drawable.bg_badge_neutral
            }
            views.setInt(R.id.widget_level, "setBackgroundResource", badgeRes)
            views.setTextViewText(R.id.widget_level, normalizedLevel)
            views.setViewVisibility(R.id.widget_level, View.VISIBLE)
        } else {
            views.setViewVisibility(R.id.widget_level, View.GONE)
        }

        if (ipa.isNotBlank()) {
            views.setTextViewText(R.id.widget_ipa, ipa)
            views.setViewVisibility(R.id.widget_ipa, View.VISIBLE)
        } else {
            views.setViewVisibility(R.id.widget_ipa, View.GONE)
        }

        views.setTextViewText(R.id.widget_meaning, meaning)
        views.setViewVisibility(R.id.widget_refresh, View.VISIBLE)

        // Card tap -> deep link to word detail
        val encodedKey = Uri.encode(wordKey)
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            action = LAUNCH_ACTION
            data = Uri.parse("lexora://word/$encodedKey")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val launchPendingIntent = PendingIntent.getActivity(
            context,
            appWidgetId,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        views.setOnClickPendingIntent(R.id.widget_root, launchPendingIntent)

        // Refresh icon -> HomeWidget background callback (lexora://refresh)
        val refreshPendingIntent = HomeWidgetBackgroundIntent.getBroadcast(
            context,
            Uri.parse("lexora://refresh")
        )
        views.setOnClickPendingIntent(R.id.widget_refresh, refreshPendingIntent)

        return views
    }
}
