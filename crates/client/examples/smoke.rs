//! Manual end-to-end smoke test against a running NNTDrive backend.
//!
//!   cargo run -p nntdrive-client --example smoke -- http://127.0.0.1:8080 /path/to/file
//!
//! Registers a throw-away account, uploads the file, downloads it and compares
//! bytes. Requires the backend to have a posting provider (the docker-compose
//! dev override ships an in-memory one).

use nntdrive_client::{download_file, upload_file, ApiClient};
use nntdrive_crypto::{derive_auth_verifier, DeviceKeypair, KeyFile};
use serde_json::json;
use std::path::PathBuf;
use uuid::Uuid;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let base = args
        .next()
        .unwrap_or_else(|| "http://127.0.0.1:8080".into());
    let path = PathBuf::from(
        args.next()
            .ok_or_else(|| anyhow::anyhow!("usage: smoke <base_url> <file>"))?,
    );
    let data = std::fs::read(&path)?;
    let email = format!("smoke-{}@example.com", Uuid::new_v4());
    let password = "smoke-test-password";
    let account_id = Uuid::new_v4();
    let (keyfile, master) = KeyFile::create(password, account_id)?;
    let verifier = derive_auth_verifier(password, account_id);
    let device = DeviceKeypair::generate();

    let http = reqwest::Client::new();
    let res = http
        .post(format!("{base}/api/v1/auth/register"))
        .json(&json!({
            "account_id": account_id,
            "email": email,
            "verifier": verifier,
            "keyfile": keyfile,
            "device": {
                "id": Uuid::new_v4(),
                "name": "smoke",
                "platform": "linux",
                "public_key": b64(&device.public().0),
            }
        }))
        .send()
        .await?;
    let status = res.status();
    let body: serde_json::Value = res.json().await?;
    anyhow::ensure!(status.is_success(), "register failed {status}: {body}");
    let token = body["token"].as_str().unwrap().to_string();

    let mut api = ApiClient::new(base.clone())?;
    api.set_token(token);
    let file_id = Uuid::new_v4();
    let sealed = master.seal_name(file_id, "smoke.bin")?.to_bytes();
    api.create_file(file_id, None, sealed, false).await?;

    println!("uploading {} bytes ...", data.len());
    let up = upload_file(&api, &master, file_id, Uuid::new_v4(), None, &path).await?;
    println!(
        "uploaded revision {} ({} new chunks, {} reused, {} articles)",
        up.revision_id, up.chunks_new, up.chunks_reused, up.articles_posted
    );
    let dest = std::env::temp_dir().join(format!("nntdrive-smoke-{}.bin", Uuid::new_v4()));
    let down = download_file(&api, &master, file_id, None, &dest).await?;
    anyhow::ensure!(down.size == data.len() as u64, "size mismatch");
    let read = std::fs::read(&dest)?;
    anyhow::ensure!(read == data, "downloaded bytes differ");
    std::fs::remove_file(&dest).ok();
    println!("SMOKE_OK: upload, download, decrypt and verify succeeded");
    Ok(())
}

fn b64(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}
