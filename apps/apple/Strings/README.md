# XDict's strings

XDict's own words ship in English (the source) and Simplified Chinese. A dictionary's content is never translated.

| File | What it holds | Read by |
|---|---|---|
| `Localizable.xcstrings` | every sentence, label and button of the app | `Bundle.main`, through `String(localized:)`, `LocalizedStringResource` and SwiftUI |
| `ServicesMenu.xcstrings` | the Service's title, "Look Up in XDict" | macOS's Services menu (`Info.plist` `NSServices`) |
| `InfoPlist.xcstrings` | the app's name and copyright line | Finder, the Dock, the About panel |

`Tools/build-bundle.sh` compiles all three into `Contents/Resources/<language>.lproj/` and refuses a bundle that lacks
any table, or an `InfoPlist.strings` key, in any language.

## Adding a string

1. Write it where the reader sees it, in the view layer (`Sources/XDictUI`, or `EntrySentences` in the entry view):
   `Text("Show in Finder")`, or a `LocalizedStringResource` from a `…Sentences` function. Below the view layer, code
   hands up kinds (an enum), never sentences; the core's English never becomes a reader's sentence (it may show as a
   diagnostic beneath one, as a skipped style sheet's `detail` does).
2. Pass values, not text: interpolate the `Int`, the `UInt64`, the `Double` itself. Numbers are then formatted for the
   reader's language when the sentence is read. A size or a share goes through a format style in the interpolation:
   `"\(bytes, format: .byteCount(style: .memory))"`, `"\(share, format: LibrarySentences.percent)"`. Never `"\(n)%"`,
   `String(format:)` or a number written into the key.
3. Run `make strings` on a build Mac. It extracts every key into `Localizable.xcstrings`; new keys arrive untranslated
   and old ones are marked stale.
4. Give each new key its English (where it differs from the key) and its Chinese, and remove the stale ones.
   `make test` fails until you do.

## Counts take plural forms

Any key whose format takes an integer (`%lld`, `%llu`) needs plural forms in English, or it says "1 files":

- **One count in the key**: a plural variation, with `one` and `other` in English and `other` alone in Chinese (CLDR gives
  Chinese no singular). Don't special-case 1 in code.
- **A count among other arguments**: a substitution. The English sentence holds `%2$#@n@` where the count goes, and the
  substitution `n` (`argNum`, `formatSpecifier`, plural `one`/`other`, each using `%arg`) words that phrase, verb
  included when the verb agrees ("%arg entry is"/"%arg entries are"). Chinese can stay a plain string.
- **Not a count** (a position "3 of 7", a version, a label and its number): add the key to `notCounts` in
  `StringCatalogTests` with the reason.

Write a Chinese sentence so that it reads for any number, 1 included ("已检查全部词条（共 %llu 个）").

## Adding a language

1. Add its code to `CFBundleLocalizations` in `Resources/Info.plist`, to `InterfaceLanguage` (Settings ▸ General), and
   to `languages` in `Tests/XDictTests/StringCatalogTests.swift` and `LANGUAGES` in `Tools/build-bundle.sh`.
2. Add a localization for every key of the three catalogs. Plurals take the categories CLDR gives that language (Russian
   needs `one`, `few`, `many`, `other`; Japanese only `other`).
3. Run the UI tour in it (`Tools/ui-tour/run.sh`, add the variant to `tour.py`), and the `pseudo` variant if the language
   runs longer than English.

What catches a gap:

| Gap | Caught by |
|---|---|
| a string the code says and the catalog lacks | `everyLiteralTheReaderSeesIsInTheCatalog` |
| a key with no translation in some language, a plural form missing `other`, a stale key | `everyEntryIsCompleteInBothLanguages` |
| a count with no plural forms in English | `everyCountHasPluralForms` |
| a plural that leaves a directive unformatted, or picks the same words for 1 and 2 | `everyPluralReadsWholeInBothLanguages` |
| a table that does not compile, or a value that does not reach the compiled table | `theCatalogCompilesIntoTablesTheBundleReads` |
| the Service title or an `Info.plist` string untranslated, or out of step with `Info.plist` | `theServiceMenuTitleIsCompleteInBothLanguages`, `theInfoPlistStringsAreCompleteAndMatchInfoPlist` |
| display text below the view layer | `noTargetBelowTheViewLayerHoldsDisplayText` |
| a language's table missing from the bundle | `Tools/build-bundle.sh` (`verify_bundle`) |

To read a sentence as a reader of one language sees it in a test, use `CompiledCatalog.text(_:in:)` from
`XDictTestSupport`: a test process has no app bundle, so `String(localized:)` alone returns the English key.

## Layout in longer languages

`Tools/ui-tour/run.sh --variants light-pseudo` runs the tour in a pseudo language: English accented and about 40% longer
(`Tools/ui-tour/pseudo.py`), compiled into a copy of the installed app on the E2E Mac, never into XDict.app. A label that
clips, wraps or overlaps there will do the same in German or Russian.
