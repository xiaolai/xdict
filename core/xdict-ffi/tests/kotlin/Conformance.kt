// The conformance scenario (conformance/README.md) through the UniFFI Kotlin binding, on the JVM.
// Usage: Conformance <fixture dir written by conformance-fixtures> <expected.json>
// Exits 1 with every mismatch printed, 0 when all agree.

import java.io.File
import kotlin.system.exitProcess
import uniffi.xdict.*

// A JSON reader, small enough to read here: the JDK has none, and a test needs no dependency for one.
class Json(private val s: String) {
    private var i = 0
    fun parse(): Any? { val v = value(); ws(); require(i == s.length) { "trailing text at $i" }; return v }
    private fun ws() { while (i < s.length && s[i].isWhitespace()) i++ }
    private fun value(): Any? {
        ws()
        return when (s[i]) {
            '{' -> { i++; val m = LinkedHashMap<String, Any?>(); ws()
                if (s[i] == '}') { i++; return m }
                while (true) { ws(); val k = string(); ws(); require(s[i++] == ':'); m[k] = value(); ws()
                    if (s[i++] == '}') return m } ; @Suppress("UNREACHABLE_CODE") m }
            '[' -> { i++; val l = ArrayList<Any?>(); ws()
                if (s[i] == ']') { i++; return l }
                while (true) { l.add(value()); ws(); if (s[i++] == ']') return l } ; @Suppress("UNREACHABLE_CODE") l }
            '"' -> string()
            't' -> { i += 4; true }
            'f' -> { i += 5; false }
            'n' -> { i += 4; null }
            else -> { val start = i; while (i < s.length && (s[i].isDigit() || s[i] in "+-.eE")) i++
                s.substring(start, i).toBigDecimal() }
        }
    }
    private fun string(): String {
        require(s[i++] == '"'); val b = StringBuilder()
        while (s[i] != '"') {
            val c = s[i++]
            if (c != '\\') { b.append(c); continue }
            when (val e = s[i++]) {
                'n' -> b.append('\n'); 't' -> b.append('\t'); 'r' -> b.append('\r'); 'b' -> b.append('\b')
                'f' -> b.append('\u000c'); 'u' -> { b.append(s.substring(i, i + 4).toInt(16).toChar()); i += 4 }
                else -> b.append(e)
            }
        }
        i++; return b.toString()
    }
}

// Results as the suites compare them: the serde shape of xdict-core's types.
fun camel(name: String): String = name.lowercase().split('_').mapIndexed { n, p -> if (n == 0) p else p.replaceFirstChar { it.uppercase() } }.joinToString("")
fun j(v: Versions) = mapOf("protocol" to v.protocol, "core" to v.core, "indexFormat" to v.indexFormat, "normalization" to v.normalization)
fun j(i: DictInfo) = mapOf("title" to i.title, "description" to i.description, "formatVersion" to i.formatVersion, "keys" to i.keys)
fun j(e: EntryRef) = mapOf("edition" to e.edition, "key" to e.key, "occurrence" to e.occurrence)
fun j(p: Problem): Map<String, Any?> = when (p) { is Problem.VolumeUnreadable -> mapOf("type" to "volumeUnreadable", "name" to p.name, "error" to j(p.error)) }
fun j(i: Imported) = mapOf("edition" to i.edition, "lineage" to i.lineage, "info" to j(i.info), "problems" to i.problems.map { j(it) })
fun j(o: Opened): Map<String, Any?> = when (o) {
    is Opened.Ready -> mapOf("type" to "ready", "dict" to o.dict, "edition" to o.edition, "info" to j(o.info))
    is Opened.NeedsImport -> mapOf("type" to "needsImport", "reason" to camel(o.reason.name))
}
fun j(h: How): Map<String, Any?> = when (h) {
    is How.Exact -> mapOf("type" to "exact"); is How.Folded -> mapOf("type" to "folded")
    is How.Unmarked -> mapOf("type" to "unmarked"); is How.Redirect -> mapOf("type" to "redirect", "chain" to h.chain)
}
fun j(p: HitProblem): Map<String, Any?> = when (p) {
    is HitProblem.DanglingRedirect -> mapOf("type" to "danglingRedirect", "from" to p.from, "target" to p.target)
    is HitProblem.RedirectLoop -> mapOf("type" to "redirectLoop", "chain" to p.chain)
    is HitProblem.RedirectLimit -> mapOf("type" to "redirectLimit", "chain" to p.chain)
}
fun j(h: Hit) = mapOf("dict" to h.dict, "entry" to j(h.entry), "headword" to h.headword, "how" to j(h.how), "problems" to h.problems.map { j(it) })
fun j(p: Page) = mapOf("hits" to p.hits.map { j(it) }, "total" to p.total, "generation" to p.generation, "problems" to p.problems.map { j(it) })
fun j(e: Entry) = mapOf("entry" to j(e.entry), "html" to e.html, "csp" to e.csp, "lossyBytes" to e.lossyBytes)
fun j(b: BlockReason): Map<String, Any?> = when (b) {
    is BlockReason.Remote -> mapOf("type" to "remote", "url" to b.url); is BlockReason.Script -> mapOf("type" to "script")
    is BlockReason.UnknownScheme -> mapOf("type" to "unknownScheme", "scheme" to b.scheme)
}
fun j(l: Link): Map<String, Any?> = when (l) {
    is Link.Lookup -> mapOf("type" to "lookup", "query" to l.query, "anchor" to l.anchor)
    is Link.Resource -> mapOf("type" to "resource", "path" to l.path)
    is Link.Sound -> mapOf("type" to "sound", "path" to l.path)
    is Link.Speak -> mapOf("type" to "speak", "text" to l.text)
    is Link.Anchor -> mapOf("type" to "anchor", "name" to l.name)
    is Link.Blocked -> mapOf("type" to "blocked", "why" to j(l.why))
}
fun j(r: Resource): Map<String, Any?> = when (r) {
    is Resource.Found -> mapOf("type" to "found", "path" to r.path, "mime" to r.mime, "text" to String(r.bytes, Charsets.UTF_8))
    is Resource.Missing -> mapOf("type" to "missing", "path" to r.path)
}
fun j(k: FindingKind): String = k.name.lowercase().split('_').mapIndexed { n, w -> if (n == 0) w else w.replaceFirstChar { it.uppercase() } }.joinToString("")
fun j(f: HealthFinding) = mapOf("kind" to j(f.kind), "count" to f.count, "name" to f.name, "examples" to f.examples.map { mapOf("key" to it.key, "text" to it.text) })
fun j(h: Health) = mapOf("version" to h.version, "entries" to h.entries, "findings" to h.findings.map { j(it) }, "classes" to h.classes.map { mapOf("name" to it.name, "count" to it.count) })
fun j(f: Feature): Map<String, Any?> = when (f) {
    is Feature.FormatVersion -> mapOf("type" to "formatVersion", "version" to f.version)
    is Feature.ResourceLibraryV3 -> mapOf("type" to "resourceLibraryV3")
    is Feature.RegistrationCode -> mapOf("type" to "registrationCode")
    is Feature.EncryptionFlags -> mapOf("type" to "encryptionFlags", "flags" to f.flags)
    is Feature.LzoInV3 -> mapOf("type" to "lzoInV3")
    is Feature.CompressionType -> mapOf("type" to "compressionType", "code" to f.code)
    is Feature.BlockEncryption -> mapOf("type" to "blockEncryption", "code" to f.code)
    is Feature.Encoding -> mapOf("type" to "encoding", "name" to f.name)
}
fun j(e: CoreException): Map<String, Any?> = when (e) {
    is CoreException.Unsupported -> mapOf("type" to "unsupported", "feature" to j(e.feature), "detail" to e.detail)
    is CoreException.Malformed -> mapOf("type" to "malformed", "detail" to e.detail)
    is CoreException.TooLarge -> mapOf("type" to "tooLarge", "limit" to camel(e.limit.name), "detail" to e.detail)
    is CoreException.NotFound -> mapOf("type" to "notFound", "what" to camel(e.what.name), "detail" to e.detail)
    is CoreException.Io -> mapOf("type" to "io", "kind" to camel(e.kind.name), "detail" to e.detail)
    is CoreException.StaleHandle -> mapOf("type" to "staleHandle", "detail" to e.detail)
    is CoreException.EditionMismatch -> mapOf("type" to "editionMismatch", "detail" to e.detail)
    is CoreException.SourceChanged -> mapOf("type" to "sourceChanged", "detail" to e.detail)
    is CoreException.Cancelled -> mapOf("type" to "cancelled", "detail" to e.detail)
    is CoreException.Incompatible -> mapOf("type" to "incompatible", "core" to e.core, "client" to e.client, "detail" to e.detail)
    is CoreException.Internal -> mapOf("type" to "internal", "detail" to e.detail)
}

fun outcome(call: () -> Any?): Any? = try { call() } catch (e: CoreException) { mapOf("error" to j(e)) }

// Comparison.
fun number(v: Any?): java.math.BigDecimal? = when (v) {
    is java.math.BigDecimal -> v; is UInt -> v.toLong().toBigDecimal(); is ULong -> java.math.BigDecimal(v.toString())
    is UByte -> v.toInt().toBigDecimal(); is Int -> v.toBigDecimal(); is Long -> v.toBigDecimal(); else -> null
}
fun subset(expected: Any?, actual: Any?, at: String): String? {
    if (expected is Map<*, *>) {
        if (actual !is Map<*, *>) return "$at: expected an object, found $actual"
        for ((k, v) in expected) {
            if (k == "comment") continue
            if (!actual.containsKey(k)) return "$at.$k: missing in $actual"
            subset(v, actual[k], "$at.$k")?.let { return it }
        }
        return null
    }
    if (expected is List<*>) {
        if (actual !is List<*> || actual.size != expected.size) return "$at: expected $expected, found $actual"
        expected.zip(actual).forEachIndexed { n, (e, a) -> subset(e, a, "$at[$n]")?.let { return it } }
        return null
    }
    val e = number(expected); val a = number(actual)
    if (e != null && a != null) return if (e.compareTo(a) == 0) null else "$at: expected $e, found $a"
    return if (expected == actual) null else "$at: expected $expected, found $actual"
}

// A source the shell implements.
class Bytes(val bytes: ByteArray, val ident: FileIdentity?, val short: Boolean = false) : ByteSource {
    override fun size(): ULong = bytes.size.toULong()
    override fun readAt(offset: ULong, len: UInt): ByteArray {
        val start = offset.toInt(); val end = minOf(start + len.toInt(), bytes.size) - (if (short) 1 else 0)
        return bytes.copyOfRange(start, end)
    }
    override fun identity(): FileIdentity? = ident
}

@Suppress("UNCHECKED_CAST")
/** A progress that cancels at once. */
class Stop : Progress {
    override fun progress(done: ULong, total: ULong): Boolean = false
}

/** A sidecar whose identity the suite changes after it is opened, as a moved or rewritten file's would. */
class Moving(val bytes: ByteArray, @Volatile var ident: FileIdentity) : ByteSource {
    override fun size(): ULong = bytes.size.toULong()
    override fun readAt(offset: ULong, len: UInt): ByteArray =
        bytes.copyOfRange(offset.toInt(), minOf(offset.toInt() + len.toInt(), bytes.size))
    override fun identity(): FileIdentity? = ident
}

fun main(args: Array<String>) {
    if (args.size != 4) { println("usage: Conformance <tiny dir> <tiny expected.json> <matrix dir> <matrix expected.json>"); exitProcess(2) }
    val dir = File(args[0])
    val x = Json(File(args[1]).readText()).parse() as Map<String, Any?>
    val failures = ArrayList<String>()
    fun check(name: String, expected: Any?, actual: Any?) { subset(expected, actual, name)?.let { failures.add(it) } }
    fun at(name: String) = Location.Path(File(dir, name).path)
    fun obj(v: Any?) = v as Map<String, Any?>
    fun list(v: Any?) = (v as List<Any?>).map { obj(it) }
    fun uint(v: Any?) = (v as java.math.BigDecimal?)?.toInt()?.toUInt()
    val viewSpec = obj(x["view"])
    fun view(max: ULong? = null) = View(viewSpec["baseUrl"] as String, max ?: (viewSpec["maxBodyBytes"] as java.math.BigDecimal).toLong().toULong())
    fun config(client: UInt) = Config(null, null, client, ByteArray(0))
    fun errorOr(c: Map<String, Any?>, key: String) = if (c.containsKey("error")) mapOf("error" to c["error"]) else c[key]

    check("versions", x["versions"], j(versions()))
    val wrong = obj(x["newWrongProtocol"])
    check("newWrongProtocol", wrong["error"], (outcome { Core(config(uint(wrong["client"])!!)); "made" } as? Map<*, *>)?.get("error") ?: "made")

    val core = Core(config(protocolVersion()))
    val pkg = Package(at("tiny.mdx"), listOf(at("tiny.mdd")), listOf(at("tiny.css")))
    check("openBeforeImport", x["openBeforeImport"], outcome { j(core.open(pkg)) })
    val imported = core.`import`(pkg, null)
    check("import", x["import"], j(imported))
    val opened = core.open(pkg)
    check("open", x["open"], j(opened))
    val dict = (opened as Opened.Ready).dict

    // The generation each lookup returned, for the cases that continue it (`{ "of": n }`).
    val generations = mutableListOf<UInt?>()
    list(x["lookups"]).forEachIndexed { n, c ->
        val generation = (c["generation"] as Map<*, *>?)?.let { generations[uint(it["of"])!!.toInt()]!! }
        val options = LookupOptions(
            uint(c["limit"])!!, uint(c["offset"])!!,
            if (c["mode"] == "link") MatchMode.LINK else MatchMode.READER, generation)
        val got = outcome { j(core.lookup(c["query"] as String, listOf(dict), options)) }
        generations.add((got as? Map<*, *>)?.get("generation") as UInt?)
        check("lookups[$n]", errorOr(c, "page"), got)
    }
    list(x["suggestions"]).forEachIndexed { n, c ->
        check("suggestions[$n]", errorOr(c, "keys"), outcome { core.suggest(c["prefix"] as String, listOf(dict), uint(c["limit"])!!) })
    }
    list(x["entries"]).forEachIndexed { n, c ->
        val e = obj(c["entry"])
        val ref = EntryRef((c["edition"] as String?) ?: imported.edition, e["key"] as String, uint(e["occurrence"])!!)
        val max = (c["maxBodyBytes"] as java.math.BigDecimal?)?.toLong()?.toULong()
        val got = outcome { j(core.entry(dict, ref, view(max))) }
        (c["cspContains"] as String?)?.let { needle ->
            if (got is Map<*, *> && got.containsKey("csp")) check("entries[$n].csp contains $needle", true, (got["csp"] as String).contains(needle))
        }
        check("entries[$n]", errorOr(c, "result"), got)
    }
    val origin = LinkOrigin.Entry(EntryRef(imported.edition, "run", 0u))
    list(x["links"]).forEachIndexed { n, c -> check("links[$n]", c["link"], outcome { j(core.link(dict, c["url"] as String, origin, view())) }) }
    list(x["resources"]).forEachIndexed { n, c -> check("resources[$n]", c["resource"], outcome { j(core.resource(dict, c["path"] as String, view())) }) }
    check("health", x["health"], outcome { j(core.health(dict, null)) })

    val b = obj(x["byteSource"])
    val mdx = File(dir, "tiny.mdx").readBytes()
    val id = obj(b["identity"])
    fun num(k: String) = (id[k] as java.math.BigDecimal).toLong()
    val ident = FileIdentity(num("device").toULong(), num("inode").toULong(), num("size").toULong(), num("mtimeNs"), num("ctimeNs"))
    val copy = Location.Source(b["name"] as String, Bytes(mdx, ident))
    val sidecarSpec = obj(b["sidecar"])
    val sidecar = Location.Source(sidecarSpec["name"] as String, Bytes((sidecarSpec["text"] as String).toByteArray(), null))
    val copyPkg = Package(copy, listOf(), listOf(sidecar))
    check("byteSource.import", b["import"], outcome { j(core.`import`(copyPkg, null)) })
    val second = core.open(copyPkg)
    check("byteSource.open", b["open"], j(second))
    val secondDict = (second as Opened.Ready).dict
    check("byteSource.resourceFromPath", b["resourceFromPath"], outcome { j(core.resource(dict, "tiny.css", view())) })
    check("byteSource.resourceFromSource", b["resourceFromSource"], outcome { j(core.resource(secondDict, "tiny.css", view())) })
    val short = Package(Location.Source("short.mdx", Bytes(mdx, null, true)), listOf(), listOf())
    check("byteSource.shortRead", b["shortRead"], outcome { j(core.`import`(short, null)) })

    val errs = obj(x["errors"])
    for (name in listOf("unsupported", "malformed", "notFound")) {
        val c = obj(errs[name])
        val faulty = Package(at(c["file"] as String), listOf(), listOf())
        check("errors.$name", mapOf("error" to c["error"]), outcome { j(core.`import`(faulty, null)) })
    }
    val alone = Package(at("tiny.mdx"), listOf(), listOf())
    check("errors.cancelled", mapOf("error" to obj(errs["cancelled"])["error"]), outcome { j(core.`import`(alone, Stop())) })
    val moving = Moving((sidecarSpec["text"] as String).toByteArray(), ident)
    val watchedPkg = Package(Location.Source(b["name"] as String, Bytes(mdx, ident)), listOf(), listOf(Location.Source("tiny.css", moving)))
    core.`import`(watchedPkg, null)
    val watched = (core.open(watchedPkg) as Opened.Ready).dict
    moving.ident = ident.copy(inode = ident.inode + 1u)
    check("errors.sourceChanged", mapOf("error" to obj(errs["sourceChanged"])["error"]), outcome { j(core.resource(watched, "tiny.css", view())) })

    // The reader's joins and splits; each lineage answered is compared as a label, since ids are minted at random.
    val n = obj(x["lineages"])
    val rebuilt = core.`import`(Package(at(n["file"] as String), listOf(), listOf()), null)
    fun label(v: Any?): Any? = when (v) {
        imported.lineage -> "tiny"
        rebuilt.lineage -> "rebuilt"
        else -> v
    }
    check("lineages.import", n["import"], j(rebuilt) + ("lineage" to label(rebuilt.lineage)))
    fun lineageOf(e: String) = label(outcome { core.lineageOf(e) })
    fun join(e: String, l: String) = label(outcome { core.joinLineage(e, l) })
    fun split(e: String, l: String) = label(outcome { core.splitLineage(e, l) })
    check("lineages.before", n["before"], lineageOf(rebuilt.edition))
    check("lineages.join", n["join"], join(rebuilt.edition, imported.lineage))
    check("lineages.afterJoin", n["afterJoin"], lineageOf(rebuilt.edition))
    check("lineages.joinAgain", n["joinAgain"], join(rebuilt.edition, imported.lineage))
    check("lineages.split", n["split"], split(rebuilt.edition, rebuilt.lineage))
    check("lineages.afterSplit", n["afterSplit"], lineageOf(rebuilt.edition))
    check("lineages.splitToNew", n["splitToNew"], split(rebuilt.edition, n["newLineage"] as String))
    check("lineages.splitToNewAgain", n["splitToNewAgain"], split(rebuilt.edition, n["newLineage"] as String))
    check("lineages.joinUnknownEdition", n["joinUnknownEdition"], join(n["unknownEdition"] as String, imported.lineage))
    check("lineages.lineageOfUnknownEdition", n["lineageOfUnknownEdition"], lineageOf(n["unknownEdition"] as String))
    check("lineages.joinUnknownLineage", n["joinUnknownLineage"], join(rebuilt.edition, n["unknownLineage"] as String))
    check("lineages.splitNotALineage", n["splitNotALineage"], split(rebuilt.edition, n["notALineage"] as String))
    check("lineages.splitIntoAnother", n["splitIntoAnother"], split(imported.edition, rebuilt.lineage))

    val l = obj(x["lifecycle"])
    val page = LookupOptions(10u, 0u, MatchMode.READER, null)
    core.close(secondDict)
    check("lifecycle.afterClose", l["afterClose"], outcome { j(core.lookup("run", listOf(secondDict), page)) })
    check("lifecycle.closeTwice", l["closeTwice"], outcome { core.close(secondDict); "ok" })
    val other = Core(config(protocolVersion()))
    check("lifecycle.foreignHandle", l["foreignHandle"], outcome { j(other.lookup("run", listOf(dict), page)) })
    check("lifecycle.panic", l["panic"], outcome { core.selfTestPanic(); "returned" })

    // The matrix: every variant imported, opened and asked the same questions.
    val matrixDir = File(args[2])
    val template = File(args[3]).readText()
    val variants = list(Json(File(matrixDir, "variants.json").readText()).parse())
    check("matrix.variants", java.math.BigDecimal(32), java.math.BigDecimal(variants.size))
    val matrixView = View("xdict://d/", (1uL shl 20))
    for (v in variants) {
        val name = v["name"] as String
        val text = template.replace("\$word", v["word"] as String).replace("\$gloss", v["gloss"] as String)
            .replace("\$version", v["version"] as String)
        val m = Json(text).parse() as Map<String, Any?>
        val c0 = Core(config(protocolVersion()))
        val p = Package(Location.Path(File(matrixDir, "$name.mdx").path), listOf(), listOf())
        val imp = outcome { j(c0.`import`(p, null)) }
        check("$name.import", m["import"], imp)
        val edition = (imp as? Map<*, *>)?.get("edition") as String? ?: continue
        val opn = outcome { j(c0.open(p)) }
        check("$name.open", m["open"], opn)
        val d = (opn as? Map<*, *>)?.get("dict") as String? ?: continue
        list(m["lookups"]).forEachIndexed { n, c ->
            val options = LookupOptions(uint(c["limit"])!!, uint(c["offset"])!!, MatchMode.READER, null)
            check("$name.lookups[$n]", c["page"], outcome { j(c0.lookup(c["query"] as String, listOf(d), options)) })
        }
        list(m["entries"]).forEachIndexed { n, c ->
            val e = obj(c["entry"])
            val ref = EntryRef(edition, e["key"] as String, uint(e["occurrence"])!!)
            check("$name.entries[$n]", c["result"], outcome { j(c0.entry(d, ref, matrixView)) })
        }
    }

    if (failures.isEmpty()) { println("kotlin conformance: all agree"); return }
    println("kotlin conformance: ${failures.size} failures")
    failures.forEach { println("  $it") }
    exitProcess(1)
}
