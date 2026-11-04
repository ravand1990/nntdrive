//! NNTDrive synchronization engine (shared by desktop and mobile clients).
//!
//! * [`scanner`] detects local changes without following symlinks out of the
//!   sync root and without touching files that are still being written.
//! * [`reconcile`] is a pure three-way decision function: revision ancestry,
//!   not mtime, decides conflicts, and both versions survive a conflict.
//! * [`journal`] persists the last synced baseline in SQLite.
//! * [`engine`] applies actions through a [`Remote`] transport.

pub mod engine;
pub mod journal;
pub mod reconcile;
pub mod scanner;

pub use engine::{Remote, SyncEngine, SyncError, SyncReport};
pub use journal::{Journal, JournalError};
pub use reconcile::{
    conflict_copy_name, detect_local, detect_remote, reconcile, Action, BaselineEntry, LocalChange,
    RemoteChange, RemoteEntry,
};
pub use scanner::{scan, ScanOptions, ScanResult, ScannedEntry};
