// The style-report parity case through the Kotlin binding (style-report-parity.sh, on demand only).
// Usage: StyleReportKt <case dir>. Prints the binding's `readingStyle` of the case as JSON, in the core's serde shape.

import java.io.File
import uniffi.xdict.*

fun q(s: String): String = buildString {
    append('"')
    for (ch in s) when {
        ch == '"' -> append("\\\"")
        ch == '\\' -> append("\\\\")
        ch < ' ' -> append(String.format("\\u%04x", ch.code))
        else -> append(ch)
    }
    append('"')
}

fun obj(vararg fields: Pair<String, String>) = fields.joinToString(",", "{", "}") { (k, v) -> q(k) + ":" + v }

fun reason(r: FontReason) = when (r) {
    FontReason.PRIVATE_USE -> "privateUse"
    FontReason.PSEUDO_CONTENT -> "pseudoContent"
    FontReason.PHONETIC -> "phonetic"
}

fun skipped(r: SkipReason) = when (r) {
    is SkipReason.TooMany -> obj("tooMany" to obj("limit" to r.limit.toString()))
    is SkipReason.TooLarge -> obj("tooLarge" to obj("limit" to r.limit.toString(), "detail" to q(r.detail)))
    is SkipReason.NotFound -> q("notFound")
    is SkipReason.Unreadable -> obj("unreadable" to obj("detail" to q(r.detail)))
}

fun main(args: Array<String>) {
    val dir = File(args[0])
    fun at(name: String) = Location.Path(File(dir, name).path)
    val core = Core(Config(null, null, protocolVersion(), ByteArray(0)))
    val pkg = Package(at("case.mdx"), listOf(at("case.mdd")), listOf(at("case.css")))
    core.import(pkg, null)
    val dict = (core.open(pkg) as Opened.Ready).dict
    val s = core.readingStyle(dict)
    val baseFrom = when (val b = s.baseFrom) {
        is BaseSource.Page -> obj("page" to obj("selector" to q(b.selector)))
        is BaseSource.Prose -> obj("prose" to obj("weight" to b.weight.toString()))
        is BaseSource.Text -> obj("text" to obj("chars" to b.chars.toString(), "share" to b.share.toString()))
        is BaseSource.BrowserDefault -> q("browserDefault")
    }
    val c = s.changes
    val fonts = s.fonts.joinToString(",", "[", "]") {
        obj("family" to q(it.family), "reason" to q(reason(it.reason)), "selector" to q(it.selector))
    }
    val list = { l: List<String> -> l.joinToString(",", "[", "]") { q(it) } }
    println(obj(
        "version" to s.version.toString(), "basePx" to s.basePx.toString(), "baseFrom" to baseFrom, "fonts" to fonts,
        "sheets" to list(s.sheets), "skipped" to s.skipped.joinToString(",", "[", "]") {
            obj("path" to q(it.path), "reason" to skipped(it.reason))
        },
        "changes" to obj(
            "important" to c.important.toString(), "page" to c.page.toString(), "family" to c.family.toString(),
            "size" to c.size.toString(), "lineHeight" to c.lineHeight.toString(), "colour" to c.colour.toString(),
            "weight" to c.weight.toString(), "space" to c.space.toString(), "dropped" to c.dropped.toString(),
        ),
    ))
}
