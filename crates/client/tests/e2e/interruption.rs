//! Interrupted transfer coverage: a provider outage or a stopped upload must
//! never publish a half-written file, and the next attempt must resume without
//! re-posting chunks that were already stored.

use super::*;
use nntdrive_storage::chunker::ChunkStream;
use nntdrive_storage::{prepare_chunk, ChunkConfig};

/// Deterministic, non-repeating content: a 64-bit LCG keeps every 4 MiB block
/// distinct so chunks cannot deduplicate by accident.
fn payload(len: usize) -> Vec<u8> {
    let mut state = 0x243F_6A88_85A3_08D3u64;
    (0..len)
        .map(|_| {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (state >> 33) as u8
        })
        .collect()
}

fn api(s: &Stack) -> ApiClient {
    let mut api = ApiClient::new(s.base_url.clone()).unwrap();
    api.set_token(s.token.clone());
    api
}

#[tokio::test]
async fn interrupted_upload_resumes_without_reposting_published_chunks() {
    let Some(s) = stack().await else { return };
    let api = api(&s);

    let dir = tempfile::tempdir().unwrap();
    // Larger than the 4 MiB maximum chunk size so the stream emits a partial
    // first chunk and at least one further chunk.
    let data = payload(9 * 1024 * 1024 + 12345);
    let src = dir.path().join("interrupted.bin");
    tokio::fs::write(&src, &data).await.unwrap();

    let file_id = create_node(&api, &s.master, "Interrupted.bin").await;

    // Publish exactly one chunk, then drop the stream: this is the state an
    // interrupted upload leaves behind (stored chunk, no committed version).
    let file = tokio::fs::File::open(&src).await.unwrap();
    let mut stream = ChunkStream::new(file, ChunkConfig::default());
    let first = stream.next_chunk().await.unwrap().unwrap();
    let prepared = prepare_chunk(&s.master, &first, 3).unwrap();
    let (_, articles) = api.publish_chunk(&prepared).await.unwrap();
    assert!(
        articles > 0,
        "the partial upload must really store articles"
    );
    drop(stream);

    assert!(
        api.versions(file_id).await.unwrap().is_empty(),
        "an interrupted upload must not create a visible version"
    );

    // Retry: the already stored chunk is reused instead of posted again.
    let revision = Uuid::new_v4();
    let result = upload_file(&api, &s.master, file_id, revision, None, &src)
        .await
        .unwrap();
    assert_eq!(result.size, data.len() as u64);
    assert_eq!(result.chunks_reused, 1, "{result:?}");
    assert!(result.chunks_new > 0, "{result:?}");

    let (sealed, manifest_rev) = api.manifest(file_id, None).await.unwrap();
    let envelope = nntdrive_crypto::Envelope::from_bytes(&sealed).unwrap();
    let manifest = FileManifest::from_bytes(
        &s.master
            .open_manifest(file_id, manifest_rev, &envelope)
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        manifest.chunks.len(),
        result.chunks_reused + result.chunks_new,
        "every chunk of the finished upload is accounted for exactly once"
    );

    let versions = api.versions(file_id).await.unwrap();
    assert_eq!(versions.len(), 1, "{versions:?}");

    let dest = dir.path().join("interrupted-out.bin");
    download_file(&api, &s.master, file_id, None, &dest)
        .await
        .unwrap();
    assert_eq!(tokio::fs::read(&dest).await.unwrap(), data);
}

#[tokio::test]
async fn upload_rejected_by_provider_keeps_no_version_and_retries() {
    let Some(s) = stack().await else { return };
    let api = api(&s);

    let dir = tempfile::tempdir().unwrap();
    let data = payload(700_000);
    let src = dir.path().join("outage.bin");
    tokio::fs::write(&src, &data).await.unwrap();

    let file_id = create_node(&api, &s.master, "Outage.bin").await;
    let revision = Uuid::new_v4();

    s._nntp.store.set_posting_blocked(true).await;
    let err = upload_file(&api, &s.master, file_id, revision, None, &src)
        .await
        .unwrap_err();
    s._nntp.store.set_posting_blocked(false).await;
    assert!(
        !err.to_string().is_empty(),
        "the interrupted upload must report a failure"
    );
    assert!(
        api.versions(file_id).await.unwrap().is_empty(),
        "a rejected upload must not create a version"
    );

    let result = upload_file(&api, &s.master, file_id, revision, None, &src)
        .await
        .unwrap();
    assert_eq!(result.size, data.len() as u64);
    assert_eq!(api.versions(file_id).await.unwrap().len(), 1);

    let dest = dir.path().join("outage-out.bin");
    download_file(&api, &s.master, file_id, None, &dest)
        .await
        .unwrap();
    assert_eq!(tokio::fs::read(&dest).await.unwrap(), data);
}

#[tokio::test]
async fn interrupted_download_leaves_no_destination_or_partial_file() {
    let Some(s) = stack().await else { return };
    let api = api(&s);

    let dir = tempfile::tempdir().unwrap();
    let data = payload(2 * 1024 * 1024 + 777);
    let src = dir.path().join("source.bin");
    tokio::fs::write(&src, &data).await.unwrap();

    let file_id = create_node(&api, &s.master, "Download.bin").await;
    upload_file(&api, &s.master, file_id, Uuid::new_v4(), None, &src)
        .await
        .unwrap();

    let dest = dir.path().join("partial.bin");
    let part = dir.path().join("partial.bin.nntdrive-part");

    s._nntp.store.set_outage(true).await;
    let err = download_file(&api, &s.master, file_id, None, &dest)
        .await
        .unwrap_err();
    s._nntp.store.set_outage(false).await;
    assert!(
        !err.to_string().is_empty(),
        "the interrupted download must report a failure"
    );

    assert!(
        !dest.exists(),
        "an interrupted download must not materialize the destination"
    );
    assert!(
        !part.exists(),
        "an interrupted download must not leave a partial file behind"
    );

    // The next attempt succeeds and never exposes stale partial content.
    let ok = download_file(&api, &s.master, file_id, None, &dest)
        .await
        .unwrap();
    assert_eq!(ok.size, data.len() as u64);
    assert_eq!(tokio::fs::read(&dest).await.unwrap(), data);
    assert!(!part.exists());
}
