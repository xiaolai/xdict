//! R10 (`dev-docs/reading-style.md`): every `<table>` is marked `data-xdict-table="data"` or `"layout"`, and a
//! top-level data table not inside an open `<p>` is wrapped in `<div data-xdict-scroll>`, so it scrolls in its own box.
//!
//! Tables are followed on a stack as the scanner meets them; what decides a table (its rows, the most cells in a row,
//! header cells, text directly in a cell, a nested table) is counted on the way, and its marks are insertions made at
//! the end with the transcriptions', in one pass.

/// The deepest nesting of tables followed.
const MAX_DEPTH: usize = 32;

struct Table {
    /// Where its `<` was written, and where an attribute goes after its name.
    start: usize,
    attribute: usize,
    rows: u32,
    cells: u32,
    widest: u32,
    header: bool,
    nested: bool,
    presentation: bool,
    /// Text directly in a cell: no element open inside the cell.
    text: bool,
    /// Elements open inside the current cell.
    depth: u32,
    in_cell: bool,
    /// Whether it opened inside an open `<p>`, which a wrapper would close.
    in_paragraph: bool,
}

#[derive(Default)]
pub(crate) struct Tables {
    open: Vec<Table>,
    deep: usize,
    paragraphs: u32,
    pub(crate) inserts: Vec<(usize, String)>,
    pub(crate) data: u64,
    pub(crate) layout: u64,
}

const VOID: [&str; 10] = ["br", "img", "hr", "input", "meta", "link", "wbr", "source", "col", "area"];

impl Tables {
    /// A start tag `name`, written from `at`; an attribute inserted at `attribute` follows its name.
    pub(crate) fn start(&mut self, name: &str, at: usize, attribute: usize, tag: &str) {
        let lower = name.to_ascii_lowercase();
        match lower.as_str() {
            "p" => self.paragraphs = self.paragraphs.saturating_add(1),
            "table" => {
                if let Some(parent) = self.open.last_mut() {
                    parent.nested = true;
                }
                if self.open.len() >= MAX_DEPTH {
                    self.deep += 1;
                    return;
                }
                let role = crate::phon::attribute_of(tag, "role");
                let summary = crate::phon::attribute_of(tag, "summary").is_some();
                self.open.push(Table {
                    start: at,
                    attribute,
                    rows: 0,
                    cells: 0,
                    widest: 0,
                    header: summary,
                    nested: false,
                    presentation: role.is_some_and(|r| r.eq_ignore_ascii_case("presentation")),
                    text: false,
                    depth: 0,
                    in_cell: false,
                    in_paragraph: self.paragraphs > 0,
                });
                return;
            }
            _ => {}
        }
        let Some(table) = self.open.last_mut() else { return };
        match lower.as_str() {
            "tr" => {
                table.rows += 1;
                table.cells = 0;
                table.in_cell = false;
            }
            "td" | "th" => {
                table.cells += 1;
                table.widest = table.widest.max(table.cells);
                table.header |= lower == "th";
                table.in_cell = true;
                table.depth = 0;
            }
            "thead" | "caption" => table.header = true,
            _ if table.in_cell && !VOID.contains(&lower.as_str()) && !tag.ends_with("/>") => table.depth += 1,
            _ => {}
        }
    }

    /// Text between tags.
    pub(crate) fn text(&mut self, raw: &str) {
        if let Some(table) = self.open.last_mut()
            && table.in_cell
            && table.depth == 0
            && !raw.trim().is_empty()
        {
            table.text = true;
        }
    }

    /// An end tag `name`; `after` is where the output stands after it.
    pub(crate) fn end(&mut self, name: &str, after: usize) {
        let lower = name.to_ascii_lowercase();
        match lower.as_str() {
            "p" => self.paragraphs = self.paragraphs.saturating_sub(1),
            "table" => {
                if self.deep > 0 {
                    self.deep -= 1;
                    return;
                }
                if let Some(table) = self.open.pop() {
                    self.close(table, after);
                }
            }
            "td" | "th" => {
                if let Some(table) = self.open.last_mut() {
                    table.in_cell = false;
                }
            }
            _ => {
                if let Some(table) = self.open.last_mut()
                    && table.in_cell
                {
                    table.depth = table.depth.saturating_sub(1);
                }
            }
        }
    }

    fn close(&mut self, table: Table, after: usize) {
        let layout = table.presentation || table.nested || table.rows <= 1 || table.widest <= 1;
        let data = !layout && (table.header || table.text);
        let kind = if data { "data" } else { "layout" };
        if data {
            self.data += 1;
        } else {
            self.layout += 1;
        }
        self.inserts.push((table.attribute, format!(" data-xdict-table=\"{kind}\"")));
        if data && self.open.is_empty() && !table.in_paragraph {
            self.inserts.push((table.start, "<div data-xdict-scroll>".to_owned()));
            self.inserts.push((after, "</div>".to_owned()));
        }
    }

    /// Tables left open at the end are marked as far as they were read; none is wrapped, having no end to close at.
    pub(crate) fn finish(mut self) -> (Vec<(usize, String)>, u64, u64) {
        while let Some(table) = self.open.pop() {
            self.inserts.push((table.attribute, " data-xdict-table=\"layout\"".to_owned()));
            self.layout += 1;
        }
        (self.inserts, self.data, self.layout)
    }
}
