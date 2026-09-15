package com.sora214.plana.app

/**
 * 是否跑在纯血鸿蒙的安卓兼容容器里(卓易通 / 出境易)。
 *
 * 容器会把 `Build` 里的厂商、品牌、型号伪装成普通安卓机,靠那几个字段认不出来;
 * 认的是容器自己设的一组 `anco` 系统属性,普通安卓机上没有。任一非空即判定
 * (属性名与 DeviceCompat、PhotonCamera 的判法一致)。
 */
object HarmonyCompat {

    private val KEYS = arrayOf(
        "ro.product.anco.devicetype",
        "ro.product.os.dist.anco.apiversion",
        "ro.product.os.dist.anco.releasetype",
        "ro.sys.anco.product.software.version",
    )

    /** 都是 `ro.` 只读属性,运行中不会变,进程内判一次即可。 */
    val isContainer: Boolean by lazy { KEYS.any { prop(it).isNotEmpty() } }

    /**
     * `android.os.SystemProperties` 是隐藏 API,只能反射;反射被拦就退到 `getprop`。
     * 两条都不通按「没有」算 —— 认不出容器只是退回应用内图库(慢,但能用),
     * 在普通机上误判才是真出错。
     */
    private fun prop(key: String): String = try {
        Class.forName("android.os.SystemProperties")
            .getMethod("get", String::class.java, String::class.java)
            .invoke(null, key, "") as? String ?: ""
    } catch (e: Exception) {
        try {
            ProcessBuilder("getprop", key).start()
                .inputStream.bufferedReader().use { it.readLine()?.trim().orEmpty() }
        } catch (e: Exception) {
            ""
        }
    }
}
