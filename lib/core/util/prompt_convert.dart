/// SD WebUI ↔ NAI 提示词权重语法整串转换(移植自 web 工具箱 MobileToolsPage):
/// SD→NAI:`(x:1.05)`→`{x}`、`(x:0.95)`→`[x]`、`(x:w)`→`w::x::`、裸 `(x)`→`{x}`、
/// `\(`/`\)`→字面括号;NAI→SD:`{x}`→`(x:1.05)`、`w::x::`→`(x:w)`、
/// `[..]` 原样、字面括号转义。数字按 JS Number 字符串语义输出(整数去 .0)。
library;

/// 去除 `<lora:…>` 标签并清理残留逗号(SD→NAI 前置清洗,与 web 同款)。
String stripLoraTags(String input) {
  return input
      .replaceAll(RegExp(r'<lora:[^>]*>'), '')
      .replaceAll(RegExp(r',\s*,'), ',')
      .replaceAll(RegExp(r'^\s*,|,\s*$'), '')
      .trim();
}

/// 去掉 `<lora:…>` / `<lyco:…>` / `<hypernet:…>` 这类内联标签并收拾残留逗号。
///
/// 只动标签,**不动权重语法** —— 权重要不要转成 NAI 方言取决于导入目标,
/// 在解析阶段就转会让详情页显示的不是图里的原文(对齐 web `stripSDTags`)。
String stripInlineTags(String input) {
  return input
      .replaceAll(RegExp(r'<lora:[^>]+>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<lyco:[^>]+>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<hypernet:[^>]+>', caseSensitive: false), '')
      .replaceAll(RegExp(r',\s*,'), ',')
      .replaceAll(RegExp(r'^\s*,|,\s*$'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _jsNum(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// 拼 NAI 数值权重 `w::内容::`。
///
/// 内容以数字结尾时在收口前补一个空格:`year 2025::` 里的 `2025::` 长得和
/// 权重前缀一模一样,NAI 会把它读成「从这里起权重 2025」,得写成 `year 2025 ::`。
String naiNumWeight(String weight, String content) {
  final last = content.isEmpty ? 0 : content.codeUnitAt(content.length - 1);
  final pad = last >= 0x30 && last <= 0x39 ? ' ' : '';
  return '$weight::$content$pad::';
}

final _numRe = RegExp(r'^\s*-?\d+(?:\.\d+)?\s*$');

String convertSdToNai(String text) {
  final res = StringBuffer();
  var i = 0;
  final n = text.length;
  while (i < n) {
    final ch = text[i];
    if (ch == r'\' && i + 1 < n && (text[i + 1] == '(' || text[i + 1] == ')')) {
      res.write(text[i + 1]);
      i += 2;
      continue;
    }
    if (ch == '(') {
      var depth = 1;
      var j = i + 1;
      while (j < n && depth > 0) {
        if (text[j] == '(') {
          depth++;
        } else if (text[j] == ')') {
          depth--;
        }
        j++;
      }
      if (depth == 0) {
        final inner = text.substring(i + 1, j - 1);
        final lastColon = inner.lastIndexOf(':');
        if (lastColon > 0) {
          final left = inner.substring(0, lastColon);
          final right = inner.substring(lastColon + 1);
          if (_numRe.hasMatch(right)) {
            final weight = double.parse(right.trim());
            final content = convertSdToNai(left);
            if ((weight - 1.05).abs() < 0.001) {
              res.write('{$content}');
            } else if ((weight - 0.952381).abs() < 0.001 ||
                (weight - 0.95).abs() < 0.001) {
              res.write('[$content]');
            } else {
              res.write(naiNumWeight(_jsNum(weight), content));
            }
            i = j;
            continue;
          }
        }
        res.write('{${convertSdToNai(inner)}}');
        i = j;
        continue;
      }
    } else if (ch == '[') {
      var depth = 1;
      var j = i + 1;
      while (j < n && depth > 0) {
        if (text[j] == '[') {
          depth++;
        } else if (text[j] == ']') {
          depth--;
        }
        j++;
      }
      if (depth == 0) {
        res.write('[${convertSdToNai(text.substring(i + 1, j - 1))}]');
        i = j;
        continue;
      }
    }
    res.write(ch);
    i++;
  }
  return res.toString();
}

final _naiWeightRe = RegExp(r'(-?\d+(?:\.\d+)?)::');

String convertNaiToSd(String text) {
  final res = StringBuffer();
  var i = 0;
  final n = text.length;
  while (i < n) {
    final ch = text[i];
    if (RegExp(r'\d').hasMatch(ch) || ch == '-') {
      final m = _naiWeightRe.matchAsPrefix(text, i);
      if (m != null) {
        final weight = double.parse(m.group(1)!);
        final afterNum = m.end;
        final endIdx = text.indexOf('::', afterNum);
        if (endIdx != -1) {
          res.write(
            '(${convertNaiToSd(text.substring(afterNum, endIdx))}'
            ':${_jsNum(weight)})',
          );
          i = endIdx + 2;
          continue;
        }
      }
    }
    if (ch == '{') {
      var depth = 1;
      var j = i + 1;
      while (j < n && depth > 0) {
        if (text[j] == '{') {
          depth++;
        } else if (text[j] == '}') {
          depth--;
        }
        j++;
      }
      if (depth == 0) {
        res.write('(${convertNaiToSd(text.substring(i + 1, j - 1))}:1.05)');
        i = j;
        continue;
      }
    } else if (ch == '[') {
      var depth = 1;
      var j = i + 1;
      while (j < n && depth > 0) {
        if (text[j] == '[') {
          depth++;
        } else if (text[j] == ']') {
          depth--;
        }
        j++;
      }
      if (depth == 0) {
        res.write('[${convertNaiToSd(text.substring(i + 1, j - 1))}]');
        i = j;
        continue;
      }
    }
    if (ch == '(' || ch == ')') {
      res.write('\\$ch');
      i++;
      continue;
    }
    res.write(ch);
    i++;
  }
  return res.toString();
}
