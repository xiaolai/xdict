import Testing
import XDictCapture

/// The capture script filter's classifier, moved from XiaolaiDict's `DictionaryLanguageTests` (the `dominant` cases;
/// the probe-word cases stayed with the dictionary side).
struct CaptureScriptTests {
    /// Captured text opens with punctuation or a digit; a first-scalar reading names no script for it. Moved by name;
    /// the `ProbeScript.of` halves stayed with the dictionary probe.
    @Test func theFirstScalarClassifierIsNotEnoughForCapturedText() {
        #expect(CaptureScript.dominant(in: "“hold”") == .latin)
        #expect(CaptureScript.dominant(in: "3D") == .latin)
    }

    /// Letters decide; everything else is ignored rather than counted as a script of its own.
    @Test func punctuationDigitsAndSpacesDoNotVote() {
        #expect(CaptureScript.dominant(in: "well-being") == .latin)
        #expect(CaptureScript.dominant(in: "第 3 章") == .han)
        #expect(CaptureScript.dominant(in: "") == nil)
        #expect(CaptureScript.dominant(in: "…—·") == nil, "nothing but punctuation names no script")
        #expect(CaptureScript.dominant(in: "42") == nil, "a number is not written in a script")
    }

    /// **Any kana makes it Japanese, whatever the count of han.** This is the same fact the probe
    /// words exist for, applied the other way round: 水 alone is Chinese, and 水 beside する is
    /// Japanese. A majority vote would call 日本語を話す han, because the kanji outnumber nothing —
    /// here they do not, but `勉強する` is 3 han to 2 kana and would come out Chinese.
    @Test func anyKanaMakesItJapaneseHoweverManyHanThereAre() {
        #expect(CaptureScript.dominant(in: "勉強する") == .kana)
        #expect(CaptureScript.dominant(in: "水") == .han)
        #expect(CaptureScript.dominant(in: "日本語") == .han, "kanji with no kana is indistinguishable from Chinese")
    }

    /// **Latin is not ASCII**, and a range that stopped at `z` would leave the European words this
    /// filter exists to let through unclassified — which reads to the reader as the filter being
    /// broken rather than as a gap in a range. The two division signs inside that block are
    /// symbols and must not vote.
    /// **The fixture has to be letters the ASCII range cannot reach.** Written with *naïve* and
    /// *café* this passed with the Latin-1 range deleted — four ASCII letters outvote one accented
    /// one, so it answered `.latin` either way and could not fail for the reason it is named
    /// after. Verified by deleting the range and watching it stay green.
    @Test func latinReachesPastAscii() {
        #expect(CaptureScript.dominant(in: "çà") == .latin, "every letter here is past ASCII")
        #expect(CaptureScript.dominant(in: "ÀÉÎÕÜ") == .latin)
        // These two only prove the accented letters do not *break* an otherwise ASCII word; they
        // are kept as the realistic case, not as the check.
        #expect(CaptureScript.dominant(in: "naïve") == .latin)
        #expect(CaptureScript.dominant(in: "Grüße") == .latin)
        #expect(CaptureScript.dominant(in: "×÷") == nil, "a division sign is a symbol, not a letter")
    }

    /// **Punctuation inside a script's block is not that script.** `U+30FB ・` sits in the
    /// Katakana block and is a separator, so a range-only classifier counted it as kana — and
    /// because any kana absorbs han, `水・` came back Japanese. A reader studying Chinese would
    /// have had it refused and filed under a script they had not ticked. Letterhood is asked of
    /// Unicode now, not inferred from a block.
    @Test func punctuationInsideAScriptsBlockDoesNotVote() {
        #expect(CaptureScript.dominant(in: "水・") == .han)
        #expect(CaptureScript.dominant(in: "・") == nil)
        #expect(CaptureScript.dominant(in: "。、「」") == nil)
        // The prolonged sound mark *is* a letter and stays kana: ラーメン is one word.
        #expect(CaptureScript.dominant(in: "ラーメン") == .kana)
    }

    /// **A script this cannot name is a word that escapes the filter**, because unclassified text
    /// is deliberately looked up. So the coverage gaps were not cosmetic: halfwidth katakana, the
    /// han beyond the basic plane, and Latin past `0x024F` all answered nil and walked straight
    /// through a filter set to exclude them.
    @Test func theScriptsAreRecognisedWhereverUnicodePutsThem() {
        #expect(CaptureScript.dominant(in: "ｶﾀｶﾅ") == .kana, "halfwidth katakana")
        #expect(CaptureScript.dominant(in: "𠮷") == .han, "han beyond the basic plane")
        #expect(CaptureScript.dominant(in: "ế") == .latin, "Latin Extended Additional")
        #expect(CaptureScript.dominant(in: "Ɓ") == .latin, "Latin Extended-B")
        #expect(CaptureScript.dominant(in: "ﾊﾝｸﾞﾙ") == .kana)
        #expect(CaptureScript.dominant(in: "한글") == .hangul)
    }

    /// **One word must not classify two ways depending on how it was typed.** Composed `ế` is a
    /// single scalar and decomposed `ế` is `e` plus two combining marks; before normalising, the
    /// first answered nil and the second Latin. A capture from the screen can be either.
    @Test func composedAndDecomposedTextAgree() {
        let composed = "ế"
        let decomposed = "e\u{0302}\u{0301}"
        // **Compared as scalars, not as strings.** Swift's `String` equality is canonical, so the
        // two compare equal and `composed != decomposed` is false — the premise has to be stated
        // at the level the classifier actually reads.
        #expect(Array(composed.unicodeScalars) != Array(decomposed.unicodeScalars),
                "the fixture must actually differ, or this proves nothing")
        #expect(CaptureScript.dominant(in: composed) == CaptureScript.dominant(in: decomposed))
        #expect(CaptureScript.dominant(in: composed) == .latin)
    }

    /// **A block named for a script still holds other scripts' letters.** `U+AB65 ꭥ` is GREEK
    /// LETTER SMALL CAPITAL OMEGA and it lives in *Latin* Extended-E — so widening the Latin
    /// ranges to cover `ế` swept it in, and a Latin-only reader would have had Greek looked up and
    /// filed under Latin. Verified against the character's own Unicode name. The lesson is the one
    /// that made `・` kana: a block is a range of code points, not a statement about script.
    @Test func aBlockNamedForOneScriptCanHoldAnother() {
        #expect(CaptureScript.dominant(in: "\u{AB65}") == nil, "Greek inside Latin Extended-E")
    }

    /// **Compatibility normalisation is what stops the block list growing for ever.** Ligatures,
    /// halfwidth kana and fullwidth Latin are the same letters wearing presentation forms, and
    /// folding them first removes three whole families of gaps instead of chasing them one block
    /// at a time — which is what the first two rounds of this classifier did.
    @Test func presentationFormsFoldToTheLettersTheyAre() {
        #expect(CaptureScript.dominant(in: "ﬀ") == .latin, "the ff ligature is two Latin letters")
        #expect(CaptureScript.dominant(in: "ｶﾀｶﾅ") == .kana, "halfwidth katakana")
        #expect(CaptureScript.dominant(in: "ＡＢＣ") == .latin, "fullwidth Latin")
        #expect(CaptureScript.dominant(in: "㌍") == .kana, "a squared katakana word")
    }

    /// Kana past the original blocks. These do not decompose, so normalisation cannot reach them
    /// and the blocks have to be named.
    @Test func kanaBeyondTheOriginalBlocksIsStillKana() {
        #expect(CaptureScript.dominant(in: "\u{1B001}") == .kana, "Kana Supplement")
        #expect(CaptureScript.dominant(in: "\u{1B150}") == .kana, "Small Kana Extension")
    }

    /// A mixed capture takes the script most of its letters are in. The case this is for is a word
    /// picked up with a stray neighbour — OCR returning `the 水` — where refusing to classify at
    /// all would be worse than naming the majority.
    @Test func amongLettersTheMajorityScriptWins() {
        #expect(CaptureScript.dominant(in: "the 水") == .latin)
        #expect(CaptureScript.dominant(in: "水水 a") == .han)
        #expect(CaptureScript.dominant(in: "하다 a") == .hangul)
    }
}
