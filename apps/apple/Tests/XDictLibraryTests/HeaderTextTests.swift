import Testing
import XDictLibrary

/// **The name a dictionary is shown by, and its About** (R11): the reader's own name first, then the header's title,
/// then the file's name — never MdxBuilder's placeholder `Title (No HTML code allowed)`, and never markup.
struct HeaderTextTests {
    @Test func theReadersNameComesFirst() {
        #expect(DisplayName.of(readers: "Mine", title: "Longman", fileName: "x.mdx") == "Mine")
        #expect(DisplayName.of(readers: "   ", title: "Longman", fileName: "x.mdx") == "Longman")
    }

    @Test func thePlaceholderTitleFallsBackToTheFileName() {
        #expect(DisplayName.of(readers: nil, title: "Title (No HTML code allowed)", fileName: "牛津高阶英汉双解词典.mdx")
                == "牛津高阶英汉双解词典")
        #expect(DisplayName.of(readers: nil, title: "  title (no html code allowed) ", fileName: "x.MDX") == "x")
        #expect(DisplayName.of(readers: nil, title: "", fileName: "Plain Glossary.mdx") == "Plain Glossary")
    }

    @Test func markupInATitleIsNotShown() {
        #expect(DisplayName.of(readers: nil, title: "<b>Oxford</b> &amp; Co", fileName: "x.mdx") == "Oxford & Co")
        #expect(DisplayName.of(readers: nil, title: "<br>", fileName: "x.mdx") == "x")
    }

    @Test func aDescriptionIsReadAsPlainText() {
        #expect(HeaderText.plain("<b>Hello</b><br>World &amp; more&nbsp;&lt;3&gt;") == "Hello\nWorld & more <3>")
        #expect(HeaderText.plain("<p>One</p><p>Two</p>") == "One\nTwo")
        #expect(HeaderText.plain("Description (No HTML code allowed)") == "")
        #expect(HeaderText.plain("  plain  ") == "plain")
    }
}
