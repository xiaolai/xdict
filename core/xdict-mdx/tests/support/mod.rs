//! A scratch file that removes itself.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

static NEXT: AtomicUsize = AtomicUsize::new(0);

pub struct Scratch(PathBuf);

impl Scratch {
    pub fn with(bytes: &[u8], extension: &str) -> Self {
        let name =
            format!("xdict-mdx-test-{}-{}.{extension}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed));
        let path = std::env::temp_dir().join(name);
        std::fs::write(&path, bytes).unwrap_or_else(|e| panic!("cannot write {}: {e}", path.display()));
        Self(path)
    }

    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}
