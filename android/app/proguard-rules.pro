# kotlinx.serialization: keep generated serializers of the protocol models.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class app.orb.android.** {
    *** Companion;
}
-keepclasseswithmembers class app.orb.android.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class app.orb.android.**$$serializer { *; }

# OkHttp / Okio ship their own consumer rules; silence optional platform classes.
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
