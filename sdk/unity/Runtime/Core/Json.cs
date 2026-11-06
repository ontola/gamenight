using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace GameNightSdk
{
    /// <summary>
    /// A small JSON reader and writer for the GameNight protocol. Objects become
    /// <c>Dictionary&lt;string, object&gt;</c>, arrays <c>List&lt;object&gt;</c>, whole
    /// numbers <c>long</c>, other numbers <c>double</c>. Unity's JsonUtility cannot
    /// read dictionaries or unknown fields, and the protocol needs both.
    /// </summary>
    public static class Json
    {
        public static object Parse(string text)
        {
            if (text == null) return null;
            var reader = new Reader(text);
            reader.SkipSpace();
            var value = reader.Value(0);
            reader.SkipSpace();
            if (!reader.AtEnd) throw new FormatException("JSON: trailing characters");
            return value;
        }

        /// <summary>Parse, or null when the text is not valid JSON.</summary>
        public static object TryParse(string text)
        {
            try { return Parse(text); }
            catch (FormatException) { return null; }
        }

        public static string Write(object value)
        {
            var sb = new StringBuilder(128);
            WriteValue(sb, value);
            return sb.ToString();
        }

        // ---- reading helpers -------------------------------------------------

        public static Dictionary<string, object> Obj(object value) => value as Dictionary<string, object>;
        public static List<object> List(object value) => value as List<object> ?? new List<object>();

        public static object Get(Dictionary<string, object> obj, string key)
        {
            if (obj == null) return null;
            return obj.TryGetValue(key, out var value) ? value : null;
        }

        public static string Str(Dictionary<string, object> obj, string key, string fallback = "")
        {
            var value = Get(obj, key);
            if (value == null) return fallback;
            if (value is string s) return s;
            return Convert.ToString(value, CultureInfo.InvariantCulture);
        }

        public static long Long(Dictionary<string, object> obj, string key, long fallback = 0) => ToLong(Get(obj, key), fallback);
        public static int Int(Dictionary<string, object> obj, string key, int fallback = 0) => (int)ToLong(Get(obj, key), fallback);

        public static bool Bool(Dictionary<string, object> obj, string key, bool fallback = false)
        {
            var value = Get(obj, key);
            return value is bool b ? b : fallback;
        }

        public static long ToLong(object value, long fallback = 0)
        {
            switch (value)
            {
                case long l: return l;
                case int i: return i;
                case double d: return double.IsNaN(d) ? fallback : (long)Math.Round(d);
                case float f: return (long)Math.Round(f);
                case bool b: return b ? 1 : 0;
                case string s when long.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed): return parsed;
                default: return fallback;
            }
        }

        public static double ToDouble(object value, double fallback = 0)
        {
            switch (value)
            {
                case long l: return l;
                case int i: return i;
                case double d: return d;
                case float f: return f;
                default: return fallback;
            }
        }

        // ---- writer ----------------------------------------------------------

        static void WriteValue(StringBuilder sb, object value)
        {
            switch (value)
            {
                case null: sb.Append("null"); return;
                case string s: WriteString(sb, s); return;
                case bool b: sb.Append(b ? "true" : "false"); return;
                case int i: sb.Append(i.ToString(CultureInfo.InvariantCulture)); return;
                case long l: sb.Append(l.ToString(CultureInfo.InvariantCulture)); return;
                case short sh: sb.Append(sh.ToString(CultureInfo.InvariantCulture)); return;
                case uint ui: sb.Append(ui.ToString(CultureInfo.InvariantCulture)); return;
                case float f: WriteNumber(sb, f); return;
                case double d: WriteNumber(sb, d); return;
                case IDictionary<string, object> dict:
                    sb.Append('{');
                    var first = true;
                    foreach (var pair in dict)
                    {
                        if (!first) sb.Append(',');
                        first = false;
                        WriteString(sb, pair.Key);
                        sb.Append(':');
                        WriteValue(sb, pair.Value);
                    }
                    sb.Append('}');
                    return;
                case IDictionary legacy:
                    sb.Append('{');
                    var firstLegacy = true;
                    foreach (DictionaryEntry pair in legacy)
                    {
                        if (!firstLegacy) sb.Append(',');
                        firstLegacy = false;
                        WriteString(sb, Convert.ToString(pair.Key, CultureInfo.InvariantCulture));
                        sb.Append(':');
                        WriteValue(sb, pair.Value);
                    }
                    sb.Append('}');
                    return;
                case IEnumerable list:
                    sb.Append('[');
                    var firstItem = true;
                    foreach (var item in list)
                    {
                        if (!firstItem) sb.Append(',');
                        firstItem = false;
                        WriteValue(sb, item);
                    }
                    sb.Append(']');
                    return;
                default:
                    WriteString(sb, Convert.ToString(value, CultureInfo.InvariantCulture));
                    return;
            }
        }

        static void WriteNumber(StringBuilder sb, double d)
        {
            if (double.IsNaN(d) || double.IsInfinity(d)) { sb.Append("null"); return; }
            if (d == Math.Floor(d) && Math.Abs(d) < 1e15) sb.Append(((long)d).ToString(CultureInfo.InvariantCulture));
            else sb.Append(d.ToString("R", CultureInfo.InvariantCulture));
        }

        static void WriteString(StringBuilder sb, string s)
        {
            sb.Append('"');
            foreach (var c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    case '\b': sb.Append("\\b"); break;
                    case '\f': sb.Append("\\f"); break;
                    default:
                        if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
        }

        // ---- reader ----------------------------------------------------------

        sealed class Reader
        {
            const int MaxDepth = 64;
            readonly string _s;
            int _i;

            public Reader(string s) { _s = s; }
            public bool AtEnd => _i >= _s.Length;

            public void SkipSpace()
            {
                while (_i < _s.Length && (_s[_i] == ' ' || _s[_i] == '\t' || _s[_i] == '\n' || _s[_i] == '\r')) _i++;
            }

            char Peek() => _i < _s.Length ? _s[_i] : '\0';

            FormatException Fail(string what) => new FormatException($"JSON: {what} at {_i}");

            public object Value(int depth)
            {
                if (depth > MaxDepth) throw Fail("nested too deep");
                SkipSpace();
                var c = Peek();
                switch (c)
                {
                    case '{': return Object(depth);
                    case '[': return Array(depth);
                    case '"': return String();
                    case 't': Literal("true"); return true;
                    case 'f': Literal("false"); return false;
                    case 'n': Literal("null"); return null;
                    default:
                        if (c == '-' || (c >= '0' && c <= '9')) return Number();
                        throw Fail("unexpected character");
                }
            }

            void Literal(string word)
            {
                if (string.CompareOrdinal(_s, _i, word, 0, word.Length) != 0) throw Fail("bad literal");
                _i += word.Length;
            }

            Dictionary<string, object> Object(int depth)
            {
                var result = new Dictionary<string, object>();
                _i++;
                SkipSpace();
                if (Peek() == '}') { _i++; return result; }
                while (true)
                {
                    SkipSpace();
                    if (Peek() != '"') throw Fail("expected a key");
                    var key = String();
                    SkipSpace();
                    if (Peek() != ':') throw Fail("expected ':'");
                    _i++;
                    result[key] = Value(depth + 1);
                    SkipSpace();
                    var c = Peek();
                    _i++;
                    if (c == ',') continue;
                    if (c == '}') return result;
                    throw Fail("expected ',' or '}'");
                }
            }

            List<object> Array(int depth)
            {
                var result = new List<object>();
                _i++;
                SkipSpace();
                if (Peek() == ']') { _i++; return result; }
                while (true)
                {
                    result.Add(Value(depth + 1));
                    SkipSpace();
                    var c = Peek();
                    _i++;
                    if (c == ',') continue;
                    if (c == ']') return result;
                    throw Fail("expected ',' or ']'");
                }
            }

            string String()
            {
                _i++;
                var start = _i;
                StringBuilder sb = null;
                while (true)
                {
                    if (_i >= _s.Length) throw Fail("unterminated string");
                    var c = _s[_i];
                    if (c == '"')
                    {
                        string result;
                        if (sb == null) result = _s.Substring(start, _i - start);
                        else result = sb.Append(_s, start, _i - start).ToString();
                        _i++;
                        return result;
                    }
                    if (c != '\\') { _i++; continue; }
                    sb = sb ?? new StringBuilder();
                    sb.Append(_s, start, _i - start);
                    _i++;
                    if (_i >= _s.Length) throw Fail("bad escape");
                    var e = _s[_i++];
                    switch (e)
                    {
                        case '"': sb.Append('"'); break;
                        case '\\': sb.Append('\\'); break;
                        case '/': sb.Append('/'); break;
                        case 'b': sb.Append('\b'); break;
                        case 'f': sb.Append('\f'); break;
                        case 'n': sb.Append('\n'); break;
                        case 'r': sb.Append('\r'); break;
                        case 't': sb.Append('\t'); break;
                        case 'u':
                            if (_i + 4 > _s.Length) throw Fail("bad unicode escape");
                            sb.Append((char)int.Parse(_s.Substring(_i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                            _i += 4;
                            break;
                        default: throw Fail("bad escape");
                    }
                    start = _i;
                }
            }

            object Number()
            {
                var start = _i;
                var fraction = false;
                if (Peek() == '-') _i++;
                while (_i < _s.Length)
                {
                    var c = _s[_i];
                    if (c >= '0' && c <= '9') { _i++; continue; }
                    if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') { fraction = true; _i++; continue; }
                    break;
                }
                var text = _s.Substring(start, _i - start);
                if (!fraction && long.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var whole)) return whole;
                if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var number)) return number;
                throw Fail("bad number");
            }
        }
    }
}
