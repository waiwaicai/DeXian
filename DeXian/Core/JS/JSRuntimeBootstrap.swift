import Foundation
import JavaScriptCore

/// 书源 JS 的运行时兼容层（Rhino / Android 环境模拟）。
///
/// 这段脚本注入到每个 JSContext 的全局作用域，补齐 JavaScriptCore 上
/// **完全没有**、但书源脚本默认存在的设施：
///
/// - Packages.java.lang / java.util / java.io / java.nio / javax.crypto / org.jsoup
/// - JavaImporter / importPackage，以及可直接使用的 HashMap、Arrays、Cipher 等类名
/// - CryptoJS（AES / DES / 3DES / MD5 / SHA* / Hmac*）
/// - jQuery 风格的 $（在书源语境里是「在当前文档上求值这条规则」）
/// - java.util.List 语义（.size() / .get(i) / .isEmpty()）
///
/// 上一版的崩溃根因就是这个对象层级写错：lang / util 被挂到了 org 下，
/// 于是 new Packages.java.lang.String(...) 里 Packages.java.lang 是 undefined，
/// 对 undefined 取属性会在 JavaScriptCore 内部直接命中断点陷阱（SIGTRAP）。
/// 这里的层级与真实 JDK 一致。
///
/// 两处**刻意不做**的别名，都是实测踩过的坑：
/// - 不定义 var String —— 书源里 String(x) 有 1877 处原生调用，
///   被包装对象遮蔽后会返回对象，页面直接显示 [object Object]；
/// - 不定义 var Boolean —— [,].filter(Boolean) 是原生用法。
///
/// 计算密集的部分（摘要 / HMAC / 分组密码 / inflate）不在 JS 里重写，
/// 全部通过 __dx.* 转发到 Swift 原生实现（见 JSEngineRuntime.swift）。
enum JSRuntimeBootstrap {

    /// 兼容层脚本。用 Swift 原生字符串字面量内联，
    /// 避免依赖「资源文件是否被打进 bundle」这种构建期不确定性。
    static let source: String = #"""
// ============================================================================
// 得闲 JS 运行时兼容层
// ----------------------------------------------------------------------------
// 书源脚本假定自己跑在 Legado 的 Rhino + Android 环境里，会直接使用
// Packages.*（Java 命名空间）、JavaImporter、CryptoJS、jQuery 风格的 $。
// JavaScriptCore 一个都没有，缺一个就会在求值期抛异常，
// 而异常又发生在 @convention(block) 回调返回路径上 —— 直接把进程打成 SIGTRAP。
//
// 这里把整套环境补齐。计算密集的部分（摘要 / HMAC / 分组密码 / inflate）
// 全部通过 __dx.* 落到原生实现，JS 只做参数搬运。
// ============================================================================

function __dxSlice(a, off, len) {
  var out = [];
  if (!a) { return out; }
  for (var i = 0; i < len; i++) { out.push(a[(off | 0) + i]); }
  return out;
}

function __dxUnsigned(bytes) {
  var out = [];
  if (!bytes) { return out; }
  for (var i = 0; i < bytes.length; i++) { out.push(bytes[i] & 255); }
  return out;
}

// ---------------------------------------------------------------------------
// Java List 语义。
// 书源里 java.getStringList(...) / elements.select(...) 的返回值一律按
// java.util.List 使用：.size() / .get(i) / .isEmpty()。原实现直接桥成 JS 数组，
// 只有 .length 没有 .size()，于是 bs.size() 抛 TypeError。
// ---------------------------------------------------------------------------
function __dxRebuildList(list, items) {
  for (var k in list) {
    if (/^[0-9]+$/.test(k)) { delete list[k]; }
  }
  for (var i = 0; i < items.length; i++) { list[i] = items[i]; }
  list.length = items.length;
}

function __dxWrapList(items) {
  var data = items ? Array.prototype.slice.call(items) : [];
  var list = {
    __isJavaList: true,
    length: data.length,
    size: function () { return data.length; },
    isEmpty: function () { return data.length === 0; },
    get: function (i) { return data[i | 0]; },
    getOrNull: function (i) { return data[i | 0]; },
    set: function (i, v) { data[i | 0] = v; list[i | 0] = v; return v; },
    first: function () { return data[0]; },
    last: function () { return data[data.length - 1]; },
    contains: function (v) { return data.indexOf(v) >= 0; },
    indexOf: function (v) { return data.indexOf(v); },
    add: function (v) { data.push(v); list[data.length - 1] = v; list.length = data.length; return true; },
    addAll: function (other) { for (var i = 0; i < other.length; i++) { list.add(other[i]); } return true; },
    clear: function () { data = []; __dxRebuildList(list, data); },
    remove: function (i) { return data.splice(i | 0, 1)[0]; },
    toArray: function () { return data.slice(); },
    join: function (s) { return data.join(s === undefined ? ',' : s); },
    slice: function (a, b) { return data.slice(a, b); },
    concat: function (o) { return data.concat(o); },
    map: function (fn) { return data.map(function (v, i) { return fn(v, i); }); },
    filter: function (fn) { return data.filter(function (v, i) { return fn(v, i); }); },
    some: function (fn) { return data.some(function (v, i) { return fn(v, i); }); },
    every: function (fn) { return data.every(function (v, i) { return fn(v, i); }); },
    find: function (fn) { for (var i = 0; i < data.length; i++) { if (fn(data[i], i)) { return data[i]; } } return null; },
    forEach: function (fn) { for (var i = 0; i < data.length; i++) { fn(data[i], i); } },
    sort: function (fn) { data.sort(fn); __dxRebuildList(list, data); return list; },
    reverse: function () { data.reverse(); __dxRebuildList(list, data); return list; },
    // jsoup Elements 的集合方法。书源会把规则求出的列表直接当元素集合用，
    // 例：result.toArray() 之后仍会调 .attr('href') / .text() / .select('a')。
    // 元素列表由 Swift 侧包装（每个元素自带 attr/text/select），
    // 这里把集合级调用按「逐个元素取值再收集」实现，与 jsoup 语义一致。
    attr: function (name) {
      if (arguments.length === 0) { return data.length ? (data[0].attr ? data[0].attr('') : '') : ''; }
      if (arguments.length > 1) {
        for (var i = 0; i < data.length; i++) { if (data[i].attr) { data[i].attr(name, arguments[1]); } }
        return list;
      }
      return data.length && data[0].attr ? data[0].attr(name) : '';
    },
    text: function () { return data.length && data[0].text ? data[0].text() : ''; },
    html: function () { return data.length && data[0].html ? data[0].html() : ''; },
    outerHtml: function () { return data.length && data[0].outerHtml ? data[0].outerHtml() : ''; },
    eachAttr: function (name) {
      var out = [];
      for (var i = 0; i < data.length; i++) { if (data[i].attr) { out.push(data[i].attr(name)); } }
      return out;
    },
    eachText: function () {
      var out = [];
      for (var i = 0; i < data.length; i++) { if (data[i].text) { out.push(data[i].text()); } }
      return out;
    },
    select: function (selector) {
      var out = [];
      for (var i = 0; i < data.length; i++) {
        if (!data[i].select) { continue; }
        var found = data[i].select(selector);
        var n = (found && typeof found.size === 'function') ? found.size() : (found ? found.length : 0);
        for (var j = 0; j < n; j++) { out.push(found.get ? found.get(j) : found[j]); }
      }
      return __dxWrapList(out);
    },
    eq: function (i) { return data[i | 0]; },
    empty: function () { return false; },
    clone: function () { return __dxWrapList(data.slice()); },
    iterator: function () {
      var cursor = 0;
      return {
        hasNext: function () { return cursor < data.length; },
        next: function () { return data[cursor++]; },
        remove: function () {}
      };
    },
    toString: function () { return data.join(','); }
  };
  __dxRebuildList(list, data);
  return list;
}

// ---------------------------------------------------------------------------
// java.lang.String 的包装对象。
// 书源大量写 new Packages.java.lang.String(x).getBytes('UTF-8')，
// 以及四参形式 new String(byteArray, offset, length, charset) 做解码。
// 注意：构造器必须返回**对象**（返回值是原始类型时 new 会丢弃它），
// 所以不能直接返回 JS 字符串。
// ---------------------------------------------------------------------------
function __dxJavaString(v) {
  var s;
  if (v === undefined || v === null) { s = ''; }
  else if (v && v.__isJavaString) { s = v.__value; }
  else if (typeof v === 'string') { s = v; }
  else { s = String(v); }
  return {
    __isJavaString: true,
    __value: s,
    toString: function () { return s; },
    valueOf: function () { return s; },
    isEmpty: function () { return s.length === 0; },
    length: function () { return s.length; },
    // Java 的 getBytes(charset) 必须按传入编码取字节：
    // 书源常用 getBytes('ISO8859_1') 做密钥，当成 UTF-8 会得到完全不同的密钥。
    getBytes: function (charset) { return __dx.u8cs(s, charset === undefined ? 'UTF-8' : charset); },
    toCharArray: function () { return s.split(''); },
    charAt: function (i) { return s.charAt(i | 0); },
    codePointAt: function (i) { return s.charCodeAt(i | 0); },
    substring: function (a, b) { return s.substring(a | 0, b === undefined ? undefined : (b | 0)); },
    subSequence: function (a, b) { return s.substring(a | 0, b | 0); },
    split: function (sep) { return s.split(String(sep)); },
    replace: function (a, b) { return s.split(String(a)).join(String(b)); },
    replaceAll: function (a, b) { try { return s.replace(new RegExp(a, 'g'), b); } catch (e) { return s; } },
    indexOf: function (x) { return s.indexOf(String(x)); },
    lastIndexOf: function (x) { return s.lastIndexOf(String(x)); },
    contains: function (x) { return s.indexOf(String(x)) >= 0; },
    startsWith: function (p) { return s.indexOf(String(p)) === 0; },
    endsWith: function (p) { var q = String(p); return s.length >= q.length && s.slice(-q.length) === q; },
    trim: function () { return s.trim(); },
    toLowerCase: function () { return s.toLowerCase(); },
    toUpperCase: function () { return s.toUpperCase(); },
    concat: function (o) { return s + String(o); },
    equals: function (o) { return s === String(o); },
    equalsIgnoreCase: function (o) { return s.toLowerCase() === String(o).toLowerCase(); },
    compareTo: function (o) { return s < String(o) ? -1 : (s > String(o) ? 1 : 0); },
    hashCode: function () {
      var h = 0;
      for (var i = 0; i < s.length; i++) { h = ((h * 31) + s.charCodeAt(i)) | 0; }
      return h;
    },
    matches: function (p) { try { return new RegExp('^' + p + '$').test(s); } catch (e) { return false; } }
  };
}

// ---------------------------------------------------------------------------
// java.util.zip.Inflater（书源里手写 ZIP 解包会用）
// ---------------------------------------------------------------------------
function __dxInflater() {
  var input = [];
  return {
    setInput: function (b, off, len) {
      input = (off === undefined) ? __dxUnsigned(b) : __dxUnsigned(__dxSlice(b, off, len));
    },
    inflate: function (dest) {
      var out = __dx.rawInflate(input);
      var n = Math.min(out.length, dest ? dest.length : 0);
      for (var i = 0; i < n; i++) { dest[i] = out[i] & 255; }
      return n;
    },
    end: function () {},
    reset: function () {},
    finished: function () { return true; },
    needsInput: function () { return input.length === 0; },
    getRemaining: function () { return 0; },
    getTotalOut: function () { return 0; }
  };
}

function __dxInflaterInputStream(source) {
  var data = (source && source.readAll) ? source.readAll() : (source || []);
  var out = __dx.rawInflate(__dxUnsigned(data));
  var pos = 0;
  return {
    read: function (buf, off, len) {
      if (pos >= out.length) { return -1; }
      if (buf && typeof buf === 'object' && len !== undefined) {
        var n = Math.min(len, out.length - pos);
        for (var i = 0; i < n; i++) { buf[(off | 0) + i] = out[pos + i] & 255; }
        pos += n;
        return n;
      }
      return out[pos++] & 255;
    },
    available: function () { return out.length - pos; },
    readAll: function () { return out.slice(); },
    close: function () {}
  };
}


// ---------------------------------------------------------------------------
// java.*
// ---------------------------------------------------------------------------
var __dxJavaLang = {
  String: function (a, b, c, d) {
    // 四参形式：new String(byteArray, offset, length, charset)
    if (a !== null && a !== undefined && typeof a === 'object'
        && typeof a.length === 'number' && b !== undefined) {
      var off = b | 0;
      var len = (c === undefined) ? (a.length - off) : (c | 0);
      var charset = (d === undefined) ? 'UTF-8' : String(d);
      return __dxJavaString(__dx.bytesToStr(__dxSlice(a, off, len), charset));
    }
    return __dxJavaString(a);
  },
  StringBuilder: function () {
    var buf = [];
    var api = {
      append: function (x) { buf.push(x === undefined || x === null ? 'null' : String(x)); return api; },
      insert: function (i, x) { buf.splice(i | 0, 0, String(x)); return api; },
      delete: function (a, b) { buf.splice(a | 0, (b | 0) - (a | 0)); return api; },
      deleteCharAt: function (i) { buf.splice(i | 0, 1); return api; },
      reverse: function () { buf.reverse(); return api; },
      length: function () { return buf.join('').length; },
      charAt: function (i) { return buf.join('').charAt(i | 0); },
      setLength: function () { return api; },
      toString: function () { return buf.join(''); }
    };
    return api;
  },
  StringBuffer: function () { return __dxJavaLang.StringBuilder(); },
  Integer: {
    parseInt: function (s) { var n = parseInt(s, 10); return isNaN(n) ? 0 : n; },
    valueOf: function (s) { return __dxJavaLang.Integer.parseInt(s); },
    toString: function (n) { return String(n); },
    toHexString: function (n) { return (n >>> 0).toString(16); },
    toBinaryString: function (n) { return (n >>> 0).toString(2); },
    MAX_VALUE: 2147483647,
    MIN_VALUE: -2147483648
  },
  Long: {
    parseLong: function (s) { var n = parseInt(s, 10); return isNaN(n) ? 0 : n; },
    valueOf: function (s) { return parseInt(s, 10) || 0; },
    toString: function (n) { return String(n); },
    MAX_VALUE: 9007199254740991
  },
  Double: {
    parseDouble: function (s) { var n = parseFloat(s); return isNaN(n) ? 0 : n; },
    valueOf: function (s) { return parseFloat(s) || 0; },
    toString: function (n) { return String(n); }
  },
  Float: {
    parseFloat: function (s) { var n = parseFloat(s); return isNaN(n) ? 0 : n; },
    valueOf: function (s) { return parseFloat(s) || 0; }
  },
  Boolean: {
    parseBoolean: function (s) { return String(s).toLowerCase() === 'true'; },
    valueOf: function (s) { return String(s).toLowerCase() === 'true'; },
    TRUE: true,
    FALSE: false
  },
  Character: {
    isDigit: function (c) { return /[0-9]/.test(String(c)); },
    isLetter: function (c) { return /[a-zA-Z]/.test(String(c)); },
    isLetterOrDigit: function (c) { return /[0-9a-zA-Z]/.test(String(c)); },
    digit: function (c, r) { var n = parseInt(String(c), (r | 0) || 10); return isNaN(n) ? -1 : n; }
  },
  Byte: { parseByte: function (s) { return parseInt(s, 10) || 0; }, valueOf: function (s) { return parseInt(s, 10) || 0; } },
  Short: { parseShort: function (s) { return parseInt(s, 10) || 0; } },
  Object: function () { return {}; },
  Math: Math,
  System: {
    currentTimeMillis: function () { return Date.now(); },
    nanoTime: function () { return Date.now() * 1000000; },
    arraycopy: function (src, sp, dst, dp, len) {
      for (var i = 0; i < (len | 0); i++) { dst[(dp | 0) + i] = src[(sp | 0) + i]; }
    },
    getProperty: function (n) { return String(n) === 'line.separator' ? '\n' : ''; },
    lineSeparator: function () { return '\n'; },
    getenv: function () { return null; },
    exit: function () {},
    gc: function () {},
    out: {
      print: function (x) { java.log(x === undefined ? '' : String(x)); },
      println: function (x) { java.log(x === undefined ? '' : String(x)); },
      printf: function () { return this; }
    },
    err: { println: function (x) { java.log(String(x)); } }
  },
  Thread: {
    sleep: function (ms) { java.sleep(ms); },
    currentThread: function () { return { getId: function () { return 1; }, getName: function () { return 'main'; } }; },
    activeCount: function () { return 1; }
  },
  Class: {
    forName: function (n) { return { getName: function () { return String(n); }, newInstance: function () { return {}; } }; }
  },
  Throwable: function (m) { return new Error(m === undefined ? '' : String(m)); },
  Exception: function (m) { return new Error(m === undefined ? '' : String(m)); },
  RuntimeException: function (m) { return new Error(m === undefined ? '' : String(m)); },
  Error: function (m) { return new Error(m === undefined ? '' : String(m)); },
  IllegalArgumentException: function (m) { return new Error(m === undefined ? '' : String(m)); },
  NumberFormatException: function (m) { return new Error(m === undefined ? '' : String(m)); },
  UnsupportedOperationException: function (m) { return new Error(m === undefined ? '' : String(m)); },
  NullPointerException: function (m) { return new Error(m === undefined ? '' : String(m)); }
};

var __dxJavaSecurity = {
  MessageDigest: {
    getInstance: function (algorithm) {
      return {
        digest: function (bytes) { return __dx.digestBytes(String(algorithm), bytes || []); },
        update: function () {},
        reset: function () {},
        getAlgorithm: function () { return String(algorithm); },
        toString: function () { return String(algorithm); }
      };
    }
  },
  KeyGenerator: {
    getInstance: function (algorithm) {
      return {
        init: function () {},
        generateKey: function () {
          return { getEncoded: function () { return __dx.randomBytes(16); }, getAlgorithm: function () { return String(algorithm); } };
        }
      };
    }
  },
  SecureRandom: function () {
    return {
      nextBytes: function (buf) {
        var b = __dx.randomBytes(buf ? buf.length : 0);
        if (buf) { for (var i = 0; i < buf.length; i++) { buf[i] = b[i] & 255; } }
      },
      nextInt: function () { return Math.floor(Math.random() * 2147483647); }
    };
  },
  spec: {}
};


var __dxJavaUtil = {
  Arrays: {
    // Java 的 Arrays.copyOf 会用 0 补齐到目标长度；
    // 留 undefined 会让后面 join('') / 字节运算得到 "null"/"undefined" 文本。
    copyOf: function (a, n) {
      var out = [];
      for (var i = 0; i < (n | 0); i++) {
        var v = a ? a[i] : 0;
        out.push(v === undefined || v === null ? 0 : v);
      }
      return out;
    },
    copyOfRange: function (a, from, to) {
      var out = [];
      for (var i = (from | 0); i < (to | 0); i++) {
        var v = a ? a[i] : 0;
        out.push(v === undefined || v === null ? 0 : v);
      }
      return out;
    },
    asList: function () { return __dxWrapList(Array.prototype.slice.call(arguments)); },
    toString: function (a) {
      if (!a) { return ''; }
      var out = [];
      for (var i = 0; i < a.length; i++) { out.push(String(a[i])); }
      return '[' + out.join(', ') + ']';
    },
    sort: function (a, cmp) { if (a && a.sort) { a.sort(cmp); } },
    fill: function (a, v) { if (a) { for (var i = 0; i < a.length; i++) { a[i] = v; } } },
    equals: function (a, b) {
      if (!a || !b || a.length !== b.length) { return false; }
      for (var i = 0; i < a.length; i++) { if (a[i] !== b[i]) { return false; } }
      return true;
    },
    hashCode: function (a) {
      var h = 1;
      if (a) { for (var i = 0; i < a.length; i++) { h = ((h * 31) + (a[i] | 0)) | 0; } }
      return h;
    }
  },
  HashMap: function () {
    var map = {};
    var api = {
      put: function (k, v) { map[String(k)] = v; return v; },
      putAll: function (other) {
        if (other && other.__keys) {
          for (var i = 0; i < other.__keys.length; i++) { map[other.__keys[i]] = other.__values[i]; }
        }
        return api;
      },
      get: function (k) { var key = String(k); return (key in map) ? map[key] : null; },
      getOrDefault: function (k, d) { var key = String(k); return (key in map) ? map[key] : d; },
      containsKey: function (k) { return String(k) in map; },
      containsValue: function (v) { for (var k in map) { if (map[k] === v) { return true; } } return false; },
      remove: function (k) { var key = String(k); var v = map[key]; delete map[key]; return v; },
      size: function () { return Object.keys(map).length; },
      isEmpty: function () { return Object.keys(map).length === 0; },
      clear: function () { map = {}; return api; },
      keySet: function () { return __dxWrapList(Object.keys(map)); },
      values: function () {
        var ks = Object.keys(map); var out = [];
        for (var i = 0; i < ks.length; i++) { out.push(map[ks[i]]); }
        return __dxWrapList(out);
      },
      entrySet: function () {
        var ks = Object.keys(map);
        var out = [];
        for (var i = 0; i < ks.length; i++) {
          (function (k) {
            out.push({
              getKey: function () { return k; },
              getValue: function () { return map[k]; },
              setValue: function (v) { map[k] = v; return v; },
              toString: function () { return k + '=' + String(map[k]); }
            });
          })(ks[i]);
        }
        return __dxWrapList(out);
      },
      forEach: function (fn) { var ks = Object.keys(map); for (var i = 0; i < ks.length; i++) { fn(map[ks[i]], ks[i]); } },
      toString: function () { try { return JSON.stringify(map); } catch (e) { return '{}'; } }
    };
    return api;
  },
  LinkedHashMap: function () { return __dxJavaUtil.HashMap(); },
  ArrayList: function (items) { return __dxWrapList(items ? Array.prototype.slice.call(items) : []); },
  LinkedList: function () { return __dxWrapList([]); },
  HashSet: function (items) { return __dxWrapList(items ? Array.prototype.slice.call(items) : []); },
  TreeMap: function () { return __dxJavaUtil.HashMap(); },
  Collections: {
    emptyList: function () { return __dxWrapList([]); },
    emptyMap: function () { return __dxJavaUtil.HashMap(); },
    singletonList: function (v) { return __dxWrapList([v]); },
    sort: function (a) { if (a && a.sort) { a.sort(); } },
    reverse: function (a) { if (a && a.reverse) { a.reverse(); } },
    shuffle: function (a) { if (a && a.sort) { a.sort(function () { return Math.random() - 0.5; }); } }
  },
  Base64: {
    getEncoder: function () {
      return {
        encodeToString: function (b) { return __dx.b64e(b); },
        encode: function (b) { return __dx.u8(__dx.b64e(b)); },
        withoutPadding: function () { return this; }
      };
    },
    getDecoder: function () {
      return {
        decode: function (s) { return __dx.b64d(s); },
        decodeToString: function (s) { return __dx.bytesToStr(__dx.b64d(s), 'UTF-8'); }
      };
    },
    getUrlEncoder: function () {
      return {
        encodeToString: function (b) { return __dx.b64e(b).split('+').join('-').split('/').join('_'); },
        withoutPadding: function () { return this; }
      };
    },
    getUrlDecoder: function () {
      return {
        decode: function (s) {
          var t = String(s).split('-').join('+').split('_').join('/');
          return __dx.b64d(t);
        }
      };
    }
  },
  UUID: { randomUUID: function () { return { toString: function () { return java.randomUUID(); } }; } },
  Objects: {
    toString: function (o, d) { return (o === null || o === undefined) ? d : String(o); },
    requireNonNull: function (o) { return o; },
    equals: function (a, b) { return a === b; },
    hash: function () { return 0; },
    isNull: function (o) { return o === null || o === undefined; },
    nonNull: function (o) { return o !== null && o !== undefined; }
  },
  Optional: {
    of: function (v) { return { get: function () { return v; }, isPresent: function () { return true; }, orElse: function () { return v; } }; },
    empty: function () { return { get: function () { return null; }, isPresent: function () { return false; }, orElse: function (d) { return d; } }; },
    ofNullable: function (v) {
      return (v === null || v === undefined) ? __dxJavaUtil.Optional.empty() : __dxJavaUtil.Optional.of(v);
    }
  },
  regex: {
    Pattern: {
      compile: function (pattern) {
        return {
          matcher: function (s) {
            return {
              find: function () { try { return new RegExp(pattern).test(String(s)); } catch (e) { return false; } },
              matches: function () { try { return new RegExp('^' + pattern + '$').test(String(s)); } catch (e) { return false; } },
              group: function (i) { try { var m = String(s).match(new RegExp(pattern)); return m ? m[i | 0] : null; } catch (e) { return null; } },
              replaceAll: function (r) { try { return String(s).replace(new RegExp(pattern, 'g'), r); } catch (e) { return String(s); } }
            };
          },
          pattern: function () { return String(pattern); },
          split: function (s) { try { return String(s).split(new RegExp(pattern)); } catch (e) { return [String(s)]; } }
        };
      },
      quote: function (s) { return String(s).replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&'); }
    }
  },
  zip: {
    Inflater: __dxInflater,
    Deflater: function () { return { setInput: function () {}, deflate: function () { return 0; }, end: function () {} }; },
    InflaterInputStream: __dxInflaterInputStream,
    GZIPInputStream: function (s) { return __dxInflaterInputStream(s); },
    ZipInputStream: function () { return { getNextEntry: function () { return null; }, read: function () { return -1; }, close: function () {} }; }
  },
  concurrent: { ConcurrentHashMap: function () { return __dxJavaUtil.HashMap(); }, TimeUnit: {} }
};


var __dxJavaIO = {
  ByteArrayOutputStream: function () {
    var bytes = [];
    var api = {
      write: function (b, off, len) {
        if (b && typeof b === 'object' && typeof b.length === 'number') {
          var start = (off === undefined) ? 0 : (off | 0);
          var count = (len === undefined) ? (b.length - start) : (len | 0);
          for (var i = 0; i < count; i++) { bytes.push(b[start + i] & 255); }
        } else {
          bytes.push(b & 255);
        }
        return api;
      },
      writeBytes: function (b) { return api.write(b); },
      toByteArray: function () {
        var out = [];
        for (var i = 0; i < bytes.length; i++) { out.push(bytes[i] > 127 ? bytes[i] - 256 : bytes[i]); }
        return out;
      },
      toString: function (charset) {
        var out = [];
        for (var i = 0; i < bytes.length; i++) { out.push(bytes[i] > 127 ? bytes[i] - 256 : bytes[i]); }
        return __dx.bytesToStr(out, charset === undefined ? 'UTF-8' : String(charset));
      },
      size: function () { return bytes.length; },
      reset: function () { bytes = []; },
      flush: function () {},
      close: function () {}
    };
    return api;
  },
  ByteArrayInputStream: function (b) {
    var data = b ? Array.prototype.slice.call(b) : [];
    var pos = 0;
    return {
      read: function (buf, off, len) {
        if (buf && typeof buf === 'object' && len !== undefined) {
          var n = Math.min(len, data.length - pos);
          for (var i = 0; i < n; i++) { buf[(off | 0) + i] = data[pos + i] & 255; }
          pos += n;
          return n > 0 ? n : -1;
        }
        return pos < data.length ? (data[pos++] & 255) : -1;
      },
      readAll: function () { return data.slice(); },
      available: function () { return data.length - pos; },
      skip: function (n) { pos += (n | 0); return n; },
      close: function () {}
    };
  },
  BufferedReader: function (reader) {
    var text = '';
    if (typeof reader === 'string') { text = reader; }
    else if (reader && reader.readAll) { text = __dx.bytesToStr(reader.readAll(), 'UTF-8'); }
    var lines = String(text).split(/\r?\n/);
    var cursor = 0;
    return {
      readLine: function () { return cursor < lines.length ? lines[cursor++] : null; },
      lines: function () { return __dxWrapList(lines); },
      close: function () {}
    };
  },
  InputStreamReader: function (s) { return s; },
  OutputStreamWriter: function () { return {}; },
  PrintStream: function () {
    return {
      print: function (x) { java.log(String(x)); },
      println: function (x) { java.log(String(x)); },
      close: function () {},
      flush: function () {}
    };
  },
  File: function (path) {
    return {
      getPath: function () { return String(path); },
      getAbsolutePath: function () { return String(path); },
      getName: function () { var a = String(path).split('/'); return a[a.length - 1]; },
      exists: function () { return false; },
      length: function () { return 0; },
      delete: function () { return false; },
      mkdirs: function () { return false; },
      toString: function () { return String(path); }
    };
  },
  FileInputStream: function () {
    return { read: function () { return -1; }, readAll: function () { return []; }, available: function () { return 0; }, close: function () {} };
  },
  FileOutputStream: function () { return { write: function () {}, flush: function () {}, close: function () {} }; },
  IOException: function (m) { return new Error(m === undefined ? '' : String(m)); },
  InputStream: function () {},
  OutputStream: function () {}
};

var __dxJavaNio = {
  ByteBuffer: {
    allocate: function (capacity) {
      var buf = { b: [], pos: 0, cap: capacity | 0 };
      var api = {
        put: function (x, off, len) {
          if (x && typeof x === 'object' && typeof x.length === 'number') {
            var start = (off === undefined) ? 0 : (off | 0);
            var count = (len === undefined) ? (x.length - start) : (len | 0);
            for (var i = 0; i < count; i++) { buf.b.push(x[start + i] & 255); }
          } else {
            buf.b.push(x & 255);
          }
          return api;
        },
        putInt: function (v) { for (var i = 3; i >= 0; i--) { buf.b.push((v >> (i * 8)) & 255); } return api; },
        putShort: function (v) { buf.b.push((v >> 8) & 255, v & 255); return api; },
        get: function (i) {
          if (i === undefined) { return buf.b[buf.pos++] & 255; }
          return (buf.b[i | 0] & 255) || 0;
        },
        getInt: function (i) {
          var p;
          if (i === undefined) { p = buf.pos; buf.pos += 4; } else { p = i | 0; }
          return ((buf.b[p] << 24) | (buf.b[p + 1] << 16) | (buf.b[p + 2] << 8) | buf.b[p + 3]);
        },
        getShort: function (i) {
          var p;
          if (i === undefined) { p = buf.pos; buf.pos += 2; } else { p = i | 0; }
          return ((buf.b[p] << 8) | buf.b[p + 1]);
        },
        array: function () { return buf.b.slice(); },
        position: function (i) { if (i === undefined) { return buf.pos; } buf.pos = i | 0; return api; },
        limit: function (i) { if (i === undefined) { return buf.cap; } buf.cap = i | 0; return api; },
        capacity: function () { return buf.cap; },
        remaining: function () { return Math.max(0, buf.cap - buf.pos); },
        hasRemaining: function () { return buf.cap > buf.pos; },
        flip: function () { buf.cap = buf.pos; buf.pos = 0; return api; },
        rewind: function () { buf.pos = 0; return api; },
        clear: function () { buf.b = []; buf.pos = 0; return api; },
        order: function (o) { if (o === undefined) { return 'BE'; } return api; },
        arrayOffset: function () { return 0; }
      };
      return api;
    },
    wrap: function (b) {
      var api = __dxJavaNio.ByteBuffer.allocate(b ? b.length : 0);
      api.put(b);
      api.flip();
      return api;
    }
  },
  ByteOrder: {
    BIG_ENDIAN: 'BE',
    LITTLE_ENDIAN: 'LE',
    nativeOrder: function () { return 'LE'; }
  },
  charset: {
    StandardCharsets: {
      UTF_8: { name: function () { return 'UTF-8'; }, toString: function () { return 'UTF-8'; } },
      ISO_8859_1: { name: function () { return 'ISO-8859-1'; }, toString: function () { return 'ISO-8859-1'; } },
      US_ASCII: { name: function () { return 'US-ASCII'; }, toString: function () { return 'US-ASCII'; } }
    },
    Charset: {
      forName: function (n) { return { name: function () { return String(n); }, toString: function () { return String(n); } }; }
    }
  }
};

// Android 侧只需要「存在且不炸」。少数书源用它做截图比对，
// 拿不到真实位图时会走自己的失败分支，而不是让整条规则链断掉。
var __dxAndroid = {
  graphics: {
    Bitmap: {
      createBitmap: function () {
        return { getWidth: function () { return 0; }, getHeight: function () { return 0; }, getPixel: function () { return 0; }, compress: function () { return true; } };
      },
      Config: { ARGB_8888: 'ARGB_8888', RGB_565: 'RGB_565' }
    },
    Rect: function () { return { left: 0, top: 0, right: 0, bottom: 0, width: function () { return 0; }, height: function () { return 0; } }; },
    Color: { red: function () { return 0; }, green: function () { return 0; }, blue: function () { return 0; }, rgb: function () { return 0; } },
    BitmapFactory: { decodeByteArray: function () { return null; }, decodeStream: function () { return null; } }
  },
  util: {
    Base64: {
      encodeToString: function (b) { return __dx.b64e(b); },
      decode: function (s) { return __dx.b64d(s); },
      DEFAULT: 0, NO_WRAP: 2, URL_SAFE: 8
    }
  },
  text: {
    TextUtils: {
      isEmpty: function (s) { return s === null || s === undefined || String(s).length === 0; },
      join: function (d, a) { return (a || []).join(d); }
    }
  },
  os: { Build: { VERSION: { SDK_INT: 34, RELEASE: '14' }, MODEL: 'DeXian', MANUFACTURER: 'DeXian', DEVICE: 'ios' } }
};


// ---------------------------------------------------------------------------
// javax.*
// ---------------------------------------------------------------------------
var __dxJavaxCrypto = {
  Cipher: {
    ENCRYPT_MODE: 1,
    DECRYPT_MODE: 2,
    WRAP_MODE: 3,
    UNWRAP_MODE: 4,
    getInstance: function (transformation) {
      var name = String(transformation);
      var key = null;
      var iv = null;
      var encrypting = false;
      var api = {
        init: function (mode, k, i) {
          encrypting = (mode === 1);
          key = k;
          iv = i;
          return api;
        },
        doFinal: function (data) {
          var keyBytes = (key && key.getEncoded) ? key.getEncoded() : key;
          var ivBytes = (iv && iv.getIV) ? iv.getIV() : null;
          var payload = (data === undefined || data === null) ? [] : data;
          return __dx.cipher(encrypting, name, keyBytes, payload, ivBytes);
        },
        update: function () { return []; },
        getBlockSize: function () { return (/des/i.test(name) && !/aes/i.test(name)) ? 8 : 16; },
        getAlgorithm: function () { return name; },
        getIV: function () { return (iv && iv.getIV) ? iv.getIV() : null; }
      };
      return api;
    },
    getMaxAllowedKeyLength: function () { return 256; }
  },
  spec: {
    SecretKeySpec: function (keyBytes, algorithm) {
      return { getEncoded: function () { return keyBytes; }, getAlgorithm: function () { return String(algorithm); } };
    },
    IvParameterSpec: function (ivBytes) { return { getIV: function () { return ivBytes; } }; },
    GCMParameterSpec: function (tagLength, ivBytes) {
      return { getIV: function () { return ivBytes; }, getTLen: function () { return tagLength; } };
    },
    PBEKeySpec: function (password) { return { getPassword: function () { return password; } }; },
    DESKeySpec: function (keyBytes) { return { getKey: function () { return keyBytes; } }; }
  },
  Mac: {
    getInstance: function (algorithm) {
      return {
        init: function () {},
        doFinal: function (bytes) { return __dx.hmacBytes(String(algorithm), bytes || [], []); }
      };
    }
  },
  MessageDigest: __dxJavaSecurity.MessageDigest,
  KeyGenerator: __dxJavaSecurity.KeyGenerator,
  SecureRandom: __dxJavaSecurity.SecureRandom
};

// ---------------------------------------------------------------------------
// org.jsoup
//
// 书源里 180 多处 Jsoup.parse + .select(...) + .size()/.get(i)/.text()。
// 真实现落在 Swift 的 HTML 解析器上（java.__jsoupParse），
// 这里只做「Java 集合语义」的适配。
// ---------------------------------------------------------------------------
function __dxJsoupDocument(html) {
  var root = java.__jsoupParse(html === undefined || html === null ? '' : String(html));
  var api = {
    select: function (selector) {
      return __dxWrapList(root ? root.select(selector) : []);
    },
    selectFirst: function (selector) {
      return (root && root.selectFirst) ? root.selectFirst(selector) : null;
    },
    getElementById: function (id) { return (root && root.selectFirst) ? root.selectFirst('#' + id) : null; },
    getElementsByTag: function (tag) { return (root && root.select) ? __dxWrapList(root.select(tag)) : __dxWrapList([]); },
    getElementsByClass: function (cls) { return (root && root.select) ? __dxWrapList(root.select('.' + cls)) : __dxWrapList([]); },
    text: function () { return (root && root.text) ? String(root.text()) : ''; },
    html: function () { return (root && root.html) ? String(root.html()) : String(html || ''); },
    outerHtml: function () { return (root && root.html) ? String(root.html()) : String(html || ''); },
    toString: function () { return (root && root.text) ? String(root.text()) : String(html || ''); },
    title: function () { return (root && root.selectFirst) ? String((root.selectFirst('title') || {}).text || '') : ''; },
    body: function () { return root; }
  };
  return api;
}

var __dxJsoup = {
  Jsoup: {
    parse: function (html) { return __dxJsoupDocument(html); },
    parseBodyFragment: function (html) { return __dxJsoupDocument(html); },
    connect: function (url) {
      var headers = {};
      var api = {
        header: function (k, v) { headers[String(k)] = v; return api; },
        userAgent: function (v) { headers['User-Agent'] = v; return api; },
        timeout: function () { return api; },
        ignoreContentType: function () { return api; },
        ignoreHttpErrors: function () { return api; },
        get: function () { return __dxJsoupDocument(java.ajax(String(url))); },
        post: function () { return __dxJsoupDocument(java.ajax(String(url))); },
        execute: function () {
          return {
            body: function () { return java.ajax(String(url)); },
            statusCode: function () { return 200; },
            parse: function () { return __dxJsoupDocument(java.ajax(String(url))); }
          };
        }
      };
      return api;
    }
  }
};


// ---------------------------------------------------------------------------
// Packages —— 这是上一版崩溃的直接原因。
//
// 书源里大量写 new Packages.java.lang.String(...) / Packages.java.util.Arrays，
// 上一版把 lang / util 错挂在 org 下面，导致 Packages.java.lang 是 undefined，
// 对 undefined 再取 .String 就在 JavaScriptCore 内部直接命中断点陷阱。
//
// java 子树必须直接映射到 __dxJava*，层级要与真实 JDK 一致。
// ---------------------------------------------------------------------------
var Packages = {
  java: {
    lang: __dxJavaLang,
    util: __dxJavaUtil,
    io: __dxJavaIO,
    nio: __dxJavaNio,
    net: { URL: function (u) { return { toString: function () { return String(u); } }; }, URLEncoder: { encode: function (s, c) { return encodeURIComponent(String(s)); } }, URLDecoder: { decode: function (s, c) { return decodeURIComponent(String(s)); } } },
    security: __dxJavaSecurity,
    text: { SimpleDateFormat: function (p) { var pat = String(p); return { format: function (t) { return java.timeFormat(t, pat); }, parse: function () { return Date.now(); } }; }, DecimalFormat: function (p) { return { format: function (n) { return String(n); } }; }, MessageFormat: { format: function (p) { return String(p); } } },
    math: { BigInteger: function (v) { var s = String(v); return { toString: function () { return s; }, add: function (o) { return s; }, multiply: function (o) { return s; } }; }, BigDecimal: function (v) { return { toString: function () { return String(v); } }; } },
    time: {},
    reflect: { Array: { newInstance: function (t, n) { return []; } } },
    System: __dxJavaLang.System,
    String: __dxJavaLang.String,
    Integer: __dxJavaLang.Integer,
    Long: __dxJavaLang.Long,
    Double: __dxJavaLang.Double,
    Boolean: __dxJavaLang.Boolean,
    Object: __dxJavaLang.Object,
    Math: Math,
    StringBuilder: __dxJavaLang.StringBuilder,
    StringBuffer: __dxJavaLang.StringBuffer,
    Throwable: __dxJavaLang.Throwable,
    Exception: __dxJavaLang.Exception,
    RuntimeException: __dxJavaLang.RuntimeException,
    Thread: __dxJavaLang.Thread,
    Class: __dxJavaLang.Class
  },
  javax: {
    crypto: __dxJavaxCrypto,
    net: {},
    script: {}
  },
  org: {
    jsoup: __dxJsoup,
    json: {},
    apache: { commons: { codec: { binary: { Base64: { encodeBase64String: function (b) { return __dx.b64e(b); }, decodeBase64: function (s) { return __dx.b64d(s); } } } } } }
  },
  android: __dxAndroid
};

// Legado 的 Rhino 支持 Java 包的「类名直接当全局变量用」写法：
// 例如 new HashMap() / new String() / Cipher.getInstance(...)。
// JavaImporter + with 是标准用法，这里提供同名类与 importPackage 让脚本能跑通。
// 书源的用法是：
//     var ji = new JavaImporter();
//     ji.importPackage(Packages.java.util, Packages.javax.crypto);
//     with (ji) { ... }
// 所以实例必须自带 importPackage 方法，并把命名空间合并到**自身**上，
// 否则 with (ji) 里找不到任何类名。
var JavaImporter = function () {
  var imported = {};
  imported.importPackage = function () {
    for (var i = 0; i < arguments.length; i++) {
      var ns = arguments[i];
      if (ns && typeof ns === 'object') {
        for (var k in ns) {
          try { imported[k] = ns[k]; } catch (e) {}
        }
      }
    }
    return imported;
  };
  imported.importClass = imported.importPackage;
  if (arguments.length) { imported.importPackage.apply(null, arguments); }
  return imported;
};

// importPackage / importClass 是 Rhino 的全局函数，书源会直接调用。
function importPackage(ns) { return ns; }
function importClass(ns) { return ns; }
function importJava() {}

// ---------------------------------------------------------------------------
// 裸包名。
//
// Rhino 里 org / javax / java / com 是全局可用的包对象，书源据此写
//     org.jsoup.Jsoup.parse(html)
//     javax.crypto.Cipher.getInstance('AES')
// 而不带 Packages. 前缀。实测语料里这种写法有 170 处，缺一个就是
// "ReferenceError: Can't find variable: org"，整条规则作废。
//
// 只暴露真正常用的三棵树；java 不作为裸名暴露 ——
// 书源里的 `java` 指的是宿主注入的 java 对象（java.ajax 等），
// 用包名覆盖它会让所有 java.* 调用消失。
// ---------------------------------------------------------------------------
var org = Packages.org;
var javax = Packages.javax;
var com = {};


// ---------------------------------------------------------------------------
// 让 new HashMap() / new String() / MessageDigest.getInstance(...) 这类
// 不带包名的写法可用。只补书源里真正出现过的类型，避免污染全局命名空间。
// ---------------------------------------------------------------------------
// 只补「书源真的会裸用、且不会撞原生全局」的类名。
//
// 绝不能 var String = ... —— 实测书源里 String(...) 有 1877 处原生调用
// （String(value) / String(x) === '' 等），一旦被包装对象遮蔽，
// 这些调用会返回对象而不是字符串，页面上直接变成
// "[object Object]"，比较逻辑全部失效。
// Boolean 同理：[,].filter(Boolean) 是原生用法。
var HashMap = __dxJavaUtil.HashMap;
var LinkedHashMap = __dxJavaUtil.LinkedHashMap;
var ArrayList = __dxJavaUtil.ArrayList;
var HashSet = __dxJavaUtil.HashSet;
var Arrays = __dxJavaUtil.Arrays;
var Base64 = __dxJavaUtil.Base64;
var UUID = __dxJavaUtil.UUID;
var Collections = __dxJavaUtil.Collections;
var Integer = __dxJavaLang.Integer;
var Long = __dxJavaLang.Long;
var Double = __dxJavaLang.Double;
var StringBuilder = __dxJavaLang.StringBuilder;
var StringBuffer = __dxJavaLang.StringBuffer;
var Character = __dxJavaLang.Character;
var ByteArrayOutputStream = __dxJavaIO.ByteArrayOutputStream;
var ByteArrayInputStream = __dxJavaIO.ByteArrayInputStream;
var MessageDigest = __dxJavaSecurity.MessageDigest;
var Cipher = __dxJavaxCrypto.Cipher;
var SecretKeySpec = __dxJavaxCrypto.spec.SecretKeySpec;
var IvParameterSpec = __dxJavaxCrypto.spec.IvParameterSpec;
var System = __dxJavaLang.System;
var Jsoup = __dxJsoup.Jsoup;

// ---------------------------------------------------------------------------
// CryptoJS 兼容层（97 处引用）。
// 计算全部落到 __dx.*（CommonCrypto），JS 只负责 WordArray 与字节数组互转。
// ---------------------------------------------------------------------------
function __dxWordArray(bytes) {
  var words = {};
  var uint8 = __dxUnsigned(bytes);

  function pack() {
    for (var i = 0; i < uint8.length; i++) { words[i >>> 2] = (words[i >>> 2] | 0) | ((uint8[i] & 255) << (24 - (i % 4) * 8)); }
  }

  pack();

  var wa = {
    __bytes: uint8,
    sigBytes: uint8.length,
    words: (function () { var out = []; for (var i = 0; i < uint8.length; i++) { out.push(uint8[i] & 255); } return out; })(),
    toString: function (encoder) {
      // CryptoJS 的默认编码是 Hex，不是 Utf8：
      //     CryptoJS.MD5(b).toString()  -> 32 位十六进制
      // 书源普遍这样用（MD5 签名、token 计算）。默认走 Utf8 会得到乱码。
      if (encoder === CryptoJS.enc.Utf8) { return __dx.s8(uint8); }
      if (encoder === CryptoJS.enc.Latin1) {
        var s = '';
        for (var i = 0; i < uint8.length; i++) { s += String.fromCharCode(uint8[i]); }
        return s;
      }
      if (encoder === CryptoJS.enc.Base64) { return __dx.b64e(uint8); }
      return __dx.hexe(uint8);
    },
    concat: function (other) {
      var a = uint8.slice();
      var b = other && other.__bytes ? other.__bytes : (other || []);
      for (var i = 0; i < b.length; i++) { a.push(b[i] & 255); }
      return __dxWordArray(a);
    },
    clamp: function () { return wa; },
    clone: function () { return __dxWordArray(uint8.slice()); }
  };
  // words 必须反映__bytes；保存为属性后在修改时同步
  Object.defineProperty(wa, 'words', {
    get: function () {
      var out = [];
      for (var i = 0; i < uint8.length; i++) { out.push(uint8[i] & 255); }
      return out;
    },
    set: function (v) {
      uint8 = [];
      for (var i = 0; i < v.length; i++) {
        var w = v[i] | 0;
        uint8.push((w >>> 24) & 255, (w >>> 16) & 255, (w >>> 8) & 255, w & 255);
      }
      wa.sigBytes = uint8.length;
      wa.__bytes = uint8;
    },
    configurable: true
  });
  return wa;
}

function __dxToBytes(v) {
  if (v === undefined || v === null) { return []; }
  if (typeof v === 'string') { return __dx.u8(v); }
  if (v.__bytes) { return v.__bytes.slice(); }
  if (typeof v.length === 'number') { return __dxUnsigned(v); }
  return __dx.u8(String(v));
}

var CryptoJS = {
  enc: {
    Utf8: {
      stringify: function (wa) { return __dx.s8(__dxToBytes(wa)); },
      parse: function (s) { return __dxWordArray(__dx.u8(String(s))); }
    },
    Latin1: {
      stringify: function (wa) {
        var b = __dxToBytes(wa); var s = '';
        for (var i = 0; i < b.length; i++) { s += String.fromCharCode(b[i] & 255); }
        return s;
      },
      parse: function (s) {
        var out = [];
        for (var i = 0; i < String(s).length; i++) { out.push(String(s).charCodeAt(i) & 255); }
        return __dxWordArray(out);
      }
    },
    Hex: {
      stringify: function (wa) { return __dx.hexe(__dxToBytes(wa)); },
      parse: function (s) { return __dxWordArray(__dx.hexd(String(s))); }
    },
    Base64: {
      stringify: function (wa) { return __dx.b64e(__dxToBytes(wa)); },
      parse: function (s) { return __dxWordArray(__dx.b64d(String(s))); }
    }
  },
  MD5: function (data) { return __dxWordArray(__dx.digest('MD5', __dxToBytes(data))); },
  SHA1: function (data) { return __dxWordArray(__dx.digest('SHA1', __dxToBytes(data))); },
  SHA256: function (data) { return __dxWordArray(__dx.digest('SHA256', __dxToBytes(data))); },
  SHA512: function (data) { return __dxWordArray(__dx.digest('SHA512', __dxToBytes(data))); },
  HmacMD5: function (data, key) { return __dxWordArray(__dx.hmac('MD5', __dxToBytes(data), __dxToBytes(key))); },
  HmacSHA1: function (data, key) { return __dxWordArray(__dx.hmac('SHA1', __dxToBytes(data), __dxToBytes(key))); },
  HmacSHA256: function (data, key) { return __dxWordArray(__dx.hmac('SHA256', __dxToBytes(data), __dxToBytes(key))); },
  HmacSHA512: function (data, key) { return __dxWordArray(__dx.hmac('SHA512', __dxToBytes(data), __dxToBytes(key))); },
  pad: {
    Pkcs7: { pad: function () {}, unpad: function () {} },
    Pkcs5: { pad: function () {}, unpad: function () {} },
    ZeroPadding: { pad: function () {}, unpad: function () {} },
    NoPadding: { pad: function () {}, unpad: function () {} },
    AnsiX923: { pad: function () {}, unpad: function () {} },
    Iso10126: { pad: function () {}, unpad: function () {} }
  },
  mode: {
    CBC: function () { return {}; },
    ECB: function () { return {}; },
    CFB: function () { return {}; },
    OFB: function () { return {}; },
    CTR: function () { return {}; }
  },
  algo: {},
  lib: { Cipher: {}, BlockCipherMode: {}, WordArray: { create: function (b) { return __dxWordArray(__dxToBytes(b)); } } }
};

function __dxCryptoJSDecrypt(data, key, cfg) {
  var transformation = (cfg && cfg.mode === CryptoJS.mode.ECB) ? 'AES/ECB/PKCS5Padding' : 'AES/CBC/PKCS5Padding';
  var iv = (cfg && cfg.iv) ? __dxToBytes(cfg.iv) : [];
  return __dxWordArray(__dx.cipher(false, transformation, __dxToBytes(key), __dxToBytes(data), iv));
}

function __dxCryptoJSEncrypt(data, key, cfg) {
  var transformation = (cfg && cfg.mode === CryptoJS.mode.ECB) ? 'AES/ECB/PKCS5Padding' : 'AES/CBC/PKCS5Padding';
  var iv = (cfg && cfg.iv) ? __dxToBytes(cfg.iv) : [];
  return __dxWordArray(__dx.cipher(true, transformation, __dxToBytes(key), __dxToBytes(data), iv));
}

CryptoJS.AES = { decrypt: __dxCryptoJSDecrypt, encrypt: __dxCryptoJSEncrypt };
CryptoJS.DES = { decrypt: __dxCryptoJSDecrypt, encrypt: __dxCryptoJSEncrypt };
CryptoJS.TripleDES = { decrypt: __dxCryptoJSDecrypt, encrypt: __dxCryptoJSEncrypt };
CryptoJS.RC4 = { decrypt: __dxCryptoJSDecrypt, encrypt: __dxCryptoJSEncrypt };
CryptoJS.Rabbit = { decrypt: __dxCryptoJSDecrypt, encrypt: __dxCryptoJSEncrypt };


// ---------------------------------------------------------------------------
// $ —— 书源里的规则求值简写（2888 处）。
//
// 在这些脚本的语境里 $('[property$=image]@content') 不是 DOM 查询，
// 而是「把这条规则在当前文档上求值」，等价于 java.getString(rule)。
// 因此这里直接转发到 java.getString，而不是去操作 DOM。
// ---------------------------------------------------------------------------
function __dxDollar(rule) {
  if (typeof rule === 'string') {
    var value = java.getString(rule);
    return value === undefined || value === null ? '' : String(value);
  }
  return '';
}

__dxDollar.ajax = function (options) {
  try {
    if (options && typeof options === 'object') {
      var url = options.url ? String(options.url) : '';
      if (!url) { return ''; }
      var body = java.ajax(url);
      // 同步语义：直接调用成功/失败回调，让脚本的 success/complete 逻辑能跑。
      if (typeof options.success === 'function') { options.success(body, 'success', null); }
      if (typeof options.complete === 'function') { options.complete(null, 'success', body); }
      if (typeof options.dataFilter === 'function') { return options.dataFilter(body); }
      return body;
    }
    if (typeof options === 'string') { return java.ajax(options); }
  } catch (e) {
    java.log('$.ajax 失败: ' + e);
  }
  return '';
};

__dxDollar.get = function (url, data, success) {
  var text = java.ajax(String(url));
  if (typeof data === 'function') { data(text); }
  else if (typeof success === 'function') { success(text); }
  return text;
};

__dxDollar.post = function (url, data, success) {
  var text = java.ajax(String(url));
  if (typeof data === 'function') { data(text); }
  else if (typeof success === 'function') { success(text); }
  return text;
};

__dxDollar.getJSON = function (url, success) {
  var text = java.ajax(String(url));
  var parsed = null;
  try { parsed = JSON.parse(String(text)); } catch (e) { parsed = null; }
  if (typeof success === 'function') { success(parsed); }
  return parsed;
};

__dxDollar.each = function (list, fn) {
  if (!list) { return list; }
  if (typeof list.length === 'number') {
    for (var i = 0; i < list.length; i++) { fn(i, list[i]); }
  } else {
    for (var k in list) { fn(k, list[k]); }
  }
  return list;
};

__dxDollar.extend = function () {
  var target = arguments[0] || {};
  for (var i = 1; i < arguments.length; i++) {
    var src = arguments[i];
    if (!src) { continue; }
    for (var k in src) { target[k] = src[k]; }
  }
  return target;
};

__dxDollar.map = function (list, fn) {
  var out = [];
  if (!list) { return out; }
  for (var i = 0; i < list.length; i++) { out.push(fn(list[i], i)); }
  return out;
};

__dxDollar.grep = function (list, fn) {
  var out = [];
  if (!list) { return out; }
  for (var i = 0; i < list.length; i++) { if (fn(list[i], i)) { out.push(list[i]); } }
  return out;
};

__dxDollar.trim = function (s) { return String(s === undefined || s === null ? '' : s).trim(); };
__dxDollar.isArray = function (v) { return Array.isArray(v); };
__dxDollar.isEmptyObject = function (v) { return !v || Object.keys(v).length === 0; };
__dxDollar.parseHTML = function (html) { return __dxJsoupDocument(html); };

// ---------------------------------------------------------------------------
// 把「Swift 侧桥过来的普通对象」包成 java.util.Map。
//
// 书源对 source.getLoginInfoMap() / getVariable() 这类返回值的用法是 Java 的：
//     var info = source.getLoginInfoMap();
//     var uid = info.get('账号');          // ← Map 语义
//     var pwd = info.get('密码');
// 而 Swift 的 [String: String] 桥到 JS 就是普通对象，只有 info['账号'] 可用，
// info.get 是 undefined。实测日志里刷屏的
//     TypeError: info.get is not a function
// 就是这个原因 —— 登录脚本整段失效（微信读书、书旗等源都依赖它）。
//
// 包出来的 Map 同时保留下标访问，两种写法都能用。
// ---------------------------------------------------------------------------
function __dxWrapMap(value) {
  // 用 api 对象**自身**当存储：下标访问与 .get() / .put() 读写的是同一份数据。
  // 若另开一个内部对象做存储，`info['账号'] = 'x'` 之后 `info.get('账号')`
  // 读到的还是旧值，书源里两种写法混用时会拿到错的数据。
  var api = {
    toString: function () {
      var out = {};
      for (var k in api) {
        if (typeof api[k] !== 'function') { out[k] = api[k]; }
      }
      try { return JSON.stringify(out); } catch (e) { return '{}'; }
    },
    put: function (k, v) { api[String(k)] = v; return v; },
    get: function (k) {
      var key = String(k);
      return Object.prototype.hasOwnProperty.call(api, key) ? api[key] : null;
    },
    getOrDefault: function (k, d) {
      var key = String(k);
      return Object.prototype.hasOwnProperty.call(api, key) ? api[key] : d;
    },
    containsKey: function (k) { return Object.prototype.hasOwnProperty.call(api, String(k)); },
    containsValue: function (v) {
      for (var k in api) { if (typeof api[k] !== 'function' && api[k] === v) { return true; } }
      return false;
    },
    remove: function (k) {
      var key = String(k);
      var v = api[key];
      delete api[key];
      return v === undefined ? null : v;
    },
    size: function () { return api.keySet().length; },
    isEmpty: function () { return api.keySet().length === 0; },
    clear: function () {
      var keys = api.keySet();
      for (var i = 0; i < keys.length; i++) { delete api[keys[i]]; }
    },
    keySet: function () {
      var out = [];
      for (var k in api) { if (typeof api[k] !== 'function') { out.push(k); } }
      return out;
    },
    values: function () {
      var out = [];
      for (var k in api) { if (typeof api[k] !== 'function') { out.push(api[k]); } }
      return out;
    },
    putAll: function (other) {
      if (other) { for (var k in other) { if (typeof other[k] !== 'function') { api[k] = other[k]; } } }
    },
    forEach: function (fn) {
      var keys = api.keySet();
      for (var i = 0; i < keys.length; i++) { fn(api[keys[i]], keys[i]); }
    }
  };
  if (value && typeof value === 'object') {
    for (var k in value) {
      if (Object.prototype.hasOwnProperty.call(value, k)) { api[k] = value[k]; }
    }
  }
  return api;
}

var $ = __dxDollar;

// 少数源用 jQuery 风格但整体挂在大写命名空间下
var jQuery = __dxDollar;
var Zepto = __dxDollar;

// ---------------------------------------------------------------------------
// 收尾：Rhino 里 ___ 之类不存在的标识符不应把整个脚本打断。
// 统一提供一个「取值为 undefined 也不报错」的 getter 兜底并不现实，
// 但书源真实依赖的全局量（result / src / baseUrl / book / chapter / key / page）
// 全部由 Swift 侧注入，这里不再重复定义，避免遮蔽宿主注入的值。
// ---------------------------------------------------------------------------

// console 兜底（宿主已在 setup 里定义，这里保证存在）
if (typeof console === 'undefined') {
  var console = { log: function () { java.log(Array.prototype.join.call(arguments, ' ')); } };
}
console.error = console.error || console.log;
console.warn = console.warn || console.log;
console.info = console.info || console.log;
console.debug = console.debug || console.log;

"""#

    /// 注入到指定上下文。
    ///
    /// 求值失败只记日志，不让引擎初始化失败：
    /// 兼容层缺失时书源会走自己的 try/catch，比整个上下文不可用要好。
    static func install(into context: JSContext) {
        _ = context.evaluateScript(source)
        if let exception = context.exception {
            Log.debugLog("JS", "运行时兼容层注入异常: " + (exception.toString() ?? ""))
            context.exception = nil
        }
    }
}
