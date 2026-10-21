//! **The log's frames and its event identity** (ADR-0024): magic, payload length, an xxh3 checksum, then the payload.
//! A checksum proves a frame is whole; replay stops at the first frame that is not, and the log is truncated there. An
//! event id is the SHA-256 of its payload, so the same stored event is the same id wherever it travels.

use sha2::{Digest, Sha256};

const MAGIC: u32 = 0x5844_4C47; // "XDLG"

/// A frame: magic, payload length, xxh3 checksum, payload.
pub(crate) fn frame(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len() + 16);
    out.extend_from_slice(&MAGIC.to_le_bytes());
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(&xxhash_rust::xxh3::xxh3_64(payload).to_le_bytes());
    out.extend_from_slice(payload);
    out
}

/// The payload of the frame at `offset` and the offset after it; `None` at the first incomplete or corrupt frame.
pub(crate) fn next_frame(bytes: &[u8], offset: usize) -> Option<(&[u8], usize)> {
    let rest = bytes.get(offset..)?;
    let magic = u32::from_le_bytes(rest.get(0..4)?.try_into().ok()?);
    if magic != MAGIC {
        return None;
    }
    let length = u32::from_le_bytes(rest.get(4..8)?.try_into().ok()?) as usize;
    let checksum = u64::from_le_bytes(rest.get(8..16)?.try_into().ok()?);
    let payload = rest.get(16..16 + length)?;
    if xxhash_rust::xxh3::xxh3_64(payload) != checksum {
        return None;
    }
    Some((payload, offset + 16 + length))
}

/// The event id: the SHA-256 of the payload, in lower-case hex.
pub(crate) fn event_id(payload: &[u8]) -> String {
    let digest = Sha256::digest(payload);
    let mut out = String::with_capacity(64);
    for byte in digest {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}
