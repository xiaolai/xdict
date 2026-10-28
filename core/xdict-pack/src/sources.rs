//! Reading a source the way the reference implementation reads it: lines split as Python splits them with
//! `newline=""`, and CSV parsed with Python's default dialect.

use std::io::Read;

use crate::error::{PackError, PackErrorKind, PackResult};
use crate::limits::{MAX_CSV_FIELD_BYTES, MAX_SOURCE_LINE_BYTES};

/// One physical line: its text without the terminator, the terminator it ended with, and its number from 1.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Line {
    /// The line's number, 1-based, counting every physical line.
    pub number: u64,
    /// The line's text, no terminator.
    pub content: String,
    /// `\n`, `\r\n`, `\r`, or empty on the last line of a file that does not end with one.
    pub terminator: &'static str,
}

impl Line {
    /// The line checked to the source bound, and its text.
    pub fn check(&self, source: &str) -> PackResult<&str> {
        let chars = self.content.chars().count() + self.terminator.chars().count();
        let bytes = self.content.len() + self.terminator.len();
        if chars as u64 > MAX_SOURCE_LINE_BYTES || bytes as u64 > MAX_SOURCE_LINE_BYTES {
            return Err(PackError::at(
                PackErrorKind::Bound,
                source,
                self.number,
                format!("line longer than {MAX_SOURCE_LINE_BYTES} bytes"),
            ));
        }
        Ok(&self.content)
    }
}

/// A reader of physical lines, splitting on `\r\n`, `\r` and `\n` and keeping the terminator — what Python does
/// with `newline=""`.
pub struct Lines<R> {
    inner: R,
    source: String,
    buffer: Vec<u8>,
    position: usize,
    filled: usize,
    number: u64,
}

impl<R: Read> Lines<R> {
    /// Reads lines from `inner`.
    pub fn new(inner: R, source: impl Into<String>) -> Self {
        Self { inner, source: source.into(), buffer: Vec::new(), position: 0, filled: 0, number: 0 }
    }

    /// `bound` the moment a line is longer than a source line may be: a reader never holds what it will refuse.
    fn too_long(&self) -> PackError {
        PackError::at(
            PackErrorKind::Bound,
            self.source.clone(),
            self.number + 1,
            format!("line longer than {MAX_SOURCE_LINE_BYTES} bytes"),
        )
    }

    fn fill(&mut self) -> PackResult<bool> {
        if self.buffer.is_empty() {
            self.buffer.resize(64 * 1024, 0);
        }
        loop {
            match self.inner.read(&mut self.buffer) {
                Ok(0) => return Ok(false),
                Ok(read) => {
                    self.position = 0;
                    self.filled = read;
                    return Ok(true);
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(error) => {
                    return Err(PackError::new(PackErrorKind::Malformed, format!("cannot read a source: {error}")));
                }
            }
        }
    }

    fn peek(&mut self) -> PackResult<Option<u8>> {
        if self.position >= self.filled && !self.fill()? {
            return Ok(None);
        }
        Ok(self.buffer.get(self.position).copied())
    }

    /// The next line, or `None` at the end of the input.
    pub fn next_line(&mut self) -> PackResult<Option<Line>> {
        let mut content: Vec<u8> = Vec::new();
        let mut saw = false;
        let terminator: &'static str = loop {
            if self.position >= self.filled && !self.fill()? {
                if !saw {
                    return Ok(None);
                }
                break "";
            }
            saw = true;
            let found = self
                .buffer
                .get(self.position..self.filled)
                .unwrap_or(&[])
                .iter()
                .position(|b| *b == b'\n' || *b == b'\r');
            match found {
                Some(offset) => {
                    let slice = self.buffer.get(self.position..self.filled).unwrap_or(&[]);
                    content.extend_from_slice(slice.get(..offset).unwrap_or(&[]));
                    if content.len() as u64 > MAX_SOURCE_LINE_BYTES {
                        return Err(self.too_long());
                    }
                    let marker = slice.get(offset).copied().unwrap_or(b'\n');
                    self.position += offset + 1;
                    if marker == b'\n' {
                        break "\n";
                    }
                    if self.peek()? == Some(b'\n') {
                        self.position += 1;
                        break "\r\n";
                    }
                    break "\r";
                }
                None => {
                    let slice = self.buffer.get(self.position..self.filled).unwrap_or(&[]);
                    content.extend_from_slice(slice);
                    self.position = self.filled;
                    if content.len() as u64 > MAX_SOURCE_LINE_BYTES {
                        return Err(self.too_long());
                    }
                }
            }
        };
        self.number += 1;
        let content = String::from_utf8(content)
            .map_err(|error| PackError::new(PackErrorKind::Malformed, format!("not UTF-8: {error}")))?;
        Ok(Some(Line { number: self.number, content, terminator }))
    }
}

/// Lines read through a gzip member, or several concatenated ones, as Python's `gzip.open` reads them.
pub fn gzip_reader(file: std::fs::File) -> flate2::read::MultiGzDecoder<std::io::BufReader<std::fs::File>> {
    flate2::read::MultiGzDecoder::new(std::io::BufReader::new(file))
}

/// One CSV record: its fields, and the number of the last physical line it occupied.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    /// The fields, in order.
    pub fields: Vec<String>,
    /// The line number Python's `reader.line_num` gives: the physical line the record ended on.
    pub line: u64,
}

/// A CSV reader with Python's default dialect: `,` the delimiter, `"` the quote, a doubled quote an escaped one,
/// a quoted field free to span lines, and (non-strict) anything after a closing quote kept literally.
pub struct Csv<R> {
    lines: Lines<R>,
    source: String,
}

impl<R: Read> Csv<R> {
    /// Reads records from `inner`, naming `source` in any failure.
    pub fn new(inner: R, source: impl Into<String>) -> Self {
        let source = source.into();
        Self { lines: Lines::new(inner, source.clone()), source }
    }

    /// The next record, or `None` at the end of the input.
    pub fn next_record(&mut self) -> PackResult<Option<Record>> {
        let Some(first) = self.lines.next_line()? else { return Ok(None) };
        let mut number = first.number;
        let mut content: Vec<char> = first.content.chars().collect();
        let mut terminator = first.terminator;
        if content.is_empty() {
            return Ok(Some(Record { fields: Vec::new(), line: number }));
        }
        let mut record: Vec<String> = Vec::new();
        let mut position = 0usize;
        loop {
            let mut field = String::new();
            let mut quoted = false;
            if content.get(position).copied() == Some('"') {
                quoted = true;
                position += 1;
            }
            let at_comma = loop {
                // A field is capped as it grows: the check after the field would run only once it was already held.
                if field.len() as u64 > MAX_CSV_FIELD_BYTES {
                    return Err(PackError::at(
                        PackErrorKind::Bound,
                        self.source.clone(),
                        number,
                        format!("field larger than field limit ({MAX_CSV_FIELD_BYTES})"),
                    ));
                }
                match content.get(position).copied() {
                    None => {
                        if quoted {
                            field.push_str(terminator);
                            match self.lines.next_line()? {
                                Some(next) => {
                                    number = next.number;
                                    content = next.content.chars().collect();
                                    terminator = next.terminator;
                                    position = 0;
                                }
                                None => break false,
                            }
                        } else {
                            break false;
                        }
                    }
                    Some(ch) if quoted => {
                        if ch == '"' {
                            if content.get(position + 1).copied() == Some('"') {
                                field.push('"');
                                position += 2;
                            } else {
                                quoted = false;
                                position += 1;
                            }
                        } else {
                            field.push(ch);
                            position += 1;
                        }
                    }
                    Some(',') => {
                        position += 1;
                        break true;
                    }
                    Some(ch) => {
                        field.push(ch);
                        position += 1;
                    }
                }
            };
            self.check_field(&field, number)?;
            record.push(field);
            if !at_comma {
                return Ok(Some(Record { fields: record, line: number }));
            }
        }
    }

    fn check_field(&self, field: &str, line: u64) -> PackResult<()> {
        if field.chars().count() as u64 > MAX_CSV_FIELD_BYTES {
            return Err(PackError::at(
                PackErrorKind::Bound,
                self.source.clone(),
                line,
                format!("field larger than field limit ({MAX_CSV_FIELD_BYTES})"),
            ));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::indexing_slicing)]

    use super::*;

    fn lines(text: &str) -> Vec<Line> {
        let mut reader = Lines::new(text.as_bytes(), "test");
        let mut out = Vec::new();
        while let Some(line) = reader.next_line().unwrap() {
            out.push(line);
        }
        out
    }

    fn records(text: &str) -> Vec<Vec<String>> {
        let mut reader = Csv::new(text.as_bytes(), "test");
        let mut out = Vec::new();
        while let Some(record) = reader.next_record().unwrap() {
            out.push(record.fields);
        }
        out
    }

    #[test]
    fn lines_split_and_keep_their_terminator() {
        let read = lines("a\r\nb\nc\rd");
        assert_eq!(read.len(), 4);
        assert_eq!(read[0].content, "a");
        assert_eq!(read[0].terminator, "\r\n");
        assert_eq!(read[1].terminator, "\n");
        assert_eq!(read[2].terminator, "\r");
        assert_eq!(read[3].content, "d");
        assert_eq!(read[3].terminator, "");
        assert_eq!(read[3].number, 4);
    }

    #[test]
    fn a_trailing_terminator_does_not_make_an_empty_line() {
        assert_eq!(lines("a\n").len(), 1);
        assert_eq!(lines("").len(), 0);
        assert_eq!(lines("\n").len(), 1);
    }

    #[test]
    fn a_carriage_return_at_a_buffer_edge_is_one_terminator() {
        // 64 KiB of 'a' put a `\r` at the very end of the first fill.
        let mut text = "a".repeat(64 * 1024 - 1);
        text.push_str("\r\nb");
        let read = lines(&text);
        assert_eq!(read.len(), 2);
        assert_eq!(read[0].terminator, "\r\n");
        assert_eq!(read[1].content, "b");
    }

    #[test]
    fn csv_splits_the_plain_and_the_quoted_alike() {
        assert_eq!(records("a,b,c\n"), vec![vec!["a", "b", "c"]]);
        assert_eq!(records("\"a,b\",c\n"), vec![vec!["a,b", "c"]]);
        assert_eq!(records("\"a\"\"b\",c\n"), vec![vec!["a\"b", "c"]]);
        assert_eq!(records("a\"b,c\n"), vec![vec!["a\"b", "c"]]);
        assert_eq!(records("\"a\"b,c\n"), vec![vec!["ab", "c"]]);
        assert_eq!(records("a,,c\n"), vec![vec!["a", "", "c"]]);
        assert_eq!(records(",,\n"), vec![vec!["", "", ""]]);
    }

    #[test]
    fn csv_yields_no_fields_for_a_blank_line() {
        assert_eq!(records("\n"), vec![Vec::<String>::new()]);
    }

    #[test]
    fn csv_quoted_fields_span_lines() {
        assert_eq!(records("\"a\nb\",c\n"), vec![vec!["a\nb", "c"]]);
        assert_eq!(records("\"a\r\nb\",c\r\n"), vec![vec!["a\r\nb", "c"]]);
    }

    #[test]
    fn csv_reports_the_line_a_record_ended_on() {
        let mut reader = Csv::new("a,b\n\"x\ny\",c\nd,e\n".as_bytes(), "test");
        assert_eq!(reader.next_record().unwrap().unwrap().line, 1);
        assert_eq!(reader.next_record().unwrap().unwrap().line, 3);
        assert_eq!(reader.next_record().unwrap().unwrap().line, 4);
        assert!(reader.next_record().unwrap().is_none());
    }

    #[test]
    fn a_field_past_the_limit_names_the_line() {
        let text = format!("{},b\n", "a".repeat(MAX_CSV_FIELD_BYTES as usize + 1));
        let mut reader = Csv::new(text.as_bytes(), "ety");
        let error = reader.next_record().unwrap_err();
        assert_eq!(error.kind(), PackErrorKind::Bound);
        assert!(error.to_string().contains("field larger than field limit (65536)"));
    }
}
