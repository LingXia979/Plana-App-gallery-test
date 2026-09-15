package com.sora214.plana.app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import kotlin.concurrent.thread

/**
 * 把缓存里的文件经系统保存对话框(SAF)存到用户挑的位置,**边读边写**。
 *
 * file_picker 的 saveFile 在安卓上只收字节:文件先整份读进 Dart 堆,再经通道拷一份到
 * Java 堆,对话框开着的这段时间两份都在。几百张图打的 zip 动辄几百 MB,一叠就 OOM。
 * 这里只传路径,拷贝在后台线程按块流过去,占用的内存与文件大小无关。
 */
class DocumentSaver(private val activity: Activity) {

    private class Pending(val path: String, val result: MethodChannel.Result)

    /** 对话框开着的那一单。系统保存对话框同一时间只会开一个,一个槽就够。 */
    private var pending: Pending? = null

    fun save(path: String, name: String, mime: String, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "上一个保存对话框还开着", null)
            return
        }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime
            putExtra(Intent.EXTRA_TITLE, name)
        }
        pending = Pending(path, result)
        try {
            activity.startActivityForResult(intent, REQUEST_CODE)
        } catch (e: ActivityNotFoundException) {
            pending = null
            result.error("no_activity", "系统里没有能保存文件的界面", null)
        }
    }

    /** MainActivity 转进来的每一条结果都过一遍,不是自己那一单就不管。 */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_CODE) return
        val p = pending ?: return
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            p.result.success(null) // 取消
            return
        }
        val resolver = activity.applicationContext.contentResolver
        thread(name = "plana-document-save") {
            val outcome = runCatching {
                val out = resolver.openOutputStream(uri) ?: throw IOException("打不开目标文件")
                out.use { o -> File(p.path).inputStream().use { it.copyTo(o, BUFFER) } }
            }
            // 写到一半失败(盘满、源文件没了):对话框那一刻文件已经建好了,
            // 删掉它,别在用户挑的目录里留一个打不开的空壳
            if (outcome.isFailure) {
                runCatching { DocumentsContract.deleteDocument(resolver, uri) }
            }
            main.post {
                outcome.fold(
                    onSuccess = { p.result.success(uri.toString()) },
                    onFailure = {
                        p.result.error("write_failed", it.message ?: it.javaClass.simpleName, null)
                    },
                )
            }
        }
    }

    companion object {
        /** 随手挑的固定值;插件各自只认自己的请求码。 */
        private const val REQUEST_CODE = 0x504C
        private const val BUFFER = 1 shl 16
        private val main = Handler(Looper.getMainLooper())
    }
}
