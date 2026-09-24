# ==================== Flutter Wrapper ====================
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# ==================== Shorebird Specific Rules ====================
-keep class dev.shorebird.** { *; }

# ==================== Google Play Core (Fixes R8 missing classes errors) ====================
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.splitcompat.** { *; }
-keep class com.google.android.play.core.splitinstall.** { *; }
-keep class com.google.android.play.core.tasks.** { *; }

# ==================== Firebase ====================
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**

# ==================== Google Play Services ====================
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**

# ==================== Dio & Networking ====================
-keepattributes Signature,InnerClasses,EnclosingMethod
-keep class retrofit2.** { *; }
-keep class okhttp3.** { *; }
-dontwarn okhttp3.**

# ==================== App Models (JSON serialization) ====================
-keep class com.paykaribazar.app.models.** { *; }
-keep class com.paykaribazar.app.** { *; }

# ==================== Payment SDKs ====================
# bKash mobile wallet SDK
-keep class com.bkash.** { *; }
# SSLCommerz payment gateway SDK
-keep class com.sslcommerz.** { *; }

# ==================== Nagad Crypto (BouncyCastle RSA/AES) ====================
# Nagad uses RSA hybrid encryption with BouncyCastle — obfuscating BC classes
# breaks the JCE provider lookup at runtime.
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# ==================== Gson / JSON SerializedName ====================
-keepattributes Signature
-keepattributes *Annotation*
-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}

# ==================== Generic Signature & Annotation Preservation ====================
# Required by Retrofit / Gson / Firebase generic type token resolution.
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses
