# flutter_local_notifications 在 release 版本 (R8 压缩混淆) 下，排定提醒 (zonedSchedule) 时会
# 报 "Missing type parameter." 崩掉——这个套件内部用 Gson 的 TypeToken 反射存/读已排程的通知，
# R8 默认会把这些泛型签名信息优化掉，导致运行时反射失败。加下面这几条 keep 规则保留相关类不被混淆/裁掉。
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * implements java.lang.reflect.Type

# 上面这几条只保留了"类不被裁掉"，但排程的闹钟到点后真正触发通知那条路径 (ScheduledNotificationReceiver
# 重新反序列化存好的通知内容) 还是完全没有任何反应——闹钟本身每次都准时响 (系统记录证实)，但通知
# 从来没贴出来过，也查不到任何崩溃记录。这更像是 R8 还把"泛型签名"这个属性本身去掉了——光保留类本身
# 不够，Gson 的反射在运行时还要读这个签名信息才能正确重建对象，这条不加，keep class 保住了类结构，
# 但泛型信息还是没了，Gson 反序列化会在某些调用路径里静默失败 (不是每个调用点都会像 TypeToken 那样
# 直接丢明确的 "Missing type parameter" 例外，有些路径会被套件自己的 try/catch 吞掉)。
# 这几行是 Gson 官方文件建议的完整 ProGuard 规则，之前只抄了一半。
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses
-keep class com.google.gson.** { *; }
-keep class sun.misc.Unsafe { *; }
-dontwarn com.dexterous.flutterlocalnotifications.**
