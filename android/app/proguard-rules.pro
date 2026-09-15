# ONNX Runtime 的 JNI 层是**按类名字符串**反查 Java 类的
# (FindClass("ai/onnxruntime/TensorInfo") 之类)。R8 一改名,FindClass 返回
# null,紧接着的 GetMethodID 收到 null class —— 那不是抛异常,是 JNI 层
# 直接 abort 整个进程:
#
#   JNI DETECTED ERROR IN APPLICATION: java_class == null in call to GetMethodID
#     from ai.onnxruntime.OrtSession.run(...)
#     #06 convertToTensorInfo  #07 convertOrtValueToONNXValue
#
# 只在 release 复现(debug 不混淆),而且 dex 里能直接看出症状:留下的是
# ai/onnxruntime/a、ai/onnxruntime/b,TensorInfo 整个不见了。
-keep class ai.onnxruntime.** { *; }
-keepclassmembers class ai.onnxruntime.** { *; }
