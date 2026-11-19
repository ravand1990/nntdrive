//! Owned result paging, not incremental filesystem scanning.
//!
//! A cursor is created only after the entire safe comparison completes. It
//! consumes each record once without rescanning, re-sorting or cloning the
//! accumulated result. Skips and collision evidence share the page budget with
//! actions; scalar metadata alone is repeated. Paths remain client-local.
use crate::{FilesystemBlock, InspectItem, SyncInspection};
use serde::Serialize;
use std::collections::HashSet;
use std::vec::IntoIter;

pub const OVERVIEW_PAGE_LIMIT: usize = 256;

#[derive(Serialize)]
pub struct OverviewInspectItem {
    #[serde(flatten)]
    pub item: InspectItem,
    /// Computed against ALL collision evidence, including later pages and both
    /// move endpoints. Consumers must not infer safety from this page's pairs.
    pub case_collision: bool,
}

#[derive(Clone, Copy, Serialize)]
pub struct InspectionTotals {
    pub items: usize,
    pub skipped: usize,
    pub case_collisions: usize,
}

#[derive(Serialize)]
pub struct InspectionPage {
    pub items: Vec<OverviewInspectItem>,
    pub skipped: Vec<(String, String)>,
    pub case_collisions: Vec<(String, String)>,
    pub filesystem_blocked: Option<FilesystemBlock>,
    pub journal_available: bool,
    pub folder_moves_pending: bool,
    pub totals: InspectionTotals,
    /// Number of records (not UI rows) delivered including this page.
    pub delivered: usize,
    pub done: bool,
}

pub struct InspectionCursor {
    items: IntoIter<InspectItem>,
    skipped: IntoIter<(String, String)>,
    collisions: IntoIter<(String, String)>,
    blocked_paths: HashSet<String>,
    filesystem_blocked: Option<FilesystemBlock>,
    journal_available: bool,
    folder_moves_pending: bool,
    totals: InspectionTotals,
    delivered: usize,
}

impl InspectionCursor {
    // Only a complete engine snapshot may become a cursor. The legacy truncated
    // inspection must never silently masquerade as a fully reachable result.
    pub(crate) fn new(inspection: SyncInspection) -> Self {
        assert!(!inspection.truncated, "cannot page a truncated inspection");
        let totals = InspectionTotals {
            items: inspection.items.len(),
            skipped: inspection.skipped.len(),
            case_collisions: inspection.case_collisions.len(),
        };
        let blocked_paths = inspection
            .case_collisions
            .iter()
            .flat_map(|(a, b)| [a.clone(), b.clone()])
            .collect();
        Self {
            items: inspection.items.into_iter(),
            skipped: inspection.skipped.into_iter(),
            collisions: inspection.case_collisions.into_iter(),
            blocked_paths,
            filesystem_blocked: inspection.filesystem_blocked,
            journal_available: inspection.journal_available,
            folder_moves_pending: inspection.folder_moves_pending,
            totals,
            delivered: 0,
        }
    }

    pub fn next_page(&mut self, limit: usize) -> Result<InspectionPage, &'static str> {
        if !(1..=OVERVIEW_PAGE_LIMIT).contains(&limit) {
            return Err("invalid overview page size");
        }
        let items: Vec<_> = self
            .items
            .by_ref()
            .take(limit)
            .map(|item| OverviewInspectItem {
                case_collision: self.blocked_paths.contains(&item.path)
                    || item
                        .path_to
                        .as_ref()
                        .is_some_and(|path| self.blocked_paths.contains(path)),
                item,
            })
            .collect();
        let skipped: Vec<_> = self.skipped.by_ref().take(limit - items.len()).collect();
        let case_collisions: Vec<_> = self
            .collisions
            .by_ref()
            .take(limit - items.len() - skipped.len())
            .collect();
        self.delivered += items.len() + skipped.len() + case_collisions.len();
        let done = self.items.len() + self.skipped.len() + self.collisions.len() == 0;
        if done {
            self.blocked_paths.clear();
        }
        Ok(InspectionPage {
            items,
            skipped,
            case_collisions,
            filesystem_blocked: self.filesystem_blocked,
            journal_available: self.journal_available,
            folder_moves_pending: self.folder_moves_pending,
            totals: self.totals,
            delivered: self.delivered,
            done,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(path: String) -> InspectItem {
        InspectItem {
            kind: "move_remote".into(),
            path,
            path_to: Some("late-target".into()),
            size: None,
            is_dir: false,
        }
    }

    #[test]
    fn pages_bound_all_records_and_keep_late_collision_safety() {
        let mut cursor = InspectionCursor::new(SyncInspection {
            items: (0..20_017).map(|i| item(format!("file-{i}"))).collect(),
            skipped: (0..10_003)
                .map(|i| (format!("skip-{i}"), "rule".into()))
                .collect(),
            case_collisions: (0..10_001)
                .map(|i| (format!("collision-{i}"), "late-target".into()))
                .collect(),
            ..Default::default()
        });
        assert!(cursor.next_page(0).is_err());
        assert!(cursor.next_page(OVERVIEW_PAGE_LIMIT + 1).is_err());
        let mut paths = HashSet::new();
        let mut skips = HashSet::new();
        let mut collisions = HashSet::new();
        let mut delivered = 0;
        loop {
            let page = cursor.next_page(127).unwrap();
            let count = page.items.len() + page.skipped.len() + page.case_collisions.len();
            assert!(count <= 127);
            assert_eq!(page.totals.items, 20_017);
            for row in page.items {
                assert!(
                    row.case_collision,
                    "destination collision is on a later page"
                );
                assert!(paths.insert(row.item.path));
            }
            for (path, _) in page.skipped {
                assert!(skips.insert(path));
            }
            for (path, _) in page.case_collisions {
                assert!(collisions.insert(path));
            }
            delivered += count;
            assert_eq!(page.delivered, delivered);
            if page.done {
                break;
            }
            assert!(count > 0);
        }
        assert_eq!(paths.len(), 20_017);
        assert_eq!(skips.len(), 10_003);
        assert_eq!(collisions.len(), 10_001);
        assert!(cursor.next_page(1).unwrap().done);
    }

    #[test]
    fn blocked_and_empty_snapshots_have_one_terminal_metadata_page() {
        for blocked in [None, Some(FilesystemBlock::NotFound)] {
            let mut cursor = InspectionCursor::new(SyncInspection {
                filesystem_blocked: blocked,
                ..Default::default()
            });
            let page = cursor.next_page(1).unwrap();
            assert!(page.done);
            assert_eq!(page.delivered, 0);
            assert_eq!(page.filesystem_blocked, blocked);
        }
    }
}
