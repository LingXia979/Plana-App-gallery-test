import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

/// 把磁盘上的 [file] 经系统保存对话框存到用户挑的位置,返回落点;取消返回 null。
///
/// 安卓上**只把路径交给原生侧**,由它边读边写(`DocumentSaver.kt`)。file_picker 的
/// saveFile 在安卓只收字节 —— 整份读进内存再经通道拷一份,几百张图打的包两份一叠
/// 就 OOM。几 KB 的导出(规则、Vibe)照旧直接用 file_picker,不必走这条。
///
/// 写失败抛 [PlatformException],`message` 是能直接展示的原因。
Future<String?> saveFileAs(
  File file, {
  required String fileName,
  required String mime,
}) async {
  if (!Platform.isAndroid) {
    // 其它平台没有这条通道,维持原来的做法
    return FilePicker.platform.saveFile(
      fileName: fileName,
      bytes: await file.readAsBytes(),
    );
  }
  return const MethodChannel('plana/document').invokeMethod<String>('saveAs', {
    'path': file.path,
    'name': fileName,
    'mime': mime,
  });
}
