//! XDict's canonical roles (`dev-docs/element-sweep.md` §2.1): each element the generic rules recognise gets one
//! `data-xdict-role`, with `data-xdict-section` or `data-xdict-label` naming a section's or a label's kind, so the
//! frame styles every dictionary alike. Only the sweep's generic rules are applied: the element tree, the entry's
//! key, the link's kind, attributes and handlers, the text, and what the edition's own CSS sets on an element's tag
//! and classes. No dictionary is named here.
//!
//! The scanner has no tree, so this builds one as it goes: a node per element (at most [`MAX_NODES`]), each with
//! its text as a range of one buffer of all the entry's text. The rules run once the entry is read, in the
//! sweep's order, each over the nodes once; what a rule asks of a node's descendants or siblings is kept as it is
//! built (a mask of the roles below it, the first long child, the first two children with text), so the cost is
//! linear in the entry. The same tree carries the strip rules that need one (S5, S10, S11).

use std::collections::BTreeMap;

use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::canonical_combining_class;

use crate::facts::{Facts, Props};
use crate::url::Link;

mod icons;
mod profiles;

/// The most elements followed; past it the rest of the entry gets no role.
const MAX_NODES: usize = 1 << 16;
/// The deepest element followed.
const MAX_DEPTH: usize = 256;
/// How far down the stack an end tag looks for its element.
const MATCH_DEPTH: usize = 32;
/// The most characters of an element's text read, as the sweep read them.
const TEXT_CHARS: usize = 800;
/// Texts at most this long are kept whole, for the rules that compare them.
const SHORT_CHARS: usize = 80;
/// The most bytes [`TEXT_CHARS`] and one more character take: what is read of an element's text from its start.
const READ_BYTES: usize = 4 * (TEXT_CHARS + 1);
/// The most bytes of text kept for the whole entry.
const TEXT_BYTES: usize = 32 << 20;
/// The most attributes read from one tag, and the most bytes of one value.
const ATTRIBUTES: usize = 64;
const VALUE_BYTES: usize = 1024;
/// How many siblings each side a hidden element is compared with (S11).
const SIBLINGS: usize = 8;
/// The shortest text a hidden duplicate is dropped for (S11).
const DUPLICATE_CHARS: usize = 20;
const ROOT: u32 = 0;
/// The longest text a run of in-page links may hold and still be taken for website chrome (Q5).
const CHROME_CHARS: usize = 200;
const SEPARATORS: &str = "|·•◆◇■□●○▪▫/\\-–—_=*~♦✦❖⁂※,;:";

const VOID: [&str; 18] = [
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr", "param",
    "basefont", "bgsound", "frame", "keygen",
];
/// Whether a tag's handler names a recording by its key (the icon sweep's §7.2): it is a speaker.
pub(crate) fn keyed_handler(tag: &str) -> bool {
    attributes(tag).iter().any(|(k, v)| k.starts_with("on") && icons::keyed(v).is_some())
}

/// Whether an element has no end tag.
pub(crate) fn void(name: &str) -> bool {
    VOID.iter().any(|v| v.eq_ignore_ascii_case(name))
}

/// Elements that are never unwrapped, even empty: they draw or hold structure, or a script or link may need them.
const STRUCTURE: [&str; 46] = [
    "a", "td", "th", "tr", "tbody", "thead", "tfoot", "table", "col", "colgroup", "caption", "li", "ul", "ol", "dl",
    "dt", "dd", "p", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "textarea", "select", "option", "button", "iframe",
    "object", "canvas", "video", "audio", "svg", "math", "script", "style", "template", "noscript", "label", "form",
    "details", "summary", "slot", "picture",
];
/// Elements that never get a role: tables are marked by `crate::tables`, and a cell's role would be a table's.
const NO_ROLE: [&str; 7] = ["table", "tr", "td", "th", "tbody", "thead", "tfoot"];
const HTML_TAGS: &str = " a abbr acronym address area article aside audio b base basefont bdi bdo big blink blockquote \
body br button canvas caption center cite code col colgroup data datalist dd del details dfn dialog dir div dl dt em \
embed fieldset figcaption figure font footer form frame frameset h1 h2 h3 h4 h5 h6 head header hgroup hr html i iframe \
img input ins kbd label legend li link main map mark marquee menu meta meter nav nobr noscript object ol optgroup \
option output p param picture pre progress q rp rt ruby s samp script section select small source span strike strong \
style sub summary sup svg table tbody td template textarea tfoot th thead time title tr track tt u ul var video wbr \
math path g rect circle line polyline polygon text tspan defs use symbol image ";

const POS_WORDS: &[&str] = &[
    "a.",
    "abbr",
    "abbr.",
    "abbreviation",
    "ad.",
    "adj",
    "adj.",
    "adjective",
    "adv",
    "adv.",
    "adverb",
    "art",
    "art.",
    "article",
    "aux",
    "aux.",
    "auxiliary",
    "combining",
    "conj",
    "conj.",
    "conjunction",
    "det",
    "det.",
    "determiner",
    "exclam",
    "exclamation",
    "form",
    "int",
    "int.",
    "interj",
    "interj.",
    "interjection",
    "intransitive",
    "modal",
    "n",
    "n.",
    "noun",
    "num",
    "num.",
    "numeral",
    "phrasal",
    "pl",
    "pl.",
    "plural",
    "predet",
    "prefix",
    "prep",
    "prep.",
    "preposition",
    "pron",
    "pron.",
    "pronoun",
    "sing",
    "singular",
    "suffix",
    "symbol",
    "transitive",
    "v",
    "v.",
    "verb",
    "vi",
    "vi.",
    "vt",
    "vt.",
    "不及物动词",
    "介词",
    "代词",
    "冠词",
    "前缀",
    "副词",
    "动词",
    "助动词",
    "及物动词",
    "叹词",
    "名词",
    "后缀",
    "形容词",
    "情态动词",
    "感叹词",
    "数词",
    "缩写",
    "缩略词",
    "连词",
    "限定词",
];
const POS_PHRASES: &[&str] = &[
    "auxiliary verb",
    "cardinal number",
    "combining form",
    "countable noun",
    "definite article",
    "indefinite article",
    "intransitive verb",
    "linking verb",
    "mass noun",
    "modal verb",
    "noun phrase",
    "ordinal number",
    "phrasal verb",
    "plural noun",
    "proper noun",
    "transitive verb",
    "uncountable noun",
    "verb phrase",
];
const REGISTER: &[&str] = &[
    "approving",
    "archaic",
    "childish",
    "colloquial",
    "dated",
    "derogatory",
    "dialect",
    "disapproving",
    "especially",
    "euphemistic",
    "figurative",
    "formal",
    "humorous",
    "informal",
    "ironic",
    "jocular",
    "literary",
    "non-standard",
    "nonstandard",
    "obsolete",
    "offensive",
    "often",
    "old",
    "old-fashioned",
    "pejorative",
    "poetic",
    "rare",
    "rhetorical",
    "slang",
    "specialist",
    "taboo",
    "technical",
    "trademark",
    "use",
    "vulgar",
    "书面语",
    "俚语",
    "口语",
    "古",
    "婉",
    "方言",
    "旧",
    "正式",
    "粗",
    "褒",
    "讳",
    "谑",
    "贬",
    "非正式",
];
const REGION: &[&str] = &[
    "am",
    "ame",
    "amer.",
    "american",
    "aus",
    "austral",
    "australian",
    "br",
    "bre",
    "brit",
    "brit.",
    "british",
    "can",
    "canadian",
    "esp",
    "especially",
    "ind",
    "indian",
    "ire",
    "irish",
    "n.amer",
    "name",
    "north",
    "nz",
    "sa",
    "safr",
    "scot",
    "scottish",
    "uk",
    "us",
    "us.",
    "加",
    "澳",
    "美",
    "美式",
    "英",
    "英式",
];
const DOMAIN: &[&str] = &[
    "anatomy",
    "architecture",
    "art",
    "astronomy",
    "biology",
    "botany",
    "business",
    "chemistry",
    "computer",
    "computing",
    "economics",
    "electronics",
    "engineering",
    "finance",
    "geology",
    "grammar",
    "law",
    "linguistics",
    "math",
    "mathematics",
    "maths",
    "medical",
    "medicine",
    "military",
    "music",
    "nautical",
    "philosophy",
    "photography",
    "physics",
    "politics",
    "psychology",
    "religion",
    "sport",
    "sports",
    "statistics",
    "zoology",
    "体",
    "军",
    "动",
    "化",
    "医",
    "哲",
    "商",
    "地",
    "天",
    "宗",
    "建",
    "律",
    "政",
    "数",
    "植",
    "法",
    "海",
    "物",
    "生",
    "经",
    "解",
    "计",
    "语",
    "音",
];
const HEADINGS: &[(&str, &str)] = &[
    ("antonyms", "thesaurus"),
    ("british/american", "usage"),
    ("collocation", "colloc"),
    ("collocations", "colloc"),
    ("culture", "usage"),
    ("date", "etym"),
    ("derivation", "etym"),
    ("derivative", "derivatives"),
    ("derivatives", "derivatives"),
    ("derived", "derivatives"),
    ("derived forms", "derivatives"),
    ("derived word", "derivatives"),
    ("etymology", "etym"),
    ("example sentences", "examples"),
    ("examples", "examples"),
    ("examples from", "examples"),
    ("extra examples", "examples"),
    ("grammar", "usage"),
    ("help", "usage"),
    ("history", "etym"),
    ("idiom", "idioms"),
    ("idioms", "idioms"),
    ("inflections", "other"),
    ("language bank", "usage"),
    ("language note", "usage"),
    ("more about", "usage"),
    ("more examples", "examples"),
    ("nearby words", "other"),
    ("note", "usage"),
    ("notes", "usage"),
    ("opposite", "thesaurus"),
    ("origin", "etym"),
    ("other forms", "derivatives"),
    ("phrasal", "phrasal"),
    ("phrasal verb", "phrasal"),
    ("phrasal verbs", "phrasal"),
    ("phrase", "idioms"),
    ("phrases", "idioms"),
    ("pronunciation", "pron"),
    ("pronunciations", "pron"),
    ("related forms", "derivatives"),
    ("related words", "other"),
    ("run-on", "derivatives"),
    ("see also", "other"),
    ("synonym", "thesaurus"),
    ("synonyms", "thesaurus"),
    ("synonyms and related", "thesaurus"),
    ("thesaurus", "thesaurus"),
    ("translations", "other"),
    ("trending", "other"),
    ("usage", "usage"),
    ("usage note", "usage"),
    ("usage notes", "usage"),
    ("vocabulary", "usage"),
    ("which word", "usage"),
    ("word combinations", "colloc"),
    ("word family", "derivatives"),
    ("word forms", "other"),
    ("word origin", "etym"),
    ("word partners", "colloc"),
    ("word study", "usage"),
    ("习语", "idioms"),
    ("例句", "examples"),
    ("例证", "examples"),
    ("反义词", "thesaurus"),
    ("发音", "pron"),
    ("同义词", "thesaurus"),
    ("成语", "idioms"),
    ("搭配", "colloc"),
    ("注意", "usage"),
    ("派生词", "derivatives"),
    ("用法", "usage"),
    ("短语", "idioms"),
    ("短语动词", "phrasal"),
    ("词族", "derivatives"),
    ("词源", "etym"),
    ("语法", "usage"),
    ("语源", "etym"),
    ("辨析", "thesaurus"),
    ("近义词", "thesaurus"),
];
const IPA: &str = "ɑɐɒæɓʙβɔɕçɗɖðʤəɘɚɛɜɝɞɟʄɡɠɢʛɦɧħɥʜɨɪʝɭɬɫɮʟɱɯɰŋɳɲɴøɵɸθœɶʘɹɺɾɻʀʁɽʂʃʈʧʉʊʋⱱʌɣɤʍχʎʏʑʐʒʔʡʕʢǀǁǂǃˈˌːˑ\u{329}\u{32f}\u{303}ʰʲʷˠˤ\u{31a}";
const STRONG_IPA: &str = "əɪʊʌɔæɑɒɛɜθðʃʒŋˈˌːɚɝɐʔɹɾ";

/// A section's kind, from its heading's name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Role {
    Audio,
    Fold,
    Image,
    Headword,
    Homograph,
    Pron,
    Sensenum,
    Pos,
    Gram,
    Label(&'static str),
    Example,
    ExampleTrans,
    Trans,
    Def,
    Sense,
    Examples,
    Subhead,
    Guide,
    Heading,
    Section(&'static str),
    Entry,
    Chrome,
}

impl Role {
    fn bit(self) -> u32 {
        1 << match self {
            Role::Audio => 0,
            Role::Fold => 1,
            Role::Image => 2,
            Role::Headword => 3,
            Role::Homograph => 4,
            Role::Pron => 5,
            Role::Sensenum => 6,
            Role::Pos => 7,
            Role::Gram => 8,
            Role::Label(_) => 9,
            Role::Example => 10,
            Role::ExampleTrans => 11,
            Role::Trans => 12,
            Role::Def => 13,
            Role::Sense => 14,
            Role::Examples => 15,
            Role::Subhead => 16,
            Role::Guide => 17,
            Role::Heading => 18,
            Role::Section(_) => 19,
            Role::Entry => 20,
            Role::Chrome => 21,
        }
    }

    /// The attribute value written, and its kind; `None` for the roles the sweep leaves unassigned (tier 3) and
    /// those found only to keep others right.
    fn written(self) -> Option<(&'static str, Option<(&'static str, &'static str)>)> {
        Some(match self {
            Role::Audio => ("audio", None),
            Role::Fold => ("fold", None),
            Role::Image => ("image", None),
            Role::Headword => ("headword", None),
            Role::Homograph => ("homograph", None),
            Role::Pron => ("pron", None),
            Role::Sensenum => ("sensenum", None),
            Role::Pos => ("pos", None),
            Role::Label(k) => ("label", Some(("data-xdict-label", k))),
            Role::Example => ("example", None),
            Role::ExampleTrans => ("example-trans", None),
            Role::Trans => ("trans", None),
            Role::Sense => ("sense", None),
            Role::Subhead => ("subhead", None),
            Role::Heading => ("heading", None),
            Role::Section(k) => ("section", Some(("data-xdict-section", k))),
            Role::Entry => ("entry", None),
            Role::Chrome => ("chrome", None),
            Role::Gram | Role::Def | Role::Examples | Role::Guide => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Lk {
    None,
    Lookup,
    Sound,
    Anchor,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kid {
    Text { words: u32, blank: bool },
    El(u32),
}

/// Bold, italic, small capitals, superscript, hidden: as inherited.
#[derive(Debug, Clone, Copy, Default)]
struct Flags {
    bold: bool,
    italic: bool,
    small: bool,
    sup: bool,
    hidden: bool,
}

struct Node {
    name: Box<str>,
    /// A class names a homograph (`hom`).
    hom: bool,
    parent: u32,
    pos: u32,
    kids: Vec<Kid>,
    start: usize,
    attr_at: usize,
    tag_end: usize,
    end: Option<(usize, usize)>,
    /// Its text, as a range of the tree's `buf` (at most [`TEXT_BYTES`], so `u32`).
    text: (u32, u32),
    direct: bool,
    link: Lk,
    href: bool,
    /// It has a handler, and the handler folds.
    handled: bool,
    folds: bool,
    audio_attr: bool,
    /// A handler that passes a path (`f(this,'a/b/c')`) and does not fold: audio when the element has no text.
    pathy: bool,
    /// A recording an attribute or handler names (S5).
    recording: Option<Box<str>>,
    flags: Flags,
    own_hidden: bool,
    /// Never unwrapped (S10): an id or name, a handler, data, a style, a drawing rule, a script's name.
    keep: bool,
    drawn: bool,
    void: bool,
    image: bool,
    big_font: bool,
    /// A box of its own: its sheets' `display`, else its tag's.
    boxed: bool,
    /// Its markup (element and classes, or its presentation), hashed: elements of the same markup.
    sig: u64,
    /// The role the edition's markup table names it (`profiles`), before its text is checked.
    profiled: Option<profiles::Sure>,
    /// The table names it a sense **header**: its run reaches into its following siblings (ADR-0029 d.2).
    sense_header: bool,
    /// What the icon rules read (`icons`), and what of it is inherited.
    icon: icons::Attrs,
    inherit: icons::Inherited,
}

/// What a rule reads of an element's text, computed once.
#[derive(Default, Clone)]
struct Feat {
    short: Option<String>,
    len: usize,
    words: u32,
    cjk: f64,
    lat: f64,
    keyform: bool,
    caps: bool,
    starts_cap: bool,
    ends_punct: bool,
    footer: bool,
    order: u32,
    is_key: bool,
}

/// An edit of the written entry: the bytes `at..until` replaced by `text` (an insertion when they are equal).
pub(crate) type Edit = (usize, usize, String);

pub(crate) struct Roles<'s> {
    nodes: Vec<Node>,
    stack: Vec<u32>,
    deep: usize,
    buf: String,
    facts: &'s Facts,
    /// The table of the edition's markup, if one names it (`profiles`).
    profile: Option<&'static profiles::Profile>,
    key: Option<String>,
    base: String,
    dir: String,
    /// Whether the package holds a resource, by its path as it travels.
    resource: Option<&'s dyn Fn(&str) -> bool>,
    /// Symbols written as text the icon rules may change: the element, where they are written and their character.
    glyphs: Vec<icons::Written>,
    /// Whether the strip list's rules this tree owns (S5, S10, S11) apply: always, but in the hostile battery's lab.
    strip: bool,
    /// The element closed last, while nothing visible has followed it: punctuation written next hugs it.
    hug_after: Option<u32>,
    /// Punctuation alone after a block it hugs, to move inside that block: the block, where the text is written, and
    /// the punctuation.
    moves: Vec<(u32, usize, String)>,
    /// Elements closed right before a `,` `;` or `.` (the frame drops their inline end spacing).
    hugs: Vec<u32>,
    /// Space written right after a block, past any punctuation: where it starts and ends. It goes if a block opens
    /// next, since space alone between two blocks is a line of its own (OED's `&nbsp;` between pronunciations).
    gap: Option<(usize, usize)>,
    /// Space to drop: between an inline element and the full stop after it, or a block's leading break.
    gaps: Vec<(usize, usize)>,
    /// Space alone between two blocks, past any punctuation moved into the first: it becomes one plain space, which
    /// collapses, so a text node stays between the blocks for a dictionary's script that walks `nextSibling`
    /// (MWALED's `this.nextSibling.nextSibling` fold).
    spaces: Vec<(usize, usize)>,
    /// A `<br>` written before anything else in its block (the block, where the break starts and ends): the block
    /// already starts a line, so once text follows in it the break goes, as its blank line would (COBUILD-EC's
    /// `<div><br>【语法信息】…`, WI-11 R8). Alone in its block it is a spacer the dictionary meant, and stays.
    lead_break: Option<(u32, usize, usize)>,
    /// Inline elements that start a line: after a block, or first in their block. A role among them is written
    /// `data-xdict-line-start`, so the space a dictionary put before it to part it from a word drops (OALD's *Pima*).
    line_starts: Vec<u32>,
    /// Nothing but space written since the last box began or ended: the next inline element starts a line.
    line_open: bool,
    /// Visible text written since the last box began or ended, or the last break.
    line_text: bool,
    /// Private Use characters of a known markup, where they are written and their Unicode ([`minion`]).
    unicode: Vec<(usize, usize, &'static str)>,
    /// Elements of Minion's markup (`class="MinionNew"`), whose Private Use characters [`minion`] writes as Unicode.
    minions: Vec<u32>,
    /// Elements no visible text on their line comes before: they start a line. In order, as the nodes are.
    fresh: Vec<u32>,
}

/// What the tree decided: its edits, the strip counts it owns, and the roles written.
pub(crate) struct Decided {
    pub(crate) edits: Vec<Edit>,
    pub(crate) audio_links: u64,
    pub(crate) empty: u64,
    pub(crate) hidden_duplicates: u64,
    pub(crate) roles: BTreeMap<String, u64>,
    pub(crate) icons: BTreeMap<String, u64>,
    /// Each headword element's extent, from where its attributes go to its end tag (unclosed: the entry's end).
    pub(crate) headwords: Vec<(usize, usize)>,
}

impl<'s> Roles<'s> {
    /// A tree for an entry; `key` (the entry's key) asks for roles, without it only the strip rules run.
    pub(crate) fn new(facts: &'s Facts, key: Option<&str>, base: &str, dir: &str) -> Self {
        let root = Node {
            name: "#root".into(),
            hom: false,
            parent: ROOT,
            pos: 0,
            kids: Vec::new(),
            start: 0,
            attr_at: 0,
            tag_end: 0,
            end: None,
            text: (0, 0),
            direct: false,
            link: Lk::None,
            href: false,
            handled: false,
            folds: false,
            audio_attr: false,
            pathy: false,
            recording: None,
            flags: Flags::default(),
            own_hidden: false,
            keep: true,
            drawn: false,
            void: false,
            image: false,
            big_font: false,
            boxed: true,
            sig: 0,
            profiled: None,
            sense_header: false,
            icon: icons::Attrs::default(),
            inherit: icons::Inherited::default(),
        };
        Self {
            nodes: vec![root],
            stack: vec![ROOT],
            deep: 0,
            buf: String::new(),
            facts,
            profile: profiles::of(facts),
            key: key.map(str::to_owned),
            base: base.to_owned(),
            dir: dir.to_owned(),
            resource: None,
            glyphs: Vec::new(),
            strip: true,
            hug_after: None,
            moves: Vec::new(),
            gaps: Vec::new(),
            spaces: Vec::new(),
            gap: None,
            hugs: Vec::new(),
            lead_break: None,
            line_starts: Vec::new(),
            line_open: true,
            line_text: false,
            unicode: Vec::new(),
            minions: Vec::new(),
            fresh: Vec::new(),
        }
    }

    /// The strip list off ([`crate::Entry::strip_off_for_tests`]): the tree marks roles and strips nothing.
    pub(crate) fn unstripped(mut self, off: bool) -> Self {
        self.strip = !off;
        self
    }

    /// The package's resources, for a recording a handler names by its key.
    pub(crate) fn with_resource(mut self, resource: Option<&'s dyn Fn(&str) -> bool>) -> Self {
        self.resource = resource;
        self
    }

    /// A start tag `name`, written from `start` to `tag_end`; an attribute inserted at `attr_at` follows its name.
    /// `tag` is its source; `image` marks a content image outside a link.
    /// `closed`: the tag was written self-closed and closed at once (S4), its end tag's bytes.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn start(
        &mut self,
        name: &str,
        start: usize,
        attr_at: usize,
        tag_end: usize,
        tag: &str,
        image: bool,
        closed: Option<(usize, usize)>,
    ) {
        let lower = name.to_ascii_lowercase();
        if let Some(gap) = self.gap.take()
            && block_tag(&lower)
            && self.spaces.len() < MAX_NODES
        {
            self.spaces.push(gap);
        }
        let void = closed.is_none() && (VOID.contains(&lower.as_str()) || tag.ends_with("/>"));
        if void || image {
            self.hug_after = None;
        }
        if self.stack.len() >= MAX_DEPTH || self.nodes.len() >= MAX_NODES {
            if !void {
                self.deep += 1;
            }
            return;
        }
        let Some(&parent) = self.stack.last() else { return };
        // A break before anything else in a block: it goes once text follows in that block (`lead_break`).
        if lower == "br"
            && self.nodes.get(parent as usize).is_some_and(|p| {
                block_tag(&p.name) && p.kids.iter().all(|k| matches!(k, Kid::Text { blank: true, .. }))
            })
        {
            self.lead_break = Some((parent, start, tag_end));
        }
        let attrs = attributes(tag);
        let get = |n: &str| attrs.iter().find(|(k, _)| k == n).map(|(_, v)| v.as_str());
        let classes: Vec<String> = get("class")
            .map(|c| c.split_ascii_whitespace().take(16).map(str::to_ascii_lowercase).collect())
            .unwrap_or_default();
        let custom = !HTML_TAGS.contains(&format!(" {lower} "));
        let style = get("style").unwrap_or("").to_ascii_lowercase();
        let mut props = self.facts.props(&lower, &classes);
        let inline = Props::of(style.split(';').filter_map(|d| d.split_once(':')), true);
        merge(&mut props, &inline);
        // A box of its own (by its sheets' `display`, else its tag) starts a line; an inline element at a line's
        // start is one (`line_starts`), and is past it.
        let boxed = props.inline.map_or_else(|| block_tag(&lower), |i| !i);
        if boxed || lower == "br" {
            self.line_open = true;
            self.line_text = false;
        } else if !void {
            if self.line_open && self.line_starts.len() < MAX_NODES {
                self.line_starts.push(self.nodes.len() as u32);
            }
            self.line_open = false;
        }
        let up = self.nodes.get(parent as usize).map(|p| p.flags).unwrap_or_default();
        let flags = Flags {
            bold: if matches!(lower.as_str(), "b" | "strong" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "th")
                || props.bold == Some(true)
            {
                true
            } else if props.bold == Some(false) {
                false
            } else {
                up.bold
            },
            italic: if matches!(lower.as_str(), "i" | "em" | "cite" | "var") || props.italic == Some(true) {
                true
            } else if props.italic == Some(false) {
                false
            } else {
                up.italic
            },
            small: up.small || props.small_caps == Some(true) || props.upper == Some(true),
            sup: up.sup || lower == "sup" || props.sup == Some(true),
            hidden: up.hidden || props.none == Some(true) || get("hidden").is_some(),
        };
        let handlers: String =
            attrs.iter().filter(|(k, _)| k.starts_with("on")).map(|(_, v)| v.as_str()).collect::<Vec<_>>().join(" ");
        let data: String =
            attrs.iter().filter(|(k, _)| k.starts_with("data-")).map(|(_, v)| v.as_str()).collect::<Vec<_>>().join(" ");
        let href = if matches!(lower.as_str(), "a" | "area") { get("href") } else { None };
        let link = match href.map(|h| crate::url::classify(h, &self.base, &self.dir)) {
            None => Lk::None,
            Some(Link::Lookup { .. }) => Lk::Lookup,
            Some(Link::Sound { .. } | Link::Speak { .. }) => Lk::Sound,
            Some(Link::Anchor { .. }) => Lk::Anchor,
            Some(_) => Lk::Other,
        };
        let audio_attr = audio_attr(&handlers, &data);
        let recording = ["data-mp3", "data-src-mp3", "data-file", "data-src", "data-audio"]
            .iter()
            .filter_map(|n| get(n))
            .find(|v| crate::strip::recording(v))
            .or_else(|| crate::strip::handler_recording(&handlers))
            .map(Box::from)
            .filter(|_| href.is_none_or(crate::strip::javascript_url));
        let keep = get("id").is_some()
            || get("name").is_some()
            || !handlers.is_empty()
            || attrs.iter().any(|(k, _)| k.starts_with("data-") || k == "role" || k == "tabindex")
            || !style.trim().is_empty()
            || STRUCTURE.contains(&lower.as_str())
            || self.facts.script_named(&lower, custom, &classes);
        let drawn = self.facts.drawn(&lower, &classes);
        // A frequency or level class marks one word of a markup, not another markup (LDOCE's `hyphenation frequent`
        // and `hyphenation`, MED's `BASE redword` and `BASE`): the signature leaves it out.
        let kinds: Vec<&str> = classes.iter().map(String::as_str).filter(|c| !modifier(c)).collect();
        let sig = if !kinds.is_empty() {
            format!("{lower}.{}", kinds.join("."))
        } else if custom {
            lower.clone()
        } else {
            let font: Vec<&str> = ["color", "face", "size"].iter().filter_map(|n| get(n)).collect();
            format!("{lower}[{}|{style}]", font.join(","))
        };
        let (icon, inherit) = icons::Attrs::of(&lower, &attrs, &classes, link, self.facts, &self.nodes, &self.stack);
        let pos = self.nodes.get(parent as usize).map_or(0, |p| p.kids.len()) as u32;
        let profiled = self.profile.and_then(|p| p.sure(&lower, &classes));
        let sense_header = self.profile.is_some_and(|p| p.is_sense_header(&lower, &classes));
        let id = self.nodes.len() as u32;
        let at = self.buf_at();
        if !self.line_text {
            self.fresh.push(id);
        }
        if classes.iter().any(|c| c == "minionnew") {
            self.minions.push(id);
        }
        self.nodes.push(Node {
            name: lower.into_boxed_str(),
            hom: classes.iter().any(|c| c.contains("hom")),
            parent,
            pos,
            kids: Vec::new(),
            start,
            attr_at,
            tag_end,
            end: closed,
            text: (at, at),
            direct: false,
            link,
            href: href.is_some(),
            handled: !handlers.is_empty(),
            folds: fold_handler(&handlers),
            audio_attr,
            pathy: pathy(&handlers),
            recording,
            flags,
            own_hidden: flags.hidden && !up.hidden,
            keep,
            drawn,
            void,
            image,
            big_font: big_font(&style),
            boxed,
            sig: {
                use std::hash::{Hash, Hasher};
                let mut h = std::collections::hash_map::DefaultHasher::new();
                sig.hash(&mut h);
                h.finish()
            },
            profiled,
            sense_header,
            icon,
            inherit,
        });
        if let Some(p) = self.nodes.get_mut(parent as usize) {
            p.kids.push(Kid::El(id));
        }
        if !void && closed.is_none() {
            self.stack.push(id);
        }
    }

    /// Text between tags, as written; `at`, where it is written in the output when it is written as it reads.
    pub(crate) fn text(&mut self, raw: &str, at: Option<usize>) {
        if raw.is_empty() {
            return;
        }
        let after_block = self.hug_after.and_then(|n| self.nodes.get(n as usize)).is_some_and(|n| block_tag(&n.name));
        self.gap = None;
        if after_block && let Some(at) = at {
            let lead = raw.len() - raw.trim_start_matches([',', ';', '.', ':']).len();
            let rest = raw.get(lead..).unwrap_or("");
            if !rest.is_empty() && crate::rewrite::unescaped_html(rest).chars().all(char::is_whitespace) {
                self.gap = Some((at + lead, at + raw.len()));
            }
        }
        // A space between an inline element and a lone full stop after it (COBUILD's "a <b>row</b> .") goes, and the
        // stop hugs the element. Not an ellipsis, not a comma: OED writes "bankier , banquier" on purpose.
        if !after_block
            && let (Some(n), Some(at)) = (self.hug_after, at)
            && self.gaps.len() < MAX_NODES
        {
            let rest = raw.trim_start_matches(char::is_whitespace);
            let space = raw.len() - rest.len();
            let mut after = rest.chars().skip(1);
            if space > 0 && rest.starts_with('.') && after.next().is_none_or(char::is_whitespace) {
                self.gaps.push((at, at + space));
                self.hugs.push(n);
            }
        }
        if let Some(n) = self.hug_after.take()
            && raw.starts_with([',', ';', '.'])
            && self.hugs.len() < MAX_NODES
        {
            self.hugs.push(n);
            // Nothing but punctuation and space: after a block it would stand on a line of its own (OED's "," between
            // two pronunciation blocks), so it goes inside the block, before its end tag.
            // The space may be written as an entity (`,&nbsp;`).
            let punct = raw.len() - raw.trim_start_matches([',', ';', '.', ':']).len();
            if let Some(at) = at
                && let (Some(p), Some(rest)) = (raw.get(..punct), raw.get(punct..))
                && crate::rewrite::unescaped_html(rest).chars().all(char::is_whitespace)
            {
                self.moves.push((n, at, p.to_owned()));
            }
        }
        if let Some(at) = at
            && !self.minions.is_empty()
            && self.stack.iter().rev().any(|id| self.minions.binary_search(id).is_ok())
            && self.unicode.len() < MAX_NODES
        {
            for (i, c) in raw.char_indices() {
                if let Some(written) = minion(c) {
                    self.unicode.push((at + i, at + i + c.len_utf8(), written));
                }
            }
        }
        if let (Some(at), Some(&top)) = (at, self.stack.last()) {
            let first = self.nodes.get(top as usize).is_some_and(|n| !n.direct);
            icons::written(raw, at, top, first, &mut self.glyphs);
        }
        let text = crate::rewrite::unescaped_html(raw);
        let blank = text.trim().is_empty();
        let words = word_count(&text.to_lowercase());
        // Past the last element followed, only what its rules read of its text is kept.
        let read = self.nodes.len() >= MAX_NODES
            && self.nodes.last().is_some_and(|n| self.buf.len() >= n.text.0 as usize + READ_BYTES);
        if !read && self.buf.len().saturating_add(text.len()) <= TEXT_BYTES {
            self.buf.push_str(&text);
        }
        if !blank
            && let Some((block, from, to)) = self.lead_break.take()
            && self.stack.contains(&block)
            && self.gaps.len() < MAX_NODES
        {
            self.gaps.push((from, to));
        }
        let Some(&top) = self.stack.last() else { return };
        let Some(node) = self.nodes.get_mut(top as usize) else { return };
        node.direct |= !blank;
        self.line_open &= blank;
        self.line_text |= !blank;
        match node.kids.last_mut() {
            Some(Kid::Text { words: w, blank: b }) => {
                *w = w.saturating_add(words);
                *b &= blank;
            }
            _ => node.kids.push(Kid::Text { words, blank }),
        }
    }

    /// An end tag, written from `at` to `after`: closes its element, and any left open inside it.
    pub(crate) fn end(&mut self, name: &str, at: usize, after: usize) {
        self.gap = None;
        if self.deep > 0 {
            self.deep -= 1;
            return;
        }
        let lower = name.to_ascii_lowercase();
        let nodes = &self.nodes;
        let found = self
            .stack
            .iter()
            .rev()
            .take(MATCH_DEPTH.min(self.stack.len().saturating_sub(1)))
            .position(|&i| nodes.get(i as usize).is_some_and(|n| *n.name == *lower));
        let Some(up) = found else { return };
        for k in 0..=up {
            let Some(i) = self.stack.pop() else { return };
            let len = self.buf_at();
            if let Some(n) = self.nodes.get_mut(i as usize) {
                n.text.1 = len;
                if k == up {
                    n.end = Some((at, after));
                    self.hug_after = Some(i);
                }
                if n.boxed {
                    self.line_open = true;
                    self.line_text = false;
                }
            }
        }
    }

    /// Where the next text goes in `buf`, which holds at most [`TEXT_BYTES`].
    fn buf_at(&self) -> u32 {
        u32::try_from(self.buf.len()).unwrap_or(u32::MAX)
    }

    /// The edits the entry's tree asks for, once it is all read.
    pub(crate) fn finish(mut self) -> Decided {
        let len = self.buf_at();
        while let Some(i) = self.stack.pop() {
            if let Some(n) = self.nodes.get_mut(i as usize) {
                n.text.1 = len;
            }
        }
        let t = Tree::new(
            &self.nodes,
            &self.buf,
            self.key.as_deref(),
            self.profile.is_some_and(|p| p.pos_words),
            self.profile.is_some_and(|p| p.example_blocks),
        );
        let mut decided = Decided {
            edits: Vec::new(),
            audio_links: 0,
            empty: 0,
            hidden_duplicates: 0,
            roles: BTreeMap::new(),
            icons: BTreeMap::new(),
            headwords: Vec::new(),
        };
        if self.strip {
            self.audio(&t, &mut decided);
            self.duplicates(&t, &mut decided);
            self.empty(&mut decided);
        }
        let roles = if self.key.is_some() { t.assign() } else { Vec::new() };
        let senses = if self.key.is_some() { t.senses(&roles) } else { SenseMap::default() };
        icons::decide(&self.nodes, &t, &roles, &self.glyphs, self.facts, &mut decided);
        for &i in &self.hugs {
            if let Some(n) = self.nodes.get(i as usize) {
                decided.edits.push((n.attr_at, n.attr_at, " data-xdict-hug".into()));
            }
        }
        for &(from, to) in &self.gaps {
            decided.edits.push((from, to, String::new()));
        }
        for &(from, to, written) in &self.unicode {
            decided.edits.push((from, to, written.to_owned()));
        }
        for &(from, to) in &self.spaces {
            decided.edits.push((from, to, " ".into()));
        }
        for (i, at, punct) in &self.moves {
            let Some(n) = self.nodes.get(*i as usize) else { continue };
            let Some((end, _)) = n.end else { continue };
            if !block_tag(&n.name) || end > *at {
                continue;
            }
            decided.edits.push((end, end, punct.clone()));
            decided.edits.push((*at, *at + punct.len(), String::new()));
        }
        if self.key.is_some() {
            let mut led: Option<(u64, u32, usize)> = None;
            // Where the role loop below writes a sure mark: a mark it does not write is written alone after it.
            let mut wrote_sure = vec![false; self.nodes.len()];
            // The elements whose tag the role loop writes: the sense attributes of the rest follow it.
            let mut wrote_role = vec![false; self.nodes.len()];
            for (i, role) in roles.iter().enumerate() {
                let (Some(role), Some(node)) = (role, self.nodes.get(i)) else { continue };
                if *role == Role::Headword {
                    decided.headwords.push((node.attr_at, node.end.map_or(usize::MAX, |(at, _)| at)));
                }
                let Some((name, kind)) = role.written() else { continue };
                // Where the edition's markup has a table that names a role, that role is the table's, and sure; the
                // generic rule's guesses of it are not written there.
                // The mark says what the table is sure of: a translation is `trans` whichever kind the role says.
                let sure = t
                    .sure(i)
                    .filter(|s| covers(*s, *role))
                    .map(|s| if s == profiles::Sure::Trans { "trans" } else { name });
                if sure.is_none()
                    && self
                        .profile
                        .is_some_and(|p| profiles::Sure::ALL.iter().any(|s| covers(*s, *role) && p.decides(*s)))
                {
                    continue;
                }
                let mut attr = format!(" data-xdict-role=\"{name}\"");
                // **The sense run** (ADR-0029 d.2): the same id on every element of a run, its label and parent on
                // the first, and the end marker on the element after it. Not a role: the reading style does not see it.
                append_sense(&mut attr, i, &senses);
                if let Some(slot) = wrote_role.get_mut(i) {
                    *slot = true;
                }
                // Only the short marks a dictionary parts from a word before them: a part of speech, a label.
                if matches!(role, Role::Pos | Role::Label(_)) && self.line_starts.binary_search(&(i as u32)).is_ok() {
                    attr.push_str(" data-xdict-line-start");
                }
                if let Some(sure) = sure {
                    attr.push_str(&format!(" data-xdict-sure=\"{sure}\""));
                    if let Some(w) = wrote_sure.get_mut(i) {
                        *w = true;
                    }
                }
                // The entry's first headword is the lead, the one headword mark precise enough for strong styling
                // (unification R, 2026-10-16). Not one in a link: a strip of links to the homographs (LDOCE's) is
                // navigation, and the entry's own headword follows it. A later headword in the lead's own markup is a
                // homograph's (OALD's `h1.headword` of *bloody²*): a lead too, so homographs look alike (WI-11 Q2).
                //
                // A later headword is a lead only where it starts a line: inside a line of text it is a mention ("1
                // chat or chat away", a word builder's "–Adjectives: considerable"). One that restates the lead at
                // once, nothing visible written between them (CALD's plain title line, then the word with its stress
                // marks and speakers), takes the lead, and the plain one is marked restated: the frame hides it, so
                // the title is drawn once. A hidden one never does.
                if *role == Role::Headword && !self.linked(i) {
                    let take = match &led {
                        None => true,
                        Some((sig, end, _)) => {
                            let after = node.text.0 >= *end;
                            let between = self.buf.get(*end as usize..node.text.0 as usize).unwrap_or("x");
                            let restates = between.trim().is_empty() && !node.flags.hidden;
                            if after && self.fresh.binary_search(&(i as u32)).is_ok() && restates {
                                if let Some((_, _, edit)) = led.take()
                                    && let Some(e) = decided.edits.get_mut(edit)
                                {
                                    e.2 = e.2.replace(" data-xdict-lead", " data-xdict-restated");
                                }
                                true
                            } else {
                                after && self.fresh.binary_search(&(i as u32)).is_ok() && *sig == node.sig
                            }
                        }
                    };
                    if take {
                        attr.push_str(" data-xdict-lead");
                        led = Some((node.sig, node.text.1, decided.edits.len()));
                    }
                }
                let mut counted = name.to_owned();
                if let Some((attribute, value)) = kind {
                    attr.push_str(&format!(" {attribute}=\"{value}\""));
                    counted = format!("{name}:{value}");
                }
                *decided.roles.entry(counted).or_default() += 1;
                decided.edits.push((node.attr_at, node.attr_at, attr));
            }
            // **The run elements the role loop did not write**: the sense attributes go on their tags alone.
            for (i, node) in self.nodes.iter().enumerate().skip(1) {
                if wrote_role.get(i).copied().unwrap_or(false) {
                    continue;
                }
                if senses.ids.get(i).copied().flatten().is_none() && !senses.ends.get(i).copied().unwrap_or(false) {
                    continue;
                }
                let mut attr = String::new();
                append_sense(&mut attr, i, &senses);
                if !attr.is_empty() {
                    decided.edits.push((node.attr_at, node.attr_at, attr));
                }
            }
            // Inside a sure example, what keeps the dictionary's look and a Chinese block (its translation) carry
            // their mark whatever role the generic rule gave them, or none.
            for (i, node) in self.nodes.iter().enumerate().skip(1) {
                let mark = match t.sure(i) {
                    Some(profiles::Sure::Keep) => "keep",
                    Some(profiles::Sure::Trans) if node.profiled.is_none() => "trans",
                    _ => continue,
                };
                if !wrote_sure.get(i).copied().unwrap_or(true) {
                    decided.edits.push((node.attr_at, node.attr_at, format!(" data-xdict-sure=\"{mark}\"")));
                }
            }
        }
        decided
    }

    /// Whether the element is a link: it is one, it is in one, or all it holds is one (MWU's `<li><a href=…>`).
    fn linked(&self, i: usize) -> bool {
        let only_links = self.nodes.get(i).is_some_and(|n| {
            !n.direct
                && n.kids.iter().any(|k| matches!(k, Kid::El(_)))
                && n.kids.iter().all(|k| match k {
                    Kid::El(c) => self.nodes.get(*c as usize).is_some_and(|c| c.href),
                    Kid::Text { blank, .. } => *blank,
                })
        });
        only_links || self.in_link(i)
    }

    /// Whether the element, or one it is in, is a link.
    fn in_link(&self, mut i: usize) -> bool {
        for _ in 0..MAX_DEPTH {
            let Some(node) = self.nodes.get(i) else { return false };
            if node.href {
                return true;
            }
            if i == 0 || node.parent as usize == i {
                return false;
            }
            i = node.parent as usize;
        }
        false
    }

    /// S5: an element whose attribute or handler names a recording becomes, or is wrapped in, a sound link.
    fn audio(&self, t: &Tree<'_>, decided: &mut Decided) {
        for (i, node) in self.nodes.iter().enumerate() {
            let spoken = || self.key.as_ref().map(|key| format!("sound://{}.tts", crate::url::encode(key)));
            let (url, accent) = match (&node.recording, &node.icon.keyed) {
                (Some(rec), _) if crate::strip::remote(rec) => (spoken(), None),
                (Some(rec), _) => (Some(format!("sound://{}", rec.trim().trim_start_matches('/'))), None),
                // The icon sweep's §7.2: a handler that names a recording by its key (`o0e.a(this,0,'a/a__gb_1')`):
                // the package's file when it holds one by that key, else the word spoken.
                (None, Some(key)) => {
                    let held = icons::keyed_files(key).find(|f| self.resource.is_some_and(|has| has(f)));
                    (held.map(|f| format!("sound://{f}")).or_else(spoken), icons::keyed_accent(key))
                }
                (None, None) => continue,
            };
            // Inside a link already, the element is that link's drawing: a link wrapped around it would be a link
            // in a link, which HTML closes at the inner one, a second speaker beside the first (MED's
            // `<a href="sound://…"><img data-src-mp3="https://…"></a>`).
            if &*node.name != "a" && self.in_link(i) {
                continue;
            }
            let Some(url) = url else { continue };
            let written = match crate::rewrite::literal(&url, &self.base, &self.dir, usize::MAX) {
                Ok((Some(text), _)) => text,
                Ok((None, _)) => url,
                Err(_) => continue,
            };
            let href = written.replace('&', "&amp;").replace('"', "&quot;");
            let blank = t.feat.get(i).is_none_or(|f| f.len == 0);
            let mode = if blank || node.void { "replace" } else { "prefix" };
            let mut marks = format!(" data-xdict-control=\"speaker\" data-xdict-control-mode=\"{mode}\"");
            let mut glyph = "<span data-xdict-icon=\"speaker\" aria-hidden=\"true\"></span>".to_owned();
            if let Some(accent) = accent {
                marks.push_str(&format!(" data-xdict-accent=\"{accent}\""));
                glyph.push_str("<span data-xdict-tag aria-hidden=\"true\"></span>");
            }
            if &*node.name == "a" && !node.href {
                decided.edits.push((node.attr_at, node.attr_at, format!(" href=\"{href}\"{marks}")));
                decided.edits.push((node.tag_end, node.tag_end, glyph.clone()));
            } else if &*node.name == "a" {
                // A `javascript:` link: its `href` is dropped as it is written (S6); the link is given the recording.
                decided.edits.push((node.attr_at, node.attr_at, format!(" href=\"{href}\"{marks}")));
                decided.edits.push((node.tag_end, node.tag_end, glyph.clone()));
            } else if node.void {
                decided.edits.push((node.start, node.start, format!("<a href=\"{href}\"{marks}>{glyph}")));
                decided.edits.push((node.tag_end, node.tag_end, "</a>".to_owned()));
            } else if let Some((end, _)) = node.end {
                decided.edits.push((node.tag_end, node.tag_end, format!("<a href=\"{href}\"{marks}>{glyph}")));
                decided.edits.push((end, end, "</a>".to_owned()));
            } else {
                continue;
            }
            decided.audio_links += 1;
        }
    }

    /// S11: a hidden element whose text is a visible sibling's (at least [`DUPLICATE_CHARS`]) is dropped.
    fn duplicates(&self, t: &Tree<'_>, decided: &mut Decided) {
        for (i, node) in self.nodes.iter().enumerate() {
            let Some((_, after)) = node.end else { continue };
            if !node.own_hidden {
                continue;
            }
            let Some(text) = t.whole(i) else { continue };
            if text.chars().count() < DUPLICATE_CHARS {
                continue;
            }
            let Some(parent) = self.nodes.get(node.parent as usize) else { continue };
            let pos = node.pos as usize;
            let from = pos.saturating_sub(SIBLINGS);
            let to = (pos + SIBLINGS + 1).min(parent.kids.len());
            let same = parent.kids.get(from..to).unwrap_or(&[]).iter().any(|k| match k {
                Kid::El(s) if *s as usize != i => self
                    .nodes
                    .get(*s as usize)
                    .is_some_and(|n| !n.flags.hidden && t.whole(*s as usize).as_deref() == Some(text.as_str())),
                _ => false,
            });
            if same {
                decided.edits.push((node.start, after, String::new()));
                decided.hidden_duplicates += 1;
            }
        }
    }

    /// S10: an element that draws nothing (no text below it but spaces, nothing kept below it, no id, handler,
    /// data, style, drawing rule or script naming it) is unwrapped; its spaces stay.
    fn empty(&self, decided: &mut Decided) {
        let n = self.nodes.len();
        let mut blank = vec![false; n];
        // Whether a blank element holds any space at all: it goes as one space then, as nothing otherwise.
        let mut spaced = vec![false; n];
        for i in (1..n).rev() {
            let Some(node) = self.nodes.get(i) else { continue };
            let has = node.kids.iter().any(|k| match k {
                Kid::Text { .. } => true,
                Kid::El(c) => spaced.get(*c as usize).copied().unwrap_or(false),
            });
            if let Some(sp) = spaced.get_mut(i) {
                *sp = has;
            }
            let kids_blank = node.kids.iter().all(|k| match k {
                Kid::Text { blank, .. } => *blank,
                Kid::El(c) => blank.get(*c as usize).copied().unwrap_or(false),
            });
            let droppable = node.end.is_some() && !node.keep && !node.drawn && !node.void && !node.image;
            if let Some(b) = blank.get_mut(i) {
                *b = droppable && kids_blank;
            }
        }
        for (i, node) in self.nodes.iter().enumerate().skip(1) {
            if !blank.get(i).copied().unwrap_or(false) {
                continue;
            }
            let Some((_, after)) = node.end else { continue };
            decided.empty += 1;
            // The outermost blank element goes whole, its blank content with it, as one space if it held any: content
            // left behind (OED's `<span class="ieWhitespace">&nbsp;</span>`) is a no-break space beside the source's
            // own, a gap of two (gallery 2026-10-16); one space keeps the words it separated apart and collapses with
            // theirs.
            if blank.get(node.parent as usize).copied().unwrap_or(false) {
                continue;
            }
            let space = if spaced.get(i).copied().unwrap_or(false) { " " } else { "" };
            decided.edits.push((node.start, after, space.into()));
        }
    }
}

fn merge(into: &mut Props, over: &Props) {
    into.bold = over.bold.or(into.bold);
    into.italic = over.italic.or(into.italic);
    into.small_caps = over.small_caps.or(into.small_caps);
    into.upper = over.upper.or(into.upper);
    into.sup = over.sup.or(into.sup);
    into.none = over.none.or(into.none);
    into.inline = over.inline.or(into.inline);
}

/// A tag's attributes, names in lower case and values unquoted, at most [`ATTRIBUTES`] of them.
pub(crate) fn attributes(tag: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let inner = tag.trim_start_matches('<');
    let name_len = inner.find(|c: char| c.is_ascii_whitespace() || c == '/' || c == '>').unwrap_or(inner.len());
    let mut rest = inner.get(name_len..).unwrap_or("");
    while out.len() < ATTRIBUTES {
        rest = rest.trim_start_matches(|c: char| c.is_ascii_whitespace() || c == '/');
        if rest.is_empty() || rest.starts_with('>') {
            break;
        }
        let len = rest.find(|c: char| c.is_ascii_whitespace() || matches!(c, '=' | '>' | '/')).unwrap_or(rest.len());
        let name = rest.get(..len.max(1)).unwrap_or("").to_ascii_lowercase();
        rest = rest.get(len.max(1)..).unwrap_or("");
        let after = rest.trim_start();
        let value = if let Some(v) = after.strip_prefix('=') {
            let v = v.trim_start();
            let (value, next) = match v.chars().next() {
                Some(q @ ('"' | '\'')) => {
                    let body = v.get(1..).unwrap_or("");
                    let end = body.find(q).unwrap_or(body.len());
                    (body.get(..end).unwrap_or(""), body.get(end + 1..).unwrap_or(""))
                }
                _ => {
                    let end = v.find(|c: char| c.is_ascii_whitespace() || c == '>').unwrap_or(v.len());
                    (v.get(..end).unwrap_or(""), v.get(end..).unwrap_or(""))
                }
            };
            rest = next;
            let cut = (0..=value.len().min(VALUE_BYTES)).rev().find(|&i| value.is_char_boundary(i)).unwrap_or(0);
            crate::rewrite::unescaped_html(value.get(..cut).unwrap_or(""))
        } else {
            String::new()
        };
        out.push((name, value));
    }
    out
}

fn audio_attr(handlers: &str, data: &str) -> bool {
    let both = format!("{handlers} {data}").to_ascii_lowercase();
    let file = both.contains("sound://") || [".mp3", ".wav", ".spx", ".ogg"].iter().any(|e| both.contains(e));
    let h = handlers.to_ascii_lowercase();
    let call = !h.is_empty()
        && ["audio", "play", "sound", "speak", "pron"].iter().any(|w| {
            h.match_indices(w).any(|(at, _)| {
                let before = h.get(..at).and_then(|b| b.chars().next_back());
                let word_start = before.is_none_or(|c| !(c.is_alphanumeric() || c == '_'));
                let rest = h.get(at..).unwrap_or("");
                let after = rest.trim_start_matches(|c: char| c.is_alphanumeric() || c == '_').trim_start();
                word_start && after.starts_with('(')
            })
        });
    file || call
}

/// A quoted path of two or more segments in a handler, which does not fold.
fn pathy(handlers: &str) -> bool {
    let word = |c: char| c.is_alphanumeric() || c == '_' || c == '-';
    let quoted = handlers.split(['\'', '"']).skip(1).step_by(2);
    let has_path = quoted.into_iter().any(|q| {
        let parts: Vec<&str> = q.split('/').collect();
        parts.len() >= 2 && parts.iter().all(|p| !p.is_empty() && p.chars().all(word))
    });
    has_path && !fold_handler(handlers)
}

/// "copyright 2020": the word alone is a word some entries define.
fn copyright_year(lower: &str) -> bool {
    lower.match_indices("copyright").any(|(at, w)| {
        let after = lower.get(at + w.len()..).unwrap_or("").trim_start();
        after.chars().take(4).filter(char::is_ascii_digit).count() == 4
    })
}

fn fold_handler(h: &str) -> bool {
    let h = h.to_ascii_lowercase();
    ["toggle", "display", "expand", "collapse", "fold", "show", "hide", "more", "less", "classlist"]
        .iter()
        .any(|w| h.contains(w))
}

fn big_font(style: &str) -> bool {
    let Some(at) = style.find("font-size") else { return false };
    let v = style.get(at + 9..).unwrap_or("").trim_start().trim_start_matches(':').trim_start();
    let v: String = v.chars().take_while(|c| *c != ';').collect();
    let v = v.trim();
    let num = |s: &str| s.parse::<f64>().ok();
    if v.starts_with("large") || v.starts_with("x-large") {
        return true;
    }
    if let Some(em) = v.strip_suffix("em").and_then(num) {
        return (1.0..2.0).contains(&em) && v.contains('.');
    }
    if let Some(p) = v.strip_suffix('%').and_then(num) {
        return (100.0..200.0).contains(&p);
    }
    if let Some(px) = v.strip_suffix("px").and_then(num) {
        return (14.0..30.0).contains(&px);
    }
    false
}

fn word_count(lower: &str) -> u32 {
    let mut n = 0u32;
    let mut inside = false;
    for c in lower.chars() {
        let w = c.is_ascii_lowercase() || ('\u{c0}'..='\u{24f}').contains(&c) || c == '\'';
        if w && !inside {
            n = n.saturating_add(1);
        }
        inside = w;
    }
    n
}

fn words_of(lower: &str) -> Vec<&str> {
    lower
        .split(|c: char| !(c.is_ascii_lowercase() || ('\u{c0}'..='\u{24f}').contains(&c) || c == '\''))
        .filter(|w| !w.is_empty())
        .collect()
}

/// The entry's key as compared: decomposed, marks, stress, dots, hyphens, digits and spaces removed, lower case.
pub(crate) fn norm_key(s: &str) -> String {
    s.nfkd()
        .filter(|c| canonical_combining_class(*c) == 0)
        .flat_map(char::to_lowercase)
        .filter(|c| !(c.is_whitespace() || c.is_numeric() || "·•ˈˌ-‧'’.¹²³⁴⁵⁶⁷⁸⁹⁰".contains(*c)))
        .collect()
}

/// Whether a text is the key: after unmarking, or once a trailing part of speech, homograph number or parenthesis
/// is taken off ("accumulated adj.", "alias, v.").
fn is_key(text: &str, key: &str) -> bool {
    if key.is_empty() {
        return false;
    }
    if norm_key(text) == key {
        return true;
    }
    let mut t = text.trim();
    if t.ends_with([')', ']'])
        && let Some(open) = t.rfind(['(', '['])
        && t.get(open..).is_some_and(|p| p.chars().count() <= 22)
    {
        t = t.get(..open).unwrap_or(t).trim_end();
    }
    let mut words: Vec<&str> = t.split_whitespace().collect();
    while words.len() > 1 {
        let Some(last) = words.last() else { break };
        let bare = last.to_lowercase();
        let bare = bare.trim_matches(|c| ".,;:()".contains(c));
        let number = {
            let d = last.trim_end_matches(['.', ',']);
            !d.is_empty() && d.chars().all(|c| c.is_ascii_digit() || "¹²³⁴⁵⁶⁷⁸⁹".contains(c))
        };
        if POS_WORDS.contains(&bare) || number {
            words.pop();
        } else {
            break;
        }
    }
    !words.is_empty() && norm_key(words.join(" ").trim_end_matches([',', ';', ':'])) == key
}

/// The key's forms: a word's inflections, or a phrase's words.
fn key_forms(key: &str) -> (Vec<String>, Vec<String>) {
    let lower = key.to_lowercase();
    let ws: Vec<String> = words_of(&lower).into_iter().map(str::to_owned).collect();
    match ws.as_slice() {
        [] => (Vec::new(), Vec::new()),
        [w] => {
            let mut f: Vec<String> =
                ["", "s", "es", "ed", "d", "ing", "er", "est", "'s"].iter().map(|s| format!("{w}{s}")).collect();
            if let Some(stem) = w.strip_suffix('e') {
                f.extend([format!("{stem}ing"), format!("{stem}ed")]);
            }
            if let Some(stem) = w.strip_suffix('y') {
                f.extend([format!("{stem}ies"), format!("{stem}ied"), format!("{stem}ier")]);
            }
            if let Some(last) = w.chars().last()
                && w.chars().count() >= 3
                && !"aeiouwxy".contains(last)
            {
                f.extend([format!("{w}{last}ed"), format!("{w}{last}ing"), format!("{w}{last}er")]);
            }
            (f, Vec::new())
        }
        _ => (Vec::new(), ws),
    }
}

fn has_form(words: &[&str], forms: &(Vec<String>, Vec<String>)) -> bool {
    let (single, phrase) = forms;
    if !single.is_empty() {
        return words.iter().any(|w| single.iter().any(|f| f == w));
    }
    let n = phrase.len();
    if n == 0 || words.len() < n {
        return false;
    }
    (0..=words.len() - n).any(|i| {
        phrase.iter().enumerate().all(|(j, p)| {
            let keep = p.chars().count().saturating_sub(1).max(2);
            let prefix: String = p.chars().take(keep).collect();
            words.get(i + j).is_some_and(|w| w.starts_with(&prefix))
        })
    })
}

fn cjk(c: char) -> bool {
    matches!(u32::from(c), 0x4E00..=0x9FFF | 0x3400..=0x4DBF | 0x3040..=0x30FF | 0xAC00..=0xD7AF | 0xF900..=0xFAFF)
}

/// Shares of letters that are CJK and Latin.
fn shares(s: &str) -> (f64, f64) {
    let (mut c, mut l, mut n) = (0u32, 0u32, 0u32);
    for ch in s.chars().take(400) {
        if cjk(ch) {
            c += 1;
            n += 1;
        } else if IPA.contains(ch) {
            n += 1;
        } else if ch.is_alphabetic() {
            n += 1;
            if u32::from(ch) < 0x250 {
                l += 1;
            }
        }
    }
    if n == 0 { (0.0, 0.0) } else { (f64::from(c) / f64::from(n), f64::from(l) / f64::from(n)) }
}

/// The role a table's sure mark gives before the generic rules run; `None` for a translation, whose kind (a sense's
/// or an example's) the generic rule decides.
fn sure_role(sure: profiles::Sure) -> Option<Role> {
    match sure {
        profiles::Sure::Pos => Some(Role::Pos),
        profiles::Sure::Sensenum => Some(Role::Sensenum),
        profiles::Sure::Example => Some(Role::Example),
        profiles::Sure::Heading => Some(Role::Heading),
        profiles::Sure::Subhead => Some(Role::Subhead),
        // A sense container is not a role: the sense pass reads it and writes `data-xdict-sense` (ADR-0029 d.2).
        profiles::Sure::Trans | profiles::Sure::Keep | profiles::Sure::Sense => None,
    }
}

/// Whether a table's sure mark speaks for the role written.
fn covers(sure: profiles::Sure, role: Role) -> bool {
    match sure {
        profiles::Sure::Trans => matches!(role, Role::Trans | Role::ExampleTrans),
        _ => sure_role(sure) == Some(role),
    }
}

/// A number, for a table's sense-number selector, which already says where numbers are: what [`sense_number`] takes,
/// a section number of up to three digits ("379"), a sub-sense ("1.1", "2.3."), or a Roman numeral sign ("Ⅱ").
fn numbered(t: &str) -> bool {
    let t = t.trim();
    if sense_number(t) {
        return true;
    }
    let body = t.strip_prefix('(').unwrap_or(t);
    let body = body.strip_suffix(')').unwrap_or(body);
    let body = body.strip_suffix('.').unwrap_or(body);
    if body.chars().count() == 1 && body.chars().all(|c| matches!(u32::from(c), 0x2160..=0x217F)) {
        return true;
    }
    !body.is_empty() && body.split('.').all(|p| (1..=3).contains(&p.len()) && p.bytes().all(|b| b.is_ascii_digit()))
}

fn sense_number(t: &str) -> bool {
    let body = t.strip_prefix('(').unwrap_or(t);
    let chars: Vec<char> = body.chars().collect();
    let suffix_ok = |rest: &[char]| match rest {
        [] => true,
        [a] => ".):、".contains(*a),
        [a, b] => ".):、".contains(*a) && *b == ')',
        _ => false,
    };
    let circled = |c: char| matches!(u32::from(c), 0x2460..=0x2473 | 0x2776..=0x277F | 0x24B6..=0x24E9);
    let cn = |c: char| "一二三四五六七八九十".contains(c);
    let roman = |c: char| "ivxIVX".contains(c);
    let mut prefixes: Vec<usize> = Vec::new();
    let digits = chars.iter().take_while(|c| c.is_ascii_digit()).count();
    for d in 1..=digits.min(2) {
        prefixes.push(d);
        if chars.get(d).is_some_and(|c| c.is_ascii_lowercase()) {
            prefixes.push(d + 1);
        }
    }
    let r = chars.iter().take_while(|c| roman(**c)).count();
    prefixes.extend(1..=r.min(5));
    if chars.first().is_some_and(|c| ('a'..='h').contains(c) || ('A'..='H').contains(c) || circled(*c)) {
        prefixes.push(1);
    }
    let k = chars.iter().take_while(|c| cn(**c)).count();
    prefixes.extend(1..=k.min(2));
    prefixes.into_iter().any(|p| chars.get(p..).is_some_and(suffix_ok))
}

fn label_kind(low: &str, t: &str, italic_or_small: bool) -> Option<&'static str> {
    let ws: Vec<String> = low
        .split(|c: char| c.is_whitespace() || ",/&;".contains(c))
        .filter(|w| !w.is_empty())
        .map(|w| w.trim_matches('.').to_owned())
        .collect();
    if ws.is_empty() || ws.len() > 3 {
        return None;
    }
    if ws.iter().all(|w| REGION.contains(&w.as_str())) {
        return Some("region");
    }
    let qual = ["often", "usually", "especially", "rather", "very", "slightly"];
    if ws.iter().all(|w| REGISTER.contains(&w.as_str()) || qual.contains(&w.as_str()))
        && ws.iter().any(|w| REGISTER.contains(&w.as_str()))
    {
        return Some("register");
    }
    if let [w] = ws.as_slice()
        && DOMAIN.contains(&w.as_str())
        && (italic_or_small || t.starts_with(['(', '[', '【', '〈']))
    {
        return Some("domain");
    }
    None
}

fn freq(t: &str) -> bool {
    let all_sym = !t.is_empty() && t.chars().all(|c| "★☆●○◆◇♦".contains(c));
    let sw = |s: &str| {
        let b = s.as_bytes();
        b.len() == 2 && matches!(b.first(), Some(b'S' | b'W')) && matches!(b.get(1), Some(b'1'..=b'3'))
    };
    let cefr = {
        let b = t.as_bytes();
        b.len() == 2 && matches!(b.first(), Some(b'A'..=b'C')) && matches!(b.get(1), Some(b'1' | b'2'))
    };
    let pair = {
        let parts: Vec<&str> = t.split([',', ' ']).filter(|p| !p.is_empty()).collect();
        parts.len() == 2 && parts.iter().all(|p| sw(p))
    };
    all_sym || sw(t) || cefr || pair
}

fn gram(t: &str) -> bool {
    let s = t.trim().trim_start_matches('[').trim_end_matches(']').trim();
    let low = s.to_ascii_lowercase();
    let letters = !s.is_empty()
        && s.split(',').all(|p| {
            let p = p.trim();
            p.len() == 1 && "CUTIL".contains(p)
        });
    let verb = ["v", "vn", "v-ing", "v-to", "vn-to", "vn-ing", "v-that", "vnn", "vnp", "vnadj"].contains(&low.as_str())
        && s.starts_with('V');
    let phrases = [
        "usually passive",
        "usually singular",
        "usually plural",
        "plural",
        "singular",
        "uncountable",
        "countable",
        "transitive",
        "intransitive",
        "only before noun",
        "not before noun",
        "no passive",
        "often passive",
        "not usually before noun",
        "usually before noun",
        "after noun",
        "c usually singular",
        "u usually singular",
    ];
    letters || verb || s.starts_with('+') || phrases.contains(&low.as_str())
}

fn heading_kind(low: &str) -> Option<&'static str> {
    if let Some((_, k)) = HEADINGS.iter().find(|(w, _)| *w == low) {
        return Some(k);
    }
    HEADINGS
        .iter()
        .find(|(w, _)| {
            w.chars().count() >= 5 && low.starts_with(&format!("{w} ")) && low.chars().count() <= w.chars().count() + 25
        })
        .map(|(_, k)| *k)
}

fn ipa_like(t: &str) -> bool {
    if t.is_empty() || t.chars().count() > 80 {
        return false;
    }
    let letters = t.chars().filter(|c| c.is_alphabetic() || IPA.contains(*c)).count();
    let strong = t.chars().filter(|c| STRONG_IPA.contains(*c)).count();
    let first = t.chars().next().unwrap_or(' ');
    let last = t.chars().last().unwrap_or(' ');
    let delimited = t.chars().count() >= 3
        && "/[\\|(".contains(first)
        && "/]\\|)".contains(last)
        && t.chars().nth(1).is_some_and(|c| !c.is_whitespace() || t.chars().skip(1).any(|c| !c.is_whitespace()));
    letters > 0 && strong >= 1 && (strong as f64 / letters as f64 >= 0.12 || delimited)
}

/// The tree as the rules read it.
struct Tree<'n> {
    nodes: &'n [Node],
    buf: &'n str,
    feat: Vec<Feat>,
    /// The markup's part-of-speech selector holds other labels too: its elements need the part-of-speech words.
    pos_words: bool,
    /// The markup's examples hold their text in blocks: an element of the selector with text of its own is not one.
    example_blocks: bool,
}

impl<'n> Tree<'n> {
    fn new(nodes: &'n [Node], buf: &'n str, key: Option<&str>, pos_words: bool, example_blocks: bool) -> Self {
        let key_norm = key.map(norm_key).unwrap_or_default();
        let forms = key.map(key_forms).unwrap_or_default();
        let mut order = 0u32;
        let mut feat = Vec::with_capacity(nodes.len());
        for node in nodes {
            let raw = buf.get(node.text.0 as usize..node.text.1 as usize).unwrap_or("");
            let mut t = String::new();
            for w in raw.chars().take(TEXT_CHARS).collect::<String>().split_whitespace() {
                if !t.is_empty() {
                    t.push(' ');
                }
                t.push_str(w);
            }
            let len = t.chars().count();
            let lower = t.to_lowercase();
            let words = words_of(&lower);
            let (c, l) = shares(&t);
            if node.direct {
                order += 1;
            }
            let head: String = lower.chars().take(200).collect();
            let starts_cap = {
                let s = t.trim_start_matches(['"', '\'', '‘', '“', '(']);
                s.starts_with(|c: char| c.is_ascii_uppercase())
            };
            let ends_punct = {
                let s = t.trim_end_matches(['\'', '"', '’', '”']);
                s.ends_with(['.', '!', '?', '。', '！', '？'])
            };
            let short = (len <= SHORT_CHARS).then(|| t.clone());
            feat.push(Feat {
                is_key: short.as_deref().is_some_and(|s| !s.is_empty() && is_key(s, &key_norm)),
                short,
                len,
                words: words.len() as u32,
                cjk: c,
                lat: l,
                keyform: has_form(&words, &forms),
                caps: !t.is_empty() && t.to_uppercase() == t && t.chars().any(char::is_alphabetic) && c == 0.0,
                starts_cap,
                ends_punct,
                footer: head.contains('©')
                    || copyright_year(&head)
                    || head.contains("all rights reserved")
                    || head.contains("版权所有")
                    || head.contains("版權"),
                order,
            });
        }
        Self { nodes, buf, feat, pos_words, example_blocks }
    }

    /// The role the markup's table makes sure for the element, once its text passes the role's check: a part of
    /// speech is 1–40 characters (and a part-of-speech word where the table asks); a sense number is a number.
    fn sure(&self, i: usize) -> Option<profiles::Sure> {
        let node = self.nodes.get(i)?;
        let Some(sure) = node.profiled else {
            // A block inside a sure example whose text is Chinese with no Latin letter is its translation (COBUILD's
            // unclassed `<p>` after the English one).
            let f = self.feat.get(i)?;
            let block = matches!(&*node.name, "p" | "div");
            return (block && f.cjk > 0.0 && f.lat == 0.0 && self.in_example(i)).then_some(profiles::Sure::Trans);
        };
        if sure == profiles::Sure::Keep {
            return self.in_example(i).then_some(sure);
        }
        let f = self.feat.get(i)?;
        let t = f.short.as_deref().unwrap_or("");
        let ok = match sure {
            profiles::Sure::Pos => f.len > 0 && f.len <= 40 && (!self.pos_words || pos_text(t)),
            profiles::Sure::Sensenum => numbered(t),
            profiles::Sure::Example => f.len > 0 && !(self.example_blocks && node.direct),
            profiles::Sure::Trans => f.len > 0,
            profiles::Sure::Heading => f.len > 0 && f.len <= 120,
            profiles::Sure::Subhead => f.len > 0 && f.len <= 120,
            profiles::Sure::Keep => false,
            profiles::Sure::Sense => f.len > 0,
        };
        ok.then_some(sure)
    }

    /// Whether an element is inside an element the table makes a sure example.
    fn in_example(&self, i: usize) -> bool {
        let mut at = self.nodes.get(i).map(|n| n.parent as usize);
        for _ in 0..MAX_DEPTH {
            let Some(p) = at.filter(|p| *p != ROOT as usize) else { return false };
            if self.nodes.get(p).and_then(|n| n.profiled) == Some(profiles::Sure::Example)
                && self.feat.get(p).is_some_and(|f| f.len > 0)
            {
                return true;
            }
            at = self.nodes.get(p).map(|n| n.parent as usize);
        }
        false
    }

    /// An element's whole text, spaces collapsed, when it is no longer than the rules read.
    fn whole(&self, i: usize) -> Option<String> {
        let n = self.nodes.get(i)?;
        let raw = self.buf.get(n.text.0 as usize..n.text.1 as usize)?;
        if raw.chars().nth(TEXT_CHARS).is_some() {
            return None;
        }
        Some(raw.split_whitespace().collect::<Vec<_>>().join(" "))
    }

    fn f(&self, i: usize) -> &Feat {
        static EMPTY: std::sync::OnceLock<Feat> = std::sync::OnceLock::new();
        self.feat.get(i).unwrap_or_else(|| EMPTY.get_or_init(Feat::default))
    }

    fn node(&self, i: usize) -> Option<&Node> {
        self.nodes.get(i)
    }

    fn el_kids(&self, i: usize) -> impl Iterator<Item = usize> + '_ {
        self.node(i).map(|n| n.kids.as_slice()).unwrap_or(&[]).iter().filter_map(|k| match k {
            Kid::El(c) => Some(*c as usize),
            Kid::Text { .. } => None,
        })
    }

    /// The element right before or after `i` among its siblings, whatever text lies between: a sense run covers the
    /// text, so only an element can end it.
    fn sibling_element(&self, i: usize, forward: bool) -> Option<usize> {
        let n = self.node(i)?;
        let p = self.node(n.parent as usize)?;
        let mut k = n.pos as usize;
        loop {
            k = if forward { k.checked_add(1)? } else { k.checked_sub(1)? };
            if let Kid::El(c) = p.kids.get(k)? {
                return Some(*c as usize);
            }
        }
    }

    /// The element right before or after `i` among its siblings, spaces skipped; text in between ends the search.
    fn sibling(&self, i: usize, forward: bool) -> Option<usize> {
        let n = self.node(i)?;
        let p = self.node(n.parent as usize)?;
        let pos = n.pos as usize;
        let mut k = pos;
        loop {
            k = if forward { k.checked_add(1)? } else { k.checked_sub(1)? };
            match p.kids.get(k)? {
                Kid::Text { blank: true, .. } => {}
                Kid::Text { .. } => return None,
                Kid::El(c) => return Some(*c as usize),
            }
        }
    }

    /// The roles the generic rules assign, in the sweep's order (`detect.py`'s passes).
    fn assign(&self) -> Vec<Option<Role>> {
        let n = self.nodes.len();
        let mut r = Roles2 { roles: vec![None; n], desc: vec![0u32; n], nodes: self.nodes };
        let f = |i: usize| self.f(i);
        let parent = |i: usize| self.node(i).map_or(ROOT as usize, |x| x.parent as usize);
        let ancestors = |i: usize| {
            let mut out = Vec::new();
            let mut p = parent(i);
            while p != ROOT as usize && out.len() < MAX_DEPTH {
                out.push(p);
                p = parent(p);
            }
            out
        };
        // Subtree sizes (nodes are in document order, so a subtree is a run).
        let mut size = vec![1usize; n];
        for i in (1..n).rev() {
            let p = parent(i);
            let s = size.get(i).copied().unwrap_or(1);
            if let Some(x) = size.get_mut(p) {
                *x += s;
            }
        }
        // What leads each element's block, the first long child, the first two children with text, links below.
        let mut lead = vec![usize::MAX; n];
        let mut first_long = vec![usize::MAX; n];
        let mut two: Vec<[usize; 2]> = vec![[usize::MAX; 2]; n];
        for (i, node) in self.nodes.iter().enumerate() {
            let mut textual = 0;
            for (k, kid) in node.kids.iter().enumerate() {
                let (has, words) = match kid {
                    Kid::Text { words, blank } => (!blank, *words),
                    Kid::El(c) => (f(*c as usize).len > 0, f(*c as usize).words),
                };
                if has
                    && lead.get(i) == Some(&usize::MAX)
                    && let Some(x) = lead.get_mut(i)
                {
                    *x = k;
                }
                if words > 3
                    && first_long.get(i) == Some(&usize::MAX)
                    && let Some(x) = first_long.get_mut(i)
                {
                    *x = k;
                }
                if let Kid::El(c) = kid
                    && f(*c as usize).len > 0
                    && textual < 2
                {
                    if let Some(t) = two.get_mut(i).and_then(|t| t.get_mut(textual)) {
                        *t = *c as usize;
                    }
                    textual += 1;
                }
            }
        }
        let leads = |i: usize| {
            let Some(node) = self.node(i) else { return false };
            lead.get(node.parent as usize).copied() == Some(node.pos as usize)
        };
        let mut lookup_below = vec![false; n];
        let mut anchors = vec![(0u32, 0usize); n];
        for i in (1..n).rev() {
            let p = parent(i);
            let me = self.node(i).map(|x| x.link);
            let below = lookup_below.get(i).copied().unwrap_or(false) || me == Some(Lk::Lookup);
            if let Some(x) = lookup_below.get_mut(p) {
                *x |= below;
            }
            let (c, l) = anchors.get(i).copied().unwrap_or((0, 0));
            let (c, l) = if me == Some(Lk::Anchor) { (c + 1, l + f(i).len) } else { (c, l) };
            if let Some(x) = anchors.get_mut(p) {
                x.0 += c;
                x.1 += l;
            }
        }
        let root_text = self.el_kids(ROOT as usize).map(|c| f(c).len).sum::<usize>().max(1);
        let hidden = |i: usize| self.node(i).is_some_and(|x| x.flags.hidden);
        let name = |i: usize| self.node(i).map_or("", |x| &*x.name);
        let link = |i: usize| self.node(i).map_or(Lk::None, |x| x.link);
        let short = |i: usize| f(i).short.as_deref().unwrap_or("");
        let audio = |i: usize| self.node(i).is_some_and(|x| x.audio_attr || (x.pathy && f(i).len == 0));

        // 0. the markup's own roles (`profiles`), before any generic rule can take the element. In a link too: LDOCE's
        // word lists and YHDCD's senses write their parts of speech inside one (the holdout labels them so).
        for i in 1..n {
            if let Some(role) = self.sure(i).and_then(sure_role) {
                r.mark(i, role);
            }
        }
        // 1. audio
        let mut covered = 0usize;
        for i in 1..n {
            let Some(node) = self.node(i) else { continue };
            if node.link == Lk::Sound || &*node.name == "audio" || audio(i) {
                r.mark(i, Role::Audio);
                if i >= covered {
                    let end = i + size.get(i).copied().unwrap_or(1);
                    for c in i + 1..end.min(n) {
                        if f(c).len == 0 || name(c) == "img" {
                            r.mark(c, Role::Audio);
                        }
                    }
                    covered = end;
                }
            }
        }
        // 1b. folding controls
        for i in 1..n {
            let Some(node) = self.node(i) else { continue };
            if r.has(i) {
                continue;
            }
            let d = f(i);
            let short_text = d.words <= 3 && d.len <= 24;
            let low = short(i).to_lowercase();
            let s = low.trim_start_matches(['[', '(']).trim_start();
            let fold_text = d.len > 0
                && (s.starts_with(['+', '-', '−', '▶', '▼', '►', '▸', '▾', '▲', '△', '▽'])
                    || ["more", "less", "show", "hide", "expand", "collapse"].iter().any(|w| s.starts_with(w)));
            let handled = node.handled && !audio(i);
            let next_hidden = self.sibling(i, true).is_some_and(hidden);
            if &*node.name == "summary"
                || (handled && node.folds && (short_text || fold_text || &*node.name == "img"))
                || (&*node.name == "img" && handled)
                || (d.len == 0 && node.drawn && next_hidden)
            {
                r.mark(i, Role::Fold);
            }
        }
        // 1c. content images
        for i in 1..n {
            if self.node(i).is_some_and(|x| x.image) {
                r.mark(i, Role::Image);
            }
        }
        // 2. headword
        let mut first = None;
        for i in 1..n {
            let d = f(i);
            if d.order > 60 {
                break;
            }
            if d.len > 0 && d.len <= 80 && d.is_key && link(i) != Lk::Lookup && !hidden(i) {
                first = Some(i);
                break;
            }
        }
        if let Some(first) = first {
            let sig = self.node(first).map_or(0, |x| x.sig);
            for i in 1..n {
                let d = f(i);
                let Some(node) = self.node(i) else { continue };
                if d.len == 0 || node.link == Lk::Lookup || !d.is_key {
                    continue;
                }
                let headlike = node.flags.bold
                    || matches!(&*node.name, "h1" | "h2" | "h3" | "h4" | "font" | "big")
                    || node.big_font;
                let inner = self.el_kids(i).all(|c| !(f(c).len as f64 >= 0.9 * d.len as f64 && f(c).is_key));
                if i == first || node.sig == sig || (d.order <= 60 && headlike && inner) {
                    r.mark(i, Role::Headword);
                }
            }
        }
        let is_hw = |r: &Roles2<'_>, i: usize| r.role(i) == Some(Role::Headword);
        // 3. homograph
        for i in 1..n {
            let Some(node) = self.node(i) else { continue };
            let t = short(i);
            let digits = !t.is_empty()
                && t.chars().count() <= 2
                && t.chars().all(|c| c.is_ascii_digit() || "¹²³⁴⁵⁶⁷⁸⁹".contains(c));
            if !digits {
                continue;
            }
            if !(node.flags.sup || &*node.name == "sup" || node.hom) {
                continue;
            }
            let near =
                ancestors(i).iter().any(|a| is_hw(&r, *a)) || self.sibling(i, false).is_some_and(|p| is_hw(&r, p));
            if near {
                r.mark(i, Role::Homograph);
            }
        }
        // 4. pronunciation: innermost IPA-shaped text
        for i in (1..n).rev() {
            if r.has(i) || !ipa_like(short(i)) || r.below(i, &[Role::Pron]) {
                continue;
            }
            r.mark(i, Role::Pron);
        }
        // 5. sense numbers
        for i in 1..n {
            let Some(node) = self.node(i) else { continue };
            let t = short(i);
            if t.is_empty() || r.has(i) || &*node.name == "sup" || node.flags.sup || !sense_number(t) {
                continue;
            }
            let lead_ok = {
                let s = t.strip_prefix('(').unwrap_or(t);
                s.starts_with(|c: char| {
                    c.is_ascii_digit()
                        || matches!(u32::from(c), 0x2460..=0x2473 | 0x2776..=0x277F | 0x24B6..=0x24E9)
                        || "一二三四五六七八九十".contains(c)
                })
            } || t.ends_with(['.', ')', ':', '、'])
                || t.starts_with('(')
                || node.flags.bold;
            if lead_ok && self.el_kids(i).count() <= 1 && node.link == Lk::None && !matches!(&*node.name, "td" | "th") {
                r.mark(i, Role::Sensenum);
            }
        }
        // 6. part of speech, grammar codes, labels
        for i in 1..n {
            let Some(node) = self.node(i) else { continue };
            let d = f(i);
            let t = short(i);
            if t.is_empty() || r.has(i) || d.len > 40 {
                continue;
            }
            let lower = t.to_lowercase();
            let low = lower.trim_matches(|c: char| " .,;:()[]{}".contains(c));
            // An element the markup's table names was decided in pass 0, whichever way.
            if pos_text(t)
                && node.profiled != Some(profiles::Sure::Pos)
                && node.link != Lk::Lookup
                && !(d.caps && t.chars().count() > 3 && leads(i) && d.order > 12 && node.flags.bold)
            {
                r.mark(i, Role::Pos);
                continue;
            }
            if gram(t) {
                r.mark(i, Role::Gram);
                continue;
            }
            if let Some(kind) = label_kind(low, t, node.flags.italic || node.flags.small) {
                r.mark(i, Role::Label(kind));
                continue;
            }
            if freq(t) {
                r.mark(i, Role::Label("freq"));
            }
        }
        // 7. examples
        for i in (1..n).rev() {
            if r.has(i) {
                continue;
            }
            let Some(node) = self.node(i) else { continue };
            let d = f(i);
            if d.len == 0 || d.words < 3 || d.lat < 0.8 || d.len > 500 || node.flags.bold || node.link == Lk::Lookup {
                continue;
            }
            let sentence = d.starts_cap || d.ends_punct;
            let cjk_next = self.sibling(i, true).is_some_and(|x| f(x).cjk >= 0.5);
            let like = node.flags.italic || (d.keyform && sentence) || (cjk_next && sentence && d.keyform);
            if !like || r.below(i, &[Role::Example, Role::Sensenum, Role::Def]) {
                continue;
            }
            r.mark(i, Role::Example);
        }
        // 8. translations
        for i in (1..n).rev() {
            let d = f(i);
            if r.has(i) || d.len == 0 || d.cjk < 0.5 {
                continue;
            }
            if r.below(i, &[Role::Trans, Role::ExampleTrans, Role::Example]) {
                continue;
            }
            let prev = self.sibling(i, false);
            let prev_sentence = prev.is_some_and(|p| {
                let e = f(p);
                e.lat >= 0.8 && e.words >= 3 && (e.ends_punct || e.keyform) && r.role(p) != Some(Role::Def)
            });
            let in_example = ancestors(i).iter().any(|a| r.role(*a) == Some(Role::Example));
            let after_example = prev.is_some_and(|p| r.role(p) == Some(Role::Example) || r.below(p, &[Role::Example]));
            r.mark(i, if in_example || after_example || prev_sentence { Role::ExampleTrans } else { Role::Trans });
        }
        // 9. definitions (not written: they are the frame's body text, but other rules read them)
        for i in (1..n).rev() {
            let Some(node) = self.node(i) else { continue };
            let d = f(i);
            if r.has(i)
                || d.len == 0
                || d.words < 3
                || d.lat < 0.75
                || node.flags.italic
                || node.flags.bold
                || node.link != Lk::None
            {
                continue;
            }
            let below = [Role::Def, Role::Example, Role::Sensenum, Role::Pron, Role::Headword, Role::Trans];
            if r.below(i, &below) || ancestors(i).iter().any(|a| matches!(r.role(*a), Some(Role::Example | Role::Def)))
            {
                continue;
            }
            let first_ok = first_long.get(node.parent as usize).copied().unwrap_or(usize::MAX) >= node.pos as usize;
            let heading_like = d.words <= 4 && (d.caps || node.flags.bold);
            if first_ok && !heading_like {
                r.mark(i, Role::Def);
            }
        }
        // 10. senses
        for i in 1..n {
            if r.role(i) != Some(Role::Sensenum) {
                continue;
            }
            let p = parent(i);
            if p == ROOT as usize || r.has(p) || f(p).len as f64 >= 0.8 * root_text as f64 {
                continue;
            }
            if two.get(p).is_some_and(|t| t.contains(&i)) {
                r.mark(p, Role::Sense);
            }
        }
        for i in 1..n {
            if name(i) == "li" && !r.has(i) && name(parent(i)) == "ol" && r.below(i, &[Role::Def]) {
                r.mark(i, Role::Sense);
            }
        }
        // 11. example lists
        for i in 1..n {
            if r.has(i) {
                continue;
            }
            let tk: Vec<usize> = self.el_kids(i).filter(|c| f(*c).len > 0).collect();
            if tk.len() < 2 {
                continue;
            }
            let ex = tk
                .iter()
                .filter(|c| {
                    r.role(**c) == Some(Role::Example)
                        || (name(**c) == "li" && self.el_kids(**c).any(|x| r.role(x) == Some(Role::Example)))
                })
                .count();
            if ex as f64 >= 0.6 * tk.len() as f64 {
                r.mark(i, Role::Examples);
            }
        }
        // 12. sub-entry heads, sense guides, headings and their sections
        for i in 1..n {
            let Some(node) = self.node(i) else { continue };
            let d = f(i);
            let t = short(i);
            // A heading a markup's table names opens an etymology as a generic one does (parity P25): its block is
            // the section. Only the etymology: the other kinds keep the spacing the tables' headings have had.
            if self.sure(i) == Some(profiles::Sure::Heading) && r.role(i) == Some(Role::Heading) {
                let lower = t.to_lowercase();
                let low = lower.trim_end_matches(|c: char| c.is_whitespace() || ":：.".contains(c));
                let blk = parent(i);
                if heading_kind(low) == Some("etym")
                    && blk != ROOT as usize
                    && !r.has(blk)
                    && (f(blk).len as f64) < 0.9 * root_text as f64
                {
                    r.mark(blk, Role::Section("etym"));
                }
                continue;
            }
            if t.is_empty() || r.has(i) || d.len > 60 || d.words > 8 || !leads(i) {
                continue;
            }
            let below = [Role::Headword, Role::Pron, Role::Sensenum, Role::Pos, Role::Example, Role::Def, Role::Audio];
            if r.below(i, &below) {
                continue;
            }
            let lower = t.to_lowercase();
            let low = lower.trim_end_matches(|c: char| c.is_whitespace() || ":：.".contains(c));
            let kind = heading_kind(low);
            if node.link != Lk::None || lookup_below.get(i).copied().unwrap_or(false) {
                continue;
            }
            let styled_head = matches!(&*node.name, "h1" | "h2" | "h3" | "h4" | "h5" | "h6")
                || ((d.caps || node.flags.small) && node.flags.bold);
            if kind.is_none() && d.keyform && node.flags.bold && !d.ends_punct && d.words >= 2 {
                r.mark(i, Role::Subhead);
                continue;
            }
            if kind.is_some() || (styled_head && d.words <= 5) {
                let blk = parent(i);
                let in_sense = r.below(blk, &[Role::Def, Role::Sensenum]);
                if kind.is_none() && (d.caps || node.flags.small) && in_sense && d.words <= 3 {
                    r.mark(i, Role::Guide);
                    continue;
                }
                if kind.is_none() && (!styled_head || d.keyform) {
                    continue;
                }
                r.mark(i, Role::Heading);
                if blk != ROOT as usize && !r.has(blk) && (f(blk).len as f64) < 0.9 * root_text as f64 {
                    r.mark(blk, Role::Section(kind.unwrap_or("other")));
                }
            }
        }
        // 16. website chrome (the owner's Q5: the frame hides it): a short run of in-page links that holds nothing
        // the entry is made of, and a copyright line. The sweep's run-of-links rule alone (precision 0.03 there,
        // 0.02 here) took whole sense blocks for navigation, so what it may hide is held to this.
        let content = [Role::Headword, Role::Sensenum, Role::Def, Role::Example, Role::Pron, Role::Trans, Role::Sense];
        for i in 1..n {
            let (count, text) = anchors.get(i).copied().unwrap_or((0, 0));
            let d = f(i);
            if count >= 3
                && !r.has(i)
                && d.len > 0
                && d.len <= CHROME_CHARS
                && text as f64 >= 0.8 * d.len as f64
                && !r.below(i, &content)
            {
                r.mark(i, Role::Chrome);
            }
        }
        for i in 1..n {
            let d = f(i);
            let quiet = link(i) == Lk::None && !r.below(i, &content);
            if d.len > 0 && d.footer && d.len < 300 && quiet && !r.has(i) && !self.el_kids(i).any(|c| f(c).footer) {
                r.mark(i, Role::Chrome);
            }
        }
        // 17. the entry: the highest ancestor of a headword holding no other headword
        let mut hw_below = vec![0u32; n];
        for i in (1..n).rev() {
            let me = u32::from(r.role(i) == Some(Role::Headword));
            let below = hw_below.get(i).copied().unwrap_or(0);
            if let Some(x) = hw_below.get_mut(parent(i)) {
                *x += below + me;
            }
        }
        for h in 1..n {
            if r.role(h) != Some(Role::Headword) {
                continue;
            }
            let mut top = None;
            for a in ancestors(h) {
                if hw_below.get(a).copied().unwrap_or(0) > 1 {
                    break;
                }
                top = Some(a);
            }
            if let Some(top) = top
                && !r.has(top)
                && f(top).len > 2 * f(h).len
            {
                r.mark(top, Role::Entry);
            }
        }
        // 19. separators and hidden marks inside a fold belong to it (the rest are decoration, which has no role).
        for i in 1..n {
            let Some(node) = self.node(i) else { continue };
            let t = short(i);
            if r.has(i) || t.is_empty() {
                continue;
            }
            let separator = t.chars().count() <= 3 && t.chars().all(|c| SEPARATORS.contains(c) || c.is_whitespace());
            let hidden_mark = node.flags.hidden && t.chars().count() <= 2 && self.el_kids(i).next().is_none();
            if (separator || hidden_mark) && ancestors(i).iter().any(|a| r.role(*a) == Some(Role::Fold)) {
                r.mark(i, Role::Fold);
            }
        }
        r.roles
    }
}

/// An element the browser lays out as a block by default: punctuation after it would start a line of its own.
/// **The senses the entry's markup names** (ADR-0029 d.2): per node, the sense run it belongs to, the first element of
/// a run and its printed label and parent, and the element that begins after a run. `Role::Sense`, a markup table's
/// sense selector, a sense number and a block that opens with a printed label all start one; where an entry names no
/// sense at all, its first definition block is the sense. **No role is changed**: the reading style is untouched.
#[derive(Default)]
struct SenseMap {
    ids: Vec<Option<u32>>,
    labels: Vec<Option<String>>,
    parents: Vec<Option<u32>>,
    starts: Vec<bool>,
    ends: Vec<bool>,
    /// The start's run continues into its following siblings: it ends with its parent, not with its own element.
    runs: Vec<bool>,
}

impl Tree<'_> {
    /// The sense runs, numbered in document order.
    fn senses(&self, roles: &[Option<Role>]) -> SenseMap {
        let n = self.nodes.len();
        let mut map = SenseMap {
            ids: vec![None; n],
            labels: vec![None; n],
            parents: vec![None; n],
            starts: vec![false; n],
            ends: vec![false; n],
            runs: vec![false; n],
        };
        if n < 2 {
            return map;
        }
        let role = |i: usize| roles.get(i).copied().flatten();
        // 0. Which elements sit in a section that is not a definition's (idioms, etymology, a thesaurus): computed
        // once, in one pass — the check used to walk every ancestor's children per element, which is quadratic on a
        // deeply nested entry and failed the icons' linearity test.
        let other_sections = self.other_sections(roles);
        // **Exclusion follows a wrapper too**: a node whose prose is all in excluded children is itself excluded, so
        // the fallback cannot carry that prose into a sense.
        let content_excluded = self.content_excluded(&other_sections);
        // 1. Where a sense may start, in document order, and whether its run reaches into its siblings.
        let mut starts: Vec<(usize, Option<String>, bool, bool)> = Vec::new();
        for i in 1..n {
            // A hidden element is not on the page: it cannot be a target.
            if self.node(i).is_some_and(|n| n.flags.hidden) {
                continue;
            }
            if other_sections.get(i).copied().unwrap_or(false) {
                continue;
            }
            let profiled = self.sure(i) == Some(profiles::Sure::Sense);
            // **A header's run reaches past its element** (COBUILD's caption, OALD's single-sense `span.def`); a
            // container holds its whole sense.
            let header = self.node(i).is_some_and(|n| n.sense_header);
            let container = role(i) == Some(Role::Sense);
            let sensenum = role(i) == Some(Role::Sensenum);
            if profiled || container {
                let (label, sub) = self.sense_label(i, roles).map_or((None, false), |(l, s)| (Some(l), s));
                // **A wrapper is not a container**: one holding two or more *primary* numbers holds several senses.
                if container && !profiled && self.primary_labels_inside(i, roles) >= 2 {
                    continue;
                }
                // A label-less container is a sense only when it reads as a definition: a "Trends of …" block is not.
                if label.is_none() && !profiled && !self.definition_like(i, roles) {
                    continue;
                }
                starts.push((i, label, sub, profiled && header));
            } else if sensenum {
                // A sense number is a number: a countability mark ("C") is not one.
                let Some((label, sub)) = self.sense_label(i, roles) else { continue };
                starts.push((i, Some(label), sub, true));
            } else if let Some((label, sub)) = self.pattern_start(i, roles) {
                starts.push((i, Some(label), sub, true));
            }
        }
        // **A markup numbered only in brackets, circles or Roman numerals** (a dictionary whose top level is `(1)`,
        // `②`, `ii.`): none of those is a sub-label when no plain number exists to be shallow, and left as sub-labels
        // they would trigger the unnumbered fallback and invent a parent. The rank rule is `primary_labels_inside`'s
        // (audit finding, 2026-10-23).
        if !starts.iter().any(|(_, _, sub, _)| !*sub) {
            let shallowest = starts.iter().filter_map(|(_, label, _, _)| label.as_deref()).map(label_rank).min();
            if shallowest == Some(1) {
                for (_, label, sub, _) in &mut starts {
                    if label.as_deref().is_some_and(|l| label_rank(l) == 1) {
                        *sub = false;
                    }
                }
            }
        }
        let mut primary_at = vec![false; n];
        for (node, _, sub, _) in &starts {
            if !sub && let Some(slot) = primary_at.get_mut(*node) {
                *slot = true;
            }
        }
        // **A sub-label with no numbered sense above it** (NOAD's `■`, a lettered entry): the entry's first definition
        // block is its first sense, and the label's block is a sense after it.
        if !primary_at.iter().any(|p| *p)
            && let Some(i) = self.first_definition(roles, &content_excluded)
        {
            starts.push((i, None, false, true));
            starts.sort_by_key(|(node, _, _, _)| *node);
            if let Some(slot) = primary_at.get_mut(i) {
                *slot = true;
            }
        }
        // 2. Which subtrees hold a primary start: a wrapper holding one ends the run before it.
        let mut contains = primary_at.clone();
        for i in (1..n).rev() {
            let p = self.node(i).map_or(ROOT as usize, |x| x.parent as usize);
            if contains.get(i).copied().unwrap_or(false)
                && let Some(slot) = contains.get_mut(p)
            {
                *slot = true;
            }
        }
        let mut start_flags = vec![false; n];
        for (node, _, _, _) in &starts {
            if let Some(slot) = start_flags.get_mut(*node) {
                *slot = true;
            }
        }
        let start_at = |i: usize| start_flags.get(i).copied().unwrap_or(false);
        // 3. The runs.
        let mut next = 1u32;
        // The last primary sense started: a sub-label with no enclosing sense belongs to it (ODE's `1.1` sits inside
        // a wrapper beside `1`, not inside `1`'s element; NOAD's `■` follows `1)` as a sibling).
        let mut last_primary: Option<u32> = None;
        // Where each id's run starts, so a parent relationship can be checked against the elements, not assumed.
        let mut start_node: Vec<usize> = Vec::new();
        for (node, label, mut sub, runs) in starts {
            // **Inside a sense already started**: the same sense, not a second one (its own sub-labels excepted).
            let mut inside = false;
            let mut at = self.node(node).map_or(ROOT as usize, |x| x.parent as usize);
            for _ in 0..MAX_DEPTH {
                if at == ROOT as usize {
                    break;
                }
                if map.starts.get(at).copied().unwrap_or(false) || map.ids.get(at).copied().flatten().is_some() {
                    inside = true;
                    break;
                }
                at = self.node(at).map_or(ROOT as usize, |x| x.parent as usize);
            }
            if inside && !sub {
                continue;
            }
            // **The number that named its container is not a second sense**: a sub-label equal to the enclosing
            // sense's own label is the same label read once.
            if inside && sub {
                let mut at = self.node(node).map_or(ROOT as usize, |x| x.parent as usize);
                for _ in 0..MAX_DEPTH {
                    if at == ROOT as usize {
                        break;
                    }
                    if map.starts.get(at).copied().unwrap_or(false) {
                        let outer = map.labels.get(at).and_then(|l| l.as_deref());
                        if outer.is_some() && outer == label.as_deref() {
                            inside = false;
                        }
                        break;
                    }
                    at = self.node(at).map_or(ROOT as usize, |x| x.parent as usize);
                }
                if !inside {
                    continue;
                }
            }
            // The parent: a self-scoped sense's element that encloses this one, else (a sub-label) the primary
            // sibling before it. A run head's element is not a parent: the next sense is not inside it.
            let mut parent = None;
            let mut at = self.node(node).map_or(ROOT as usize, |x| x.parent as usize);
            for _ in 0..MAX_DEPTH {
                if at == ROOT as usize {
                    break;
                }
                if map.starts.get(at).copied().unwrap_or(false) && !map.runs.get(at).copied().unwrap_or(false) {
                    parent = map.ids.get(at).copied().flatten();
                    break;
                }
                at = self.node(at).map_or(ROOT as usize, |x| x.parent as usize);
            }
            if parent.is_none()
                && sub
                && let Some(id) = last_primary
                && let Some(start) = start_node.get(id as usize - 1).copied()
            {
                // **A sub-label belongs to the primary sense it follows** when that sense's element encloses it or its
                // run's scope does; a self-contained parent whose element has closed cannot own a later block, and a
                // run scoped to an earlier paragraph cannot reach one in a later paragraph (audit and verification
                // findings, 2026-10-22/23). Otherwise the label is a sense of its own, not a child outside its parent.
                let reaches = self.descends_from(node, start)
                    || (map.runs.get(start).copied().unwrap_or(false)
                        && self.node(start).is_some_and(|n| self.descends_from(node, n.parent as usize)));
                if reaches {
                    parent = Some(id);
                }
            }
            if sub && parent.is_none() {
                sub = false;
            }
            let id = next;
            next += 1;
            if start_node.len() < id as usize {
                start_node.resize(id as usize, usize::MAX);
            }
            if let Some(slot) = start_node.get_mut(id as usize - 1) {
                *slot = node;
            }
            if !sub {
                last_primary = Some(id);
            }
            if let Some(slot) = map.ids.get_mut(node) {
                *slot = Some(id);
            }
            if let Some(slot) = map.starts.get_mut(node) {
                *slot = true;
            }
            if let Some(slot) = map.labels.get_mut(node) {
                *slot = label;
            }
            if let Some(slot) = map.parents.get_mut(node) {
                *slot = parent;
            }
            if let Some(slot) = map.runs.get_mut(node) {
                *slot = runs;
            }
            // **A run head reaches into its following siblings** (the definition and examples after a number); a
            // container holds its own. A sub-label's start inside a primary run is included there and takes over.
            if !runs {
                continue;
            }
            let mut current = node;
            for _ in 0..MAX_NODES {
                // **Text between elements belongs to the run**: the next *element* is what can end it.
                let Some(sib) = self.sibling_element(current, true) else { break };
                // A separator written as bare text between two elements ("• • •") ends the run at the element after it.
                if let (Some(a), Some(b)) =
                    (self.node(current).map(|n| n.text.1 as usize), self.node(sib).map(|n| n.text.0 as usize))
                    && let Some(between) = self.buf.get(a..b)
                {
                    let between = between.trim();
                    if !between.is_empty()
                        && between.chars().count() <= 12
                        && between.chars().all(|c| "•·.…-—* \n\t".contains(c))
                    {
                        if let Some(slot) = map.ends.get_mut(sib) {
                            *slot = true;
                        }
                        break;
                    }
                }
                if map.ids.get(sib).copied().flatten().is_some_and(|own| own != id) {
                    break;
                }
                // **A separator ends the sense**: a line of dots or bullets ("• • •") divides the entry's blocks.
                if let Some(text) = self.whole(sib) {
                    let text = text.trim();
                    if !text.is_empty() && text.chars().count() <= 12 && text.chars().all(|c| "•·.…-—* ".contains(c))
                    {
                        if let Some(slot) = map.ends.get_mut(sib) {
                            *slot = true;
                        }
                        break;
                    }
                }
                if role(sib)
                    .is_some_and(|r| matches!(r, Role::Heading | Role::Subhead | Role::Section(_) | Role::Chrome))
                {
                    if let Some(slot) = map.ends.get_mut(sib) {
                        *slot = true;
                    }
                    break;
                }
                if primary_at.get(sib).copied().unwrap_or(false) {
                    break;
                }
                if start_at(sib) {
                    if sub {
                        break;
                    }
                    if let Some(slot) = map.ids.get_mut(sib) {
                        *slot = Some(id);
                    }
                    current = sib;
                    continue;
                }
                if contains.get(sib).copied().unwrap_or(false) {
                    if let Some(slot) = map.ends.get_mut(sib) {
                        *slot = true;
                    }
                    break;
                }
                if let Some(slot) = map.ids.get_mut(sib) {
                    *slot = Some(id);
                }
                current = sib;
            }
        }
        map
    }

    /// The label a sense starts with: the first sense number inside it, else a printed label at its start. `None` for
    /// a sense whose number the sheet draws (OALD 10's counters).
    fn sense_label(&self, i: usize, roles: &[Option<Role>]) -> Option<(String, bool)> {
        let mut stack = vec![i];
        let mut seen = 0;
        while let Some(j) = stack.pop() {
            seen += 1;
            if seen > 256 {
                break;
            }
            if j != i
                && roles.get(j).copied().flatten() == Some(Role::Sensenum)
                && let Some(text) = self.whole(j)
                && let Some(label) = any_label(&text)
            {
                return Some(label);
            }
            let kids: Vec<usize> = self.el_kids(j).collect();
            for kid in kids.into_iter().rev() {
                stack.push(kid);
            }
        }
        self.whole(i).and_then(|text| any_label(&text))
    }

    /// A block whose text opens with a printed label — NOAD's `1)` and `■`, a dictionary that writes its numbers as
    /// text. A bare number is not enough here (a year opens a paragraph too); the label must be punctuated.
    fn pattern_start(&self, i: usize, roles: &[Option<Role>]) -> Option<(String, bool)> {
        let node = self.node(i)?;
        if !block_tag(&node.name) {
            return None;
        }
        if !matches!(
            roles.get(i).copied().flatten(),
            None | Some(Role::Label(_)) | Some(Role::Pos) | Some(Role::Def) | Some(Role::Sense)
        ) {
            return None;
        }
        if self.in_role(i, roles, Role::Example) {
            return None;
        }
        let text = self.whole(i)?;
        if text.len() < 20 {
            return None;
        }
        let (label, sub) = printed_label(&text, false)?;
        if text.get(label.len()..).unwrap_or("").trim().chars().count() < 10 {
            return None;
        }
        Some((label.trim().to_owned(), sub))
    }

    /// **Which elements sit in a section that is not a definition's** — an idiom list, an etymology, a thesaurus. Those
    /// sections hold senses of their own only in the dictionary's own sense of the word; the mode explains the
    /// headword's sense, and a navigation or etymology block is not one. One forward pass: a node is in one when it is
    /// such a section, holds a heading that names one, or is inside a node that is.
    fn other_sections(&self, roles: &[Option<Role>]) -> Vec<bool> {
        const OTHER: &[&str] = &[
            "idioms",
            "phrasal",
            "phrases",
            "examples",
            "etym",
            "derivatives",
            "usage",
            "thesaurus",
            "colloc",
            "synonyms",
            "antonyms",
            "pron",
            "pronunciation",
            "pronunciations",
            "translations",
            "grammar",
            "trending",
            "vocabulary",
            "inflections",
            "notes",
            "help",
        ];
        let n = self.nodes.len();
        let mut own = vec![false; n];
        let mut after = vec![false; n];
        for i in 1..n {
            let section = matches!(
                roles.get(i).copied().flatten(),
                Some(Role::Section(kind)) if OTHER.contains(&kind)
            );
            // **A heading names what follows it, not what precedes it**: an "Idioms" heading at the end of a block
            // must not exclude the definitions above it (audit finding, 2026-10-22). A section marked as a whole but
            // holding such a heading is scoped the same way; one with no heading child is excluded whole.
            let mut in_other = false;
            let mut saw_heading = false;
            for c in self.el_kids(i) {
                let heading = roles.get(c).copied().flatten() == Some(Role::Heading)
                    && self.whole(c).is_some_and(|text| {
                        let low = text.to_lowercase();
                        let low = low.trim_end_matches(|ch: char| ch.is_whitespace() || ":：.".contains(ch));
                        heading_kind(low).is_some_and(|kind| OTHER.contains(&kind))
                    });
                if heading {
                    in_other = true;
                    saw_heading = true;
                }
                if in_other && let Some(slot) = after.get_mut(c) {
                    *slot = true;
                }
            }
            if section
                && !saw_heading
                && let Some(slot) = own.get_mut(i)
            {
                *slot = true;
            }
        }
        let mut out = vec![false; n];
        for i in 1..n {
            let parent = self.node(i).map_or(ROOT as usize, |x| x.parent as usize);
            let inherited = out.get(parent).copied().unwrap_or(false);
            let mine = own.get(i).copied().unwrap_or(false) || after.get(i).copied().unwrap_or(false);
            if let Some(slot) = out.get_mut(i) {
                *slot = inherited || mine;
            }
        }
        out
    }

    /// Whether an element reads as a definition: prose of its own, not a heading, not a run of navigation, and not a
    /// section that opens with one.
    fn definition_like(&self, i: usize, roles: &[Option<Role>]) -> bool {
        if matches!(
            roles.get(i).copied().flatten(),
            Some(Role::Heading | Role::Subhead | Role::Chrome | Role::Section(_))
        ) {
            return false;
        }
        // A section opens with its heading; a sense does not (OALD's "Trends of …", ODE's "Origin").
        for c in self.el_kids(i).take(2) {
            if matches!(roles.get(c).copied().flatten(), Some(Role::Heading | Role::Subhead | Role::Section(_))) {
                return false;
            }
        }
        let f = self.f(i);
        // A label-less sense is a definition, not a heading line or a list: give it room to be prose.
        f.words >= 5 && f.len >= 80
    }

    /// **The distinct top-level labels inside an element**: two or more make it a wrapper over several senses, not one.
    /// A markup whose only numbering is bracketed, circled or roman (`(1)`, `①`, `ii.`) is numbered by those; one that
    /// has plain numbers counts only them, so a numbered sense with lettered subsenses is not a wrapper (verification
    /// finding, 2026-10-23).
    fn primary_labels_inside(&self, i: usize, roles: &[Option<Role>]) -> usize {
        let mut stack = vec![i];
        let mut labels: Vec<(u8, String)> = Vec::new();
        let mut seen = 0;
        while let Some(j) = stack.pop() {
            seen += 1;
            if seen > 256 {
                break;
            }
            if j != i
                && roles.get(j).copied().flatten() == Some(Role::Sensenum)
                && let Some(text) = self.whole(j)
                && let Some((label, _)) = any_label(&text)
            {
                let label = label.trim().to_owned();
                let rank = label_rank(&label);
                if !labels.iter().any(|(r, l)| *r == rank && *l == label) {
                    labels.push((rank, label));
                }
            }
            let kids: Vec<usize> = self.el_kids(j).collect();
            for kid in kids.into_iter().rev() {
                stack.push(kid);
            }
        }
        // **The top-level labels are the ones at the shallowest rank present**: a `(1)` with `a.`/`b.` is one sense,
        // while `(1)`/`(2)` or `①`/`②` alone number two (verification finding, 2026-10-23).
        let Some(top) = labels.iter().map(|(rank, _)| *rank).min() else { return 0 };
        labels.iter().filter(|(rank, _)| *rank == top).count()
    }

    /// **Which elements' prose is excluded**, following wrappers: an element in an excluded section, or one with no
    /// prose of its own whose element children are all excluded. One reverse pass — children follow their parents.
    fn content_excluded(&self, excluded: &[bool]) -> Vec<bool> {
        let n = self.nodes.len();
        let mut out = vec![false; n];
        for i in (1..n).rev() {
            let Some(node) = self.node(i) else { continue };
            let kids: Vec<usize> = self.el_kids(i).collect();
            let kids_excluded = !kids.is_empty() && kids.iter().all(|c| out.get(*c).copied().unwrap_or(true));
            let mine = excluded.get(i).copied().unwrap_or(false) || (!node.direct && kids_excluded);
            if let Some(slot) = out.get_mut(i) {
                *slot = mine;
            }
        }
        out
    }

    /// Whether `i` is a descendant of `ancestor` in the element tree.
    fn descends_from(&self, i: usize, ancestor: usize) -> bool {
        let mut at = self.node(i).map(|n| n.parent as usize);
        for _ in 0..MAX_DEPTH {
            match at {
                Some(p) if p == ancestor => return true,
                Some(p) if p != ROOT as usize => at = self.node(p).map(|n| n.parent as usize),
                _ => return false,
            }
        }
        false
    }

    /// Whether an element is inside one whose role is `want`.
    fn in_role(&self, i: usize, roles: &[Option<Role>], want: Role) -> bool {
        let mut at = self.node(i).map(|n| n.parent as usize);
        for _ in 0..MAX_DEPTH {
            let Some(p) = at.filter(|p| *p != ROOT as usize) else { return false };
            if roles.get(p).copied().flatten() == Some(want) {
                return true;
            }
            at = self.node(p).map(|n| n.parent as usize);
        }
        false
    }

    /// **The first definition block**, for an entry that names no sense at all: the innermost element with prose of
    /// its own, no role that says it is something else, and no enclosing example or section. Its run is the sense.
    fn first_definition(&self, roles: &[Option<Role>], content_excluded: &[bool]) -> Option<usize> {
        let mut matches = Vec::new();
        for i in 1..self.nodes.len() {
            let Some(node) = self.node(i) else { continue };
            // **The fallback obeys the same eligibility as the main pass**: a hidden element, or one in an idiom,
            // etymology or navigation section (or a wrapper over one), is never the definition (audit findings,
            // 2026-10-22/23).
            if node.flags.hidden || content_excluded.get(i).copied().unwrap_or(true) {
                continue;
            }
            // A definition is often the element the generic rules name `Def` (an internal role, never written); that
            // does not make it something else. A structural role does.
            if !matches!(
                roles.get(i).copied().flatten(),
                None | Some(Role::Def) | Some(Role::Pos) | Some(Role::Label(_))
            ) {
                continue;
            }
            if matches!(&*node.name, "script" | "style" | "head" | "title") {
                continue;
            }
            let f = self.f(i);
            if f.len < 40 {
                continue;
            }
            if self.in_role(i, roles, Role::Example) {
                continue;
            }
            // **A wrapper over excluded content is not the definition**: its text is the excluded prose's, and making
            // it the sense would carry that prose into the target. Prose split across inline children stays eligible.
            if content_excluded.get(i).copied().unwrap_or(true) {
                continue;
            }
            // The text must read as prose: a phonetics line, a run of links or a list of labels is not a definition.
            let Some(text) = self.whole(i) else { continue };
            if text.split_whitespace().count() < 5 {
                continue;
            }
            matches.push(i);
        }
        // **The innermost match**: a wrapper holding the entry's blocks matches too, and is not the definition.
        for &i in &matches {
            let mut has_below = false;
            for &j in &matches {
                if j == i {
                    continue;
                }
                let mut at = self.node(j).map(|n| n.parent as usize);
                for _ in 0..MAX_DEPTH {
                    match at {
                        Some(p) if p == i => {
                            has_below = true;
                            break;
                        }
                        Some(p) if p != ROOT as usize => at = self.node(p).map(|n| n.parent as usize),
                        _ => break,
                    }
                }
                if has_below {
                    break;
                }
            }
            if !has_below {
                return Some(i);
            }
        }
        None
    }
}

/// The sense attributes one element's tag carries (ADR-0029 d.2).
fn append_sense(attr: &mut String, i: usize, senses: &SenseMap) {
    if let Some(id) = senses.ids.get(i).copied().flatten() {
        attr.push_str(&format!(" data-xdict-sense=\"{id}\""));
        if senses.starts.get(i).copied().unwrap_or(false) {
            if let Some(label) = senses.labels.get(i).and_then(Option::as_deref) {
                attr.push_str(&format!(" data-xdict-sense-label=\"{}\"", attr_text(label)));
            }
            // **The renderer is the authority on the hierarchy**: 0 says a top-level sense, so the projection never
            // invents a parent from whatever run happens to be open (ADR-0029 d.2).
            let parent = senses.parents.get(i).copied().flatten().unwrap_or(0);
            attr.push_str(&format!(" data-xdict-sense-parent=\"{parent}\""));
            if senses.runs.get(i).copied().unwrap_or(false) {
                attr.push_str(" data-xdict-sense-run");
            }
        }
    }
    if senses.ends.get(i).copied().unwrap_or(false) {
        attr.push_str(" data-xdict-sense-end");
    }
}

/// A label as an attribute value: the four characters markup cannot hold written as entities, controls dropped.
fn attr_text(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars().filter(|c| !c.is_control()) {
        match c {
            '&' => out.push_str("&amp;"),
            '"' => out.push_str("&quot;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            c => out.push(c),
        }
    }
    out
}

/// **A label as the markup writes it**: the printed forms [`printed_label`] reads, else a form [`sense_number`]
/// accepts and the renderer recognised as a sense number (`①`, `ii.`, `一、`) — a label the classifier accepted must
/// start a sense (audit finding, 2026-10-22).
fn any_label(text: &str) -> Option<(String, bool)> {
    let text = text.trim();
    if let Some((label, sub)) = printed_label(text, true) {
        return Some((label.trim().to_owned(), sub));
    }
    if numbered(text) {
        let first = text.chars().next()?;
        let sub = !(first.is_ascii_digit() || "一二三四五六七八九十".contains(first));
        return Some((text.chars().take(32).collect(), sub));
    }
    None
}

/// **How shallow a label's numbering is**: 0 a plain number, 1 a bracketed, circled or roman one, 2 a letter, a
/// multi-part number or a marker. The shallowest rank present is a container's top level (verification finding,
/// 2026-10-23).
fn label_rank(label: &str) -> u8 {
    let Some(first) = label.chars().next() else { return 2 };
    let code = u32::from(first);
    if first.is_ascii_digit() {
        // **A multi-part number is a subsense of the plain one**: `1.1` under `1`, never a second top level.
        let bytes = label.as_bytes();
        let mut at = 1;
        while bytes.get(at).is_some_and(|b| b.is_ascii_digit()) {
            at += 1;
        }
        if bytes.get(at) == Some(&b'.') && bytes.get(at + 1).is_some_and(|b| b.is_ascii_digit()) {
            return 2;
        }
        return 0;
    }
    if "一二三四五六七八九十".contains(first) {
        0
    } else if first == '('
        || (0x2460..=0x2473).contains(&code)
        || (0x2776..=0x277F).contains(&code)
        || "ivxIVX".contains(first)
    {
        1
    } else {
        2
    }
}

/// A printed sense label at the start of `t`: a marker (`■`), a number (`1`, `1.`, `1)`, `1.1`), a bracketed number
/// (`(1)`), or a lettered sub-sense (`a.`–`h.`, never a part of speech such as `n.`). `true` when it is a sub-label.
fn printed_label(t: &str, allow_bare: bool) -> Option<(&str, bool)> {
    let t = t.trim_start_matches(|c: char| c.is_whitespace() || matches!(c, '►' | '•' | '·'));
    if t.is_empty() {
        return None;
    }
    let first = t.chars().next()?;
    // A square marks a sub-sense (NOAD's `■`); a round bullet is a bullet, not a label.
    if "■□".contains(first) {
        return Some((t.get(..first.len_utf8())?, true));
    }
    let bytes = t.as_bytes();
    let digits = bytes.iter().take(3).take_while(|b| b.is_ascii_digit()).count();
    // **Four leading digits are a year, not a sense number**; a shorter number continues with `.` or `)` at byte 3
    // (`1.12`, `12.3`), which the guard must not reject (audit finding, 2026-10-22).
    if digits == 3 && bytes.get(3).is_some_and(|b| b.is_ascii_digit()) {
        return None;
    }
    if digits > 0 {
        let mut at = digits;
        let mut multi = false;
        while bytes.get(at) == Some(&b'.') && bytes.get(at + 1).is_some_and(|b| b.is_ascii_digit()) {
            multi = true;
            at += 1;
            while bytes.get(at).is_some_and(|b| b.is_ascii_digit()) {
                at += 1;
            }
        }
        let mut end = at;
        if bytes.get(end).is_some_and(|b| *b == b'.' || *b == b')') {
            end += 1;
        }
        if multi || end > at {
            return Some((t.get(..end)?, multi));
        }
        if allow_bare {
            return Some((t.get(..digits)?, false));
        }
        return None;
    }
    // A lettered sub-sense: a–h, punctuated and followed by a space. "n." is a part of speech, not a label.
    if ('a'..='h').contains(&first) || ('A'..='H').contains(&first) {
        let after = t.get(first.len_utf8()..)?.chars().next();
        if matches!(after, Some('.') | Some(')')) {
            let end = first.len_utf8() + 1;
            if t.get(end..).is_none_or(|rest| rest.chars().next().is_none_or(char::is_whitespace)) {
                return Some((t.get(..end)?, true));
            }
        }
    }
    None
}

/// Whether short text reads as a part of speech: a word or phrase of [`POS_WORDS`] or [`POS_PHRASES`], or up to
/// three of the words joined by `and`/`or`.
fn pos_text(t: &str) -> bool {
    let lower = t.to_lowercase();
    let low = lower.trim_matches(|c: char| " .,;:()[]{}".contains(c));
    let low2 = low.trim_end_matches(|c: char| c.is_whitespace() || c == '.');
    let words: Vec<&str> = low.split(|c: char| c.is_whitespace() || ",/&;".contains(c)).collect();
    let pos_word = |w: &str| POS_WORDS.contains(&w.trim_matches('.'));
    POS_WORDS.contains(&low)
        || POS_WORDS.contains(&low2)
        || POS_PHRASES.contains(&low)
        || (words.len() <= 3
            && words.iter().all(|w| pos_word(w) || matches!(*w, "and" | "or" | "&" | ""))
            && words.iter().any(|w| pos_word(w)))
}

/// Whether a class (lower case) only grades the word it marks: its frequency, level or stars (`frequent`, `redword`,
/// `star3`, `level2`, `ox3000`, `cefr-b1`), not what kind of element it is.
fn modifier(class: &str) -> bool {
    const STEMS: &[&str] =
        &["freq", "frequent", "redword", "star", "stars", "level", "ox3000", "ox5000", "cefr", "band"];
    let stem = class.trim_end_matches(|c: char| c.is_ascii_digit() || c == '-' || c == '_');
    STEMS.contains(&class)
        || STEMS.contains(&stem)
        || STEMS.iter().any(|s| stem.strip_prefix(s).is_some_and(|r| r.starts_with(['-', '_'])))
}

fn block_tag(name: &str) -> bool {
    const BLOCKS: &[&str] = &[
        "div",
        "p",
        "li",
        "dd",
        "dt",
        "dl",
        "ul",
        "ol",
        "section",
        "article",
        "blockquote",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "header",
        "footer",
        "aside",
        "table",
        "center",
        "address",
        "figure",
    ];
    BLOCKS.contains(&name)
}

/// Roles as they are assigned: the first one an element gets is its role; `desc` holds, per element, the roles
/// below it.
struct Roles2<'n> {
    roles: Vec<Option<Role>>,
    desc: Vec<u32>,
    nodes: &'n [Node],
}

impl Roles2<'_> {
    fn has(&self, i: usize) -> bool {
        self.roles.get(i).is_some_and(Option::is_some)
    }

    fn role(&self, i: usize) -> Option<Role> {
        self.roles.get(i).copied().flatten()
    }

    fn below(&self, i: usize, roles: &[Role]) -> bool {
        let mask = roles.iter().fold(0, |m, r| m | r.bit());
        self.desc.get(i).is_some_and(|d| d & mask != 0)
    }

    fn mark(&mut self, i: usize, role: Role) {
        let Some(node) = self.nodes.get(i) else { return };
        if i == ROOT as usize || self.has(i) || NO_ROLE.contains(&&*node.name) {
            return;
        }
        if let Some(slot) = self.roles.get_mut(i) {
            *slot = Some(role);
        }
        let bit = role.bit();
        let mut p = node.parent as usize;
        while let Some(d) = self.desc.get_mut(p) {
            if *d & bit != 0 {
                break;
            }
            *d |= bit;
            if p == ROOT as usize {
                break;
            }
            p = self.nodes.get(p).map_or(ROOT as usize, |x| x.parent as usize);
        }
    }
}

/// An entry's original text with only its roles inserted: no rewrite, no strip, nothing else changed. For measuring
/// the rules against the element sweep's labels, which key elements by their markup as written.
pub fn roles_marked(text: &str, key: &str, style: &crate::Style, base: &str) -> String {
    let mut roles = Roles::new(&style.facts, Some(key), base, "");
    let mut rest = text;
    let mut at = 0usize;
    while let Some(lt) = rest.find('<') {
        let (before, from) = rest.split_at(lt);
        roles.text(before, Some(at));
        at += before.len();
        if let Some(c) = from.strip_prefix("<!--") {
            let end = c.find("-->").map_or(c.len(), |e| e + 3);
            at += 4 + end;
            rest = c.get(end..).unwrap_or("");
            continue;
        }
        let close = from.strip_prefix("</");
        let body = close.unwrap_or(from.get(1..).unwrap_or(""));
        if !body.starts_with(|c: char| c.is_ascii_alphabetic()) {
            roles.text("<", None);
            at += 1;
            rest = from.get(1..).unwrap_or("");
            continue;
        }
        let len = from.find('>').map_or(from.len(), |e| e + 1);
        let tag = from.get(..len).unwrap_or(from);
        let name_len = body.find(|c: char| c.is_ascii_whitespace() || c == '/' || c == '>').unwrap_or(body.len());
        let name = body.get(..name_len).unwrap_or("");
        if close.is_some() {
            roles.end(name, at, at + len);
            at += len;
            rest = from.get(len..).unwrap_or("");
            continue;
        }
        let image =
            name.eq_ignore_ascii_case("img") && !matches!(crate::images::judge(tag), crate::images::Image::Decoration);
        roles.start(name, at, at + 1 + name.len(), at + len, tag, image, None);
        at += len;
        rest = from.get(len..).unwrap_or("");
        if name.eq_ignore_ascii_case("script") || name.eq_ignore_ascii_case("style") {
            let lower = rest.to_ascii_lowercase();
            let end = lower.find(&format!("</{}", name.to_ascii_lowercase())).unwrap_or(rest.len());
            at += end;
            rest = rest.get(end..).unwrap_or("");
        }
    }
    roles.text(rest, Some(at));
    let decided = roles.finish();
    let mut inserts: Vec<(usize, String)> = decided
        .edits
        .into_iter()
        .filter(|(a, b, t)| a == b && t.starts_with(" data-xdict-role"))
        .map(|(a, _, t)| (a, t))
        .collect();
    inserts.sort_by_key(|(a, _)| *a);
    let mut out = String::with_capacity(text.len() + inserts.len() * 32);
    let mut from = 0;
    for (a, s) in inserts {
        out.push_str(text.get(from..a).unwrap_or(""));
        out.push_str(&s);
        from = a;
    }
    out.push_str(text.get(from..).unwrap_or(""));
    out
}

/// What a Private Use character of Minion's markup is in Unicode: AHD's pronunciation key, drawn by a Minion that is
/// not on a Mac (the gallery sweep of 2026-10-17 drew boxes; reading-style R3's edge). The two tied vowels with their
/// combining tie (U+035E double macron, U+035D double breve), and the primary stress, a bold prime beside the light
/// prime (U+2032) the markup writes for secondary stress. Read from the entries: `bassoon` (bə-so͞on′),
/// `hurdswoman` (-wo͝om′-), `alone` (ə-lōn′). The bold is a style, not a `<b>`: a dictionary rule on its bold (AHD's
/// `.runseg b::before`, a bullet) would draw on it too.
fn minion(c: char) -> Option<&'static str> {
    match c {
        '\u{e012}' => Some("o\u{35d}o"),
        '\u{e013}' => Some("o\u{35e}o"),
        '\u{e01f}' => Some("<span style=\"font-weight:bold\">\u{2032}</span>"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    // The workspace forbids these in library code; a test asserts by failing, which is the point.
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

    use super::*;

    /// Past the last element followed, the text kept is only what that element's rules read: 50 MiB of links kept
    /// 8 MiB of text no rule reads.
    #[test]
    fn text_past_the_last_element_is_kept_only_as_far_as_it_is_read() {
        let style = crate::Style::of_sheets([]);
        let mut roles = Roles::new(&style.facts, Some("word"), "xdict://d/", "");
        for i in 0..MAX_NODES + 10 {
            roles.start("b", i, i, i, "<b>", false, None);
            roles.text("word ", None);
            roles.end("b", i, i);
        }
        for _ in 0..100_000 {
            roles.text("more text no rule reads ", None);
        }
        let last = roles.nodes.last().map_or(0, |n| n.text.0 as usize);
        assert!(
            roles.buf.len() <= last + READ_BYTES + 64,
            "{} bytes kept, the last element at {last}",
            roles.buf.len()
        );
    }

    /// Every element followed holds a `Node`, up to `MAX_NODES` of them.
    #[test]
    fn a_node_is_small() {
        assert!(size_of::<Node>() <= 160, "{} bytes", size_of::<Node>());
    }

    #[test]
    fn a_key_is_compared_unmarked() {
        assert_eq!(norm_key("acidˈūlate"), "acidulate");
        assert!(is_key("ac·cu·mu·lat·ed adj.", &norm_key("accumulated")));
        assert!(is_key("alias, v.", &norm_key("alias")));
        assert!(is_key("bank²", &norm_key("bank")));
        assert!(!is_key("banks", &norm_key("bank")));
    }

    #[test]
    fn sense_numbers_are_shaped() {
        for t in ["1", "1a", "(2)", "ii.", "b)", "①", "一、", "12."] {
            assert!(sense_number(t), "{t}");
        }
        for t in ["123", "word", "z)", "1.2.3"] {
            assert!(!sense_number(t), "{t}");
        }
    }

    #[test]
    fn labels_and_parts_of_speech_are_closed_lists() {
        assert_eq!(label_kind("brit", "Brit", false), Some("region"));
        assert_eq!(label_kind("informal", "informal", false), Some("register"));
        assert_eq!(label_kind("law", "law", false), None, "a domain word needs italics or brackets");
        assert_eq!(label_kind("law", "(law)", false), Some("domain"));
        assert!(freq("B2") && freq("★★★") && freq("S1, W2") && !freq("D4"));
        assert!(gram("[C]") && gram("[T, I]") && !gram("[ok]"));
    }

    #[test]
    fn a_labels_rank_says_which_level_its_numbering_is() {
        // A plain number is the top level; a multi-part number is a subsense; bracketed, circled and roman numbers
        // are their own top level when no plain one exists; a letter or a marker is below them.
        assert_eq!(label_rank("1."), 0);
        assert_eq!(label_rank("12"), 0);
        assert_eq!(label_rank("一、"), 0);
        assert_eq!(label_rank("1.1"), 2);
        assert_eq!(label_rank("1)"), 0);
        assert_eq!(label_rank("(1)"), 1);
        assert_eq!(label_rank("①"), 1);
        assert_eq!(label_rank("ii."), 1);
        assert_eq!(label_rank("a."), 2);
        assert_eq!(label_rank("■"), 2);
    }

    #[test]
    fn an_entry_numbered_only_in_brackets_gives_two_top_level_senses() {
        // No plain number exists, so `(1)` and `(2)` are the top level: left as sub-labels they would trigger the
        // unnumbered fallback and give the first sense a fabricated parent (audit finding, 2026-10-23).
        let style = crate::Style::of_edition([], []);
        let context = crate::Entry {
            key: "bracketed",
            resource: None,
            is_key: None,
            strip_off_for_tests: false,
            original: false,
        };
        let html = concat!(
            r#"<div class="entry"><div><span class="num">(1)</span><span class="def">a body of water</span></div>"#,
            r#"<div><span class="num">(2)</span><span class="def">to move fast</span></div></div>"#
        );
        let (marked, _) = crate::entry_normalized_within(html, "", "", &style, &context, usize::MAX).unwrap();
        assert_eq!(marked.matches("data-xdict-sense=\"").count(), 2, "{marked}");
        assert_eq!(marked.matches("data-xdict-sense-parent=\"0\"").count(), 2, "{marked}");
    }
}
