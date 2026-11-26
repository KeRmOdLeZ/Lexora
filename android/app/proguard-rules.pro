# Lexora v2.0.0 — R8 / ProGuard Rules

# R8 Full Mode: preserve generic signatures & Gson TypeToken metadata
-keepattributes Signature, InnerClasses, EnclosingMethod
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep public class * implements java.lang.reflect.Type
-keep class com.dexterous.** { *; }

# Keep Lexora native entrypoints
-keep class com.lexora.app.VocabWidgetProvider { *; }
-keep class com.lexora.app.DictExtractor { *; }
-keep class com.lexora.app.DictExtractor$* { *; }

# Keep home_widget, workmanager, and WorkManager classes
-keep class es.antonborri.home_widget.** { *; }
-keep class dev.fluttercommunity.workmanager.** { *; }
-keep class androidx.work.** { *; }

# Strip verbose/debug/info logs from release builds
-assumenosideeffects class android.util.Log {
    public static int d(...);
    public static int v(...);
    public static int i(...);
}
