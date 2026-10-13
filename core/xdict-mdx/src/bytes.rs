//! Bounds-checked reading of untrusted bytes. Nothing here indexes or panics; running past the end is an
//! `Error::Malformed` naming what was being read.

use crate::Error;

/// A position in a buffer that only moves forward.
pub(crate) struct Cursor<'a> {
    buf: &'a [u8],
    pos: usize,
    what: &'static str,
}

impl<'a> Cursor<'a> {
    pub(crate) fn new(buf: &'a [u8], what: &'static str) -> Self {
        Self { buf, pos: 0, what }
    }

    pub(crate) fn is_at_end(&self) -> bool {
        self.pos >= self.buf.len()
    }

    pub(crate) fn take(&mut self, n: usize) -> Result<&'a [u8], Error> {
        let end = self.pos.checked_add(n).ok_or_else(|| self.short())?;
        let slice = self.buf.get(self.pos..end).ok_or_else(|| self.short())?;
        self.pos = end;
        Ok(slice)
    }

    pub(crate) fn u8(&mut self) -> Result<u8, Error> {
        Ok(u8::from_be_bytes(self.array()?))
    }

    pub(crate) fn u16(&mut self) -> Result<u16, Error> {
        Ok(u16::from_be_bytes(self.array()?))
    }

    pub(crate) fn u32(&mut self) -> Result<u32, Error> {
        Ok(u32::from_be_bytes(self.array()?))
    }

    pub(crate) fn u64(&mut self) -> Result<u64, Error> {
        Ok(u64::from_be_bytes(self.array()?))
    }

    /// A number in the format's width: 8 bytes from version 2.0, 4 before.
    pub(crate) fn number(&mut self, wide: bool) -> Result<u64, Error> {
        if wide { self.u64() } else { self.u32().map(u64::from) }
    }

    /// Bytes up to a null of `unit` bytes aligned to `unit`, consuming the null.
    pub(crate) fn until_null(&mut self, unit: usize) -> Result<&'a [u8], Error> {
        if unit == 0 {
            return Err(Error::Malformed(format!("the {} has a zero-width terminator", self.what)));
        }
        let rest = self.buf.get(self.pos..).ok_or_else(|| self.short())?;
        let mut at = 0;
        loop {
            let chunk = rest.get(at..at + unit).ok_or_else(|| self.short())?;
            if chunk.iter().all(|&b| b == 0) {
                self.pos += at + unit;
                return rest.get(..at).ok_or_else(|| self.short());
            }
            at += unit;
        }
    }

    /// A terminating null of `unit` bytes, which must be zero.
    pub(crate) fn null(&mut self, unit: usize) -> Result<(), Error> {
        if self.take(unit)?.iter().any(|&b| b != 0) {
            return Err(Error::Malformed(format!("a key in the {} is not null-terminated", self.what)));
        }
        Ok(())
    }

    fn array<const N: usize>(&mut self) -> Result<[u8; N], Error> {
        let slice = self.take(N)?;
        slice.try_into().map_err(|_| self.short())
    }

    fn short(&self) -> Error {
        Error::Malformed(format!("the {} ends early", self.what))
    }
}

/// Adler-32, as the format uses it for every checksum.
pub(crate) fn adler32(data: &[u8]) -> u32 {
    let (mut a, mut b) = (1u32, 0u32);
    for chunk in data.chunks(5552) {
        for &byte in chunk {
            a += u32::from(byte);
            b += a;
        }
        a %= 65521;
        b %= 65521;
    }
    (b << 16) | a
}

/// Converts a declared length to `usize`, refusing what exceeds `limit`.
pub(crate) fn length(value: u64, limit: u64, what: &str) -> Result<usize, Error> {
    if value > limit {
        return Err(Error::Malformed(format!("the {what} declares {value} bytes, more than the {limit} allowed")));
    }
    usize::try_from(value).map_err(|_| Error::Malformed(format!("the {what} is too large for this device")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_zero_width_terminator_is_refused() {
        let mut cursor = Cursor::new(b"abc", "test");
        assert!(cursor.until_null(0).is_err());
    }

    #[test]
    fn a_terminator_must_be_null() {
        assert!(Cursor::new(&[0, 0], "test").null(2).is_ok());
        assert!(matches!(Cursor::new(&[0, 1], "test").null(2), Err(Error::Malformed(_))));
    }
}
