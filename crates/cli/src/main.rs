//! NNTDrive CLI: administrative helpers and the Phase 1 storage demonstration.

use anyhow::{bail, Context as _, Result};
use clap::{Parser, Subcommand};
use nntdrive_crypto::{hash_verifier, KeyFile, MasterKey, RecoveryKit};
use nntdrive_nntp::{parse_providers, MockConfig, MockNntpServer, NntpPool};
use nntdrive_storage::config::StorageConfig;
use nntdrive_storage::{Context, Storage, Store};
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use uuid::Uuid;

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("../../migrations");

#[derive(Parser, Clone)]
#[command(
    name = "nntdrive",
    version,
    about = "Encrypted cloud storage on Usenet"
)]
struct Cli {
    #[arg(long, env = "DATABASE_URL")]
    database_url: Option<String>,
    #[arg(long, env = "NNTDRIVE_NNTP_PROVIDERS")]
    providers: Option<String>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Clone)]
enum Command {
    /// Create tables in the configured PostgreSQL database.
    InitDb,
    /// Create an account, keyfile and recovery kit (operator bootstrap).
    AccountCreate {
        #[arg(long)]
        email: String,
        #[arg(long, env = "NNTDRIVE_PASSWORD")]
        password: String,
        #[arg(long, default_value = "nntdrive.keyfile.json")]
        keyfile_out: PathBuf,
        #[arg(long)]
        recovery_out: Option<PathBuf>,
        /// Grant administrator rights (the first account is always admin).
        #[arg(long)]
        admin: bool,
    },
    /// Encrypt, erasure-code and post a file to Usenet.
    Upload {
        #[arg(long)]
        account: Uuid,
        #[arg(long)]
        keyfile: PathBuf,
        #[arg(long, env = "NNTDRIVE_PASSWORD")]
        password: String,
        #[arg(long)]
        path: PathBuf,
        #[arg(long)]
        file_id: Option<Uuid>,
        #[arg(long)]
        parent: Option<Uuid>,
    },
    /// Download and verify the latest (or a specific) revision.
    Download {
        #[arg(long)]
        account: Uuid,
        #[arg(long)]
        keyfile: PathBuf,
        #[arg(long, env = "NNTDRIVE_PASSWORD")]
        password: String,
        #[arg(long)]
        file_id: Uuid,
        #[arg(long)]
        revision: Option<Uuid>,
        #[arg(long)]
        out: PathBuf,
    },
    /// Show article health and recoverability for a file.
    Health {
        #[arg(long)]
        account: Uuid,
        #[arg(long)]
        keyfile: PathBuf,
        #[arg(long, env = "NNTDRIVE_PASSWORD")]
        password: String,
        #[arg(long)]
        file_id: Uuid,
        #[arg(long)]
        json: bool,
    },
    /// Repost missing shards from surviving ones.
    Repair {
        #[arg(long)]
        account: Uuid,
        #[arg(long)]
        keyfile: PathBuf,
        #[arg(long, env = "NNTDRIVE_PASSWORD")]
        password: String,
        #[arg(long)]
        file_id: Uuid,
    },
    /// Repost aging articles before provider retention expires them.
    Refresh {
        #[arg(long)]
        account: Uuid,
        #[arg(long)]
        keyfile: PathBuf,
        #[arg(long, env = "NNTDRIVE_PASSWORD")]
        password: String,
        #[arg(long)]
        file_id: Uuid,
        #[arg(long, default_value_t = 30)]
        max_age_days: u32,
    },
    /// List version history (revision IDs and sizes; names are client-side).
    Versions {
        #[arg(long)]
        account: Uuid,
        #[arg(long)]
        file_id: Uuid,
    },
    /// Mint an API token for an account (operator bootstrap for the admin UI).
    TokenCreate {
        #[arg(long)]
        account: Uuid,
        #[arg(long, default_value = "operator")]
        label: String,
    },
    /// First-run bootstrap: create the first administrator, keyfile, recovery
    /// kit and admin token in one step (only when the database has no accounts).
    Bootstrap {
        #[arg(long)]
        email: String,
        #[arg(long, env = "NNTDRIVE_PASSWORD")]
        password: String,
        #[arg(long, default_value = "nntdrive-admin.keyfile.json")]
        keyfile_out: PathBuf,
        #[arg(long)]
        recovery_out: Option<PathBuf>,
    },
    /// Export a recovery kit for an existing key.
    RecoveryCreate {
        #[arg(long)]
        keyfile: PathBuf,
        #[arg(long, env = "NNTDRIVE_PASSWORD")]
        password: String,
        #[arg(long)]
        out: PathBuf,
    },
    /// Rebuild a keyfile from a recovery kit and a new password.
    RecoveryRestore {
        #[arg(long)]
        kit: PathBuf,
        #[arg(long, env = "NNTDRIVE_RECOVERY_CODE")]
        recovery_code: String,
        #[arg(long, env = "NNTDRIVE_PASSWORD")]
        password: String,
        #[arg(long)]
        out: PathBuf,
    },
    /// Full local demonstration against the built-in mock NNTP server.
    Demo {
        #[arg(long)]
        file: Option<PathBuf>,
        #[arg(long, default_value_t = 2_000_000)]
        size: usize,
        #[arg(long, default_value = "nntdrive-demo.keyfile.json")]
        keyfile_out: PathBuf,
    },
    /// Development-only standalone NNTP mock (no credentials, in-memory).
    MockNntp {
        #[arg(long, default_value = "127.0.0.1:1119")]
        bind: String,
        #[arg(long, default_value = "alt.binaries.test")]
        group: String,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info,sqlx=warn".into()),
        )
        .init();
    let cli = Cli::parse();
    match cli.command.clone() {
        Command::InitDb => {
            let pool = connect(&cli.database_url).await?;
            MIGRATOR.run(&pool).await?;
            println!("database schema is up to date");
        }
        Command::AccountCreate {
            email,
            password,
            keyfile_out,
            recovery_out,
            admin,
        } => {
            let pool = connect(&cli.database_url).await?;
            MIGRATOR.run(&pool).await?;
            let account_id = Uuid::new_v4();
            let (keyfile, master) = KeyFile::create(&password, account_id)?;
            let verifier = nntdrive_crypto::derive_auth_verifier(&password, account_id);
            let hash = hash_verifier(&verifier)?;
            let mut tx = pool.begin().await?;
            let is_admin = nntdrive_storage::store::account_creation_is_admin(&mut tx, true, admin)
                .await?
                .expect("account-create allows existing accounts");
            sqlx::query(
                "INSERT INTO accounts (id, email, password_hash, display_name, keyfile, is_admin)
                 VALUES ($1, lower($2), $3, $2, $4, $5)",
            )
            .bind(account_id)
            .bind(&email)
            .bind(hash)
            .bind(serde_json::to_value(&keyfile)?)
            .bind(is_admin)
            .execute(&mut *tx)
            .await?;
            tx.commit().await?;
            std::fs::write(&keyfile_out, serde_json::to_vec_pretty(&keyfile)?)?;
            let (kit, code) = RecoveryKit::create(&master, Some(format!("account {account_id}")))?;
            let kit_path =
                recovery_out.unwrap_or_else(|| keyfile_out.with_extension("recovery.json"));
            std::fs::write(&kit_path, kit.to_json_pretty()?)?;
            println!("account_id: {account_id}");
            println!("keyfile:    {}", keyfile_out.display());
            println!("recovery:   {} (kit) ", kit_path.display());
            println!("RECOVERY CODE (shown once, store offline): {code}");
        }
        Command::Upload {
            account,
            keyfile,
            password,
            path,
            file_id,
            parent,
        } => {
            let master = unlock(&keyfile, &password, account)?;
            let (storage, _mock) = storage(&cli, &pool(&cli).await?).await?;
            let file_id = match file_id {
                Some(id) => {
                    ensure_file(&storage, account, id, parent, &path, &master).await?;
                    id
                }
                None => create_file(&storage, account, parent, &path, &master).await?,
            };
            let revision = Uuid::new_v4();
            let handle = tokio::fs::File::open(&path).await?;
            let ctx = Context::new(account, master);
            let outcome = storage.upload(&ctx, file_id, revision, handle).await?;
            storage.commit(&ctx, &outcome, None).await?;
            println!(
                "uploaded file_id={file_id} revision={revision} size={} chunks_new={} chunks_reused={} articles={} bytes_posted={}",
                outcome.manifest.size,
                outcome.stats.chunks_new,
                outcome.stats.chunks_reused,
                outcome.stats.articles_posted,
                outcome.stats.bytes_posted
            );
        }
        Command::Download {
            account,
            keyfile,
            password,
            file_id,
            revision,
            out,
        } => {
            let master = unlock(&keyfile, &password, account)?;
            let (storage, _mock) = storage(&cli, &pool(&cli).await?).await?;
            let ctx = Context::new(account, master);
            let (manifest, _, rev) = storage.load_manifest(&ctx, file_id, revision).await?;
            let mut writer = tokio::fs::File::create(&out).await?;
            let stats = storage.download_to(&ctx, &manifest, &mut writer).await?;
            use tokio::io::AsyncWriteExt;
            writer.flush().await?;
            println!(
                "downloaded file_id={file_id} revision={rev} bytes={} chunks={} shards={} -> {}",
                stats.bytes_written,
                stats.chunks,
                stats.shards_fetched,
                out.display()
            );
        }
        Command::Health {
            account,
            keyfile,
            password,
            file_id,
            json,
        } => {
            let master = unlock(&keyfile, &password, account)?;
            let (storage, _mock) = storage(&cli, &pool(&cli).await?).await?;
            let ctx = Context::new(account, master);
            let (manifest, _, _) = storage.load_manifest(&ctx, file_id, None).await?;
            let health = storage.check_file(&ctx, &manifest).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&health)?);
            } else {
                println!(
                    "file {file_id}: recoverable={} degraded={} shards {}/{}",
                    health.recoverable,
                    health.degraded,
                    health.available_shards,
                    health.total_shards
                );
                for s in &health.stripes {
                    println!(
                        "  stripe {}: {}/{} shards (need {}) recoverable={}{}",
                        s.index,
                        s.available,
                        s.data_shards + s.parity_shards,
                        s.required,
                        s.recoverable,
                        if s.degraded { " DEGRADED" } else { "" }
                    );
                }
            }
            if !health.recoverable {
                std::process::exit(2);
            }
        }
        Command::Repair {
            account,
            keyfile,
            password,
            file_id,
        } => {
            let master = unlock(&keyfile, &password, account)?;
            let (storage, _mock) = storage(&cli, &pool(&cli).await?).await?;
            let ctx = Context::new(account, master);
            let (manifest, _, _) = storage.load_manifest(&ctx, file_id, None).await?;
            let report = storage.repair_file(&ctx, &manifest).await?;
            println!("{}", serde_json::to_string_pretty(&report)?);
            if report.stripes_unrecoverable > 0 {
                std::process::exit(2);
            }
        }
        Command::Refresh {
            account,
            keyfile,
            password,
            file_id,
            max_age_days,
        } => {
            let master = unlock(&keyfile, &password, account)?;
            let (storage, _mock) = storage(&cli, &pool(&cli).await?).await?;
            let ctx = Context::new(account, master);
            let (manifest, _, _) = storage.load_manifest(&ctx, file_id, None).await?;
            let report = storage.refresh_file(&ctx, &manifest, max_age_days).await?;
            println!("{}", serde_json::to_string_pretty(&report)?);
        }
        Command::Versions { account, file_id } => {
            let pool = pool(&cli).await?;
            let versions = Store::new(pool)
                .list_versions(account, file_id, 100)
                .await?;
            for v in versions {
                println!(
                    "{} size={} created={} deleted={}",
                    v.revision_id,
                    v.size,
                    v.created_at.to_rfc3339(),
                    v.deleted
                );
            }
        }
        Command::TokenCreate { account, label } => {
            let pool = pool(&cli).await?;
            let exists: Option<Uuid> = sqlx::query_scalar("SELECT id FROM accounts WHERE id = $1")
                .bind(account)
                .fetch_optional(&pool)
                .await?;
            if exists.is_none() {
                bail!("account {account} does not exist");
            }
            let token = mint_token(&pool, account, &label).await?;
            println!("token ({label}, valid 90 days, shown once): {token}");
        }
        Command::Bootstrap {
            email,
            password,
            keyfile_out,
            recovery_out,
        } => {
            let pool = pool(&cli).await?;
            if password.len() < 8 {
                bail!("password must be at least 8 characters");
            }
            let account_id = Uuid::new_v4();
            let (keyfile, master) = KeyFile::create(&password, account_id)?;
            let verifier = nntdrive_crypto::derive_auth_verifier(&password, account_id);
            let hash = hash_verifier(&verifier)?;
            let mut tx = pool.begin().await?;
            if nntdrive_storage::store::account_creation_is_admin(&mut tx, false, false)
                .await?
                .is_none()
            {
                bail!("this server already has accounts; use account-create/token-create instead");
            }
            sqlx::query(
                "INSERT INTO accounts (id, email, password_hash, display_name, keyfile, is_admin)
                 VALUES ($1, lower($2), $3, $2, $4, TRUE)",
            )
            .bind(account_id)
            .bind(&email)
            .bind(hash)
            .bind(serde_json::to_value(&keyfile)?)
            .execute(&mut *tx)
            .await?;
            tx.commit().await?;
            let (kit, code) = RecoveryKit::create(&master, Some(format!("account {account_id}")))?;

            if let Some(parent) = keyfile_out.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(&keyfile_out, serde_json::to_vec_pretty(&keyfile)?)?;
            let kit_path = recovery_out
                .clone()
                .unwrap_or_else(|| keyfile_out.with_extension("recovery.json"));
            if let Some(parent) = kit_path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(&kit_path, kit.to_json_pretty()?)?;
            let token = mint_token(&pool, account_id, "admin-dashboard").await?;

            println!("==================================================================");
            println!(" NNTDrive first-run setup complete");
            println!("==================================================================");
            println!("server:        (your backend URL, e.g. http://127.0.0.1:8080)");
            println!("account_id:    {account_id}");
            println!("email:         {email}");
            println!("role:          administrator");
            println!("keyfile:       {}", keyfile_out.display());
            println!("recovery kit:  {}", kit_path.display());
            println!();
            println!("RECOVERY CODE (shown once, store offline):");
            println!("  {code}");
            println!();
            println!("ADMIN API TOKEN (shown once, paste into /admin):");
            println!("  {token}");
            println!("==================================================================");
        }
        Command::RecoveryCreate {
            keyfile,
            password,
            out,
        } => {
            let kf: KeyFile = serde_json::from_slice(&std::fs::read(&keyfile)?)?;
            let master = kf.unlock(&password)?;
            let (kit, code) = RecoveryKit::create(&master, None)?;
            std::fs::write(&out, kit.to_json_pretty()?)?;
            println!("recovery kit: {}", out.display());
            println!("RECOVERY CODE (shown once, store offline): {code}");
        }
        Command::RecoveryRestore {
            kit,
            recovery_code,
            password,
            out,
        } => {
            let kit = RecoveryKit::from_json(&std::fs::read_to_string(&kit)?)?;
            let master = kit.unlock(&recovery_code)?;
            let keyfile = KeyFile::create(&password, master.account_id())?;
            // Reuse the restored master, not the newly generated one.
            let kf = keyfile.0.rewrap(&master, &password)?;
            std::fs::write(&out, serde_json::to_vec_pretty(&kf)?)?;
            println!(
                "restored keyfile: {} (epoch {})",
                out.display(),
                master.epoch()
            );
        }
        Command::Demo {
            file,
            size,
            keyfile_out,
        } => {
            demo(&cli, file, size, &keyfile_out).await?;
        }
        Command::MockNntp { bind, group } => {
            let server = MockNntpServer::start_on(
                bind.parse()
                    .map_err(|_| anyhow::anyhow!("invalid --bind address"))?,
                MockConfig {
                    require_auth: false,
                    posting_enabled: true,
                    groups: vec![group.clone()],
                    ..Default::default()
                },
            )
            .await;
            let config = nntdrive_nntp::NntpConfig {
                name: "mock".into(),
                host: "127.0.0.1".into(),
                port: server.addr.port(),
                tls: false,
                username: None,
                password: None,
                max_connections: 8,
                role: nntdrive_nntp::ProviderRole::Both,
                priority: 0,
                groups: vec![group],
                message_id_domain: "mock.local".into(),
                connect_timeout_secs: 5,
                io_timeout_secs: 30,
                retention_days: None,
                max_retries: 1,
            };
            println!(
                "mock NNTP listening on {} (in-memory, development only)",
                server.addr
            );
            println!("provider JSON: {}", serde_json::to_string(&vec![config])?);
            println!("press Ctrl-C to stop; all articles are lost on exit");
            tokio::signal::ctrl_c().await?;
        }
    }
    Ok(())
}

async fn connect(url: &Option<String>) -> Result<PgPool> {
    let url = url
        .clone()
        .or_else(|| std::env::var("DATABASE_URL").ok())
        .context("DATABASE_URL is required")?;
    Ok(PgPoolOptions::new()
        .max_connections(8)
        .connect(&url)
        .await?)
}

async fn pool(cli: &Cli) -> Result<PgPool> {
    let pool = connect(&cli.database_url).await?;
    MIGRATOR.run(&pool).await?;
    Ok(pool)
}

async fn storage(cli: &Cli, pool: &PgPool) -> Result<(Storage, Option<MockNntpServer>)> {
    let store = Store::new(pool.clone());
    if let Some(json) = std::env::var("NNTDRIVE_NNTP_PROVIDERS")
        .ok()
        .or(cli.providers.clone())
    {
        let providers = parse_providers(&json).context("invalid NNTDRIVE_NNTP_PROVIDERS JSON")?;
        let pool = Arc::new(NntpPool::new(providers)?);
        return Ok((Storage::new(store, pool, StorageConfig::default())?, None));
    }
    bail!(
        "no NNTP providers configured. Set NNTDRIVE_NNTP_PROVIDERS to a JSON array \
         (see deploy/providers.example.json)"
    )
}

fn unlock(path: &Path, password: &str, account: Uuid) -> Result<MasterKey> {
    let kf: KeyFile = serde_json::from_slice(&std::fs::read(path)?)?;
    if kf.account_id != account {
        bail!("keyfile belongs to account {}", kf.account_id);
    }
    Ok(kf.unlock(password)?)
}

async fn mint_token(pool: &PgPool, account: Uuid, label: &str) -> Result<String> {
    use base64::Engine;
    use rand::RngCore;
    use sha2::{Digest, Sha256};
    let mut bytes = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    let token = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes);
    let mut h = Sha256::new();
    h.update(token.as_bytes());
    let hash = h.finalize();
    sqlx::query(
        "INSERT INTO api_tokens (id, account_id, token_hash, scope, expires_at)
         VALUES ($1, $2, $3, 'client', now() + interval '90 days')",
    )
    .bind(Uuid::new_v4())
    .bind(account)
    .bind(hash.as_slice())
    .execute(pool)
    .await?;
    let _ = label;
    Ok(token)
}

async fn create_file(
    storage: &Storage,
    account: Uuid,
    parent: Option<Uuid>,
    path: &Path,
    master: &MasterKey,
) -> Result<Uuid> {
    let id = Uuid::new_v4();
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| id.to_string());
    let name_enc = master.seal_name(id, &name)?.to_bytes();
    sqlx::query("INSERT INTO files (id, account_id, parent_id, name_enc) VALUES ($1, $2, $3, $4)")
        .bind(id)
        .bind(account)
        .bind(parent)
        .bind(name_enc)
        .execute(storage.store().pool())
        .await?;
    Ok(id)
}

async fn ensure_file(
    storage: &Storage,
    account: Uuid,
    id: Uuid,
    parent: Option<Uuid>,
    path: &Path,
    master: &MasterKey,
) -> Result<()> {
    let exists: Option<Uuid> =
        sqlx::query_scalar("SELECT id FROM files WHERE account_id = $1 AND id = $2")
            .bind(account)
            .bind(id)
            .fetch_optional(storage.store().pool())
            .await?;
    if exists.is_none() {
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| id.to_string());
        let name_enc = master.seal_name(id, &name)?.to_bytes();
        sqlx::query(
            "INSERT INTO files (id, account_id, parent_id, name_enc) VALUES ($1, $2, $3, $4)",
        )
        .bind(id)
        .bind(account)
        .bind(parent)
        .bind(name_enc)
        .execute(storage.store().pool())
        .await?;
    }
    Ok(())
}

async fn demo(cli: &Cli, file: Option<PathBuf>, size: usize, keyfile_out: &Path) -> Result<()> {
    let pool = pool(cli).await?;
    let server = MockNntpServer::start(MockConfig {
        require_auth: false,
        ..Default::default()
    })
    .await;
    let nntp = Arc::new(NntpPool::new(vec![server.client_config()])?);
    let config = StorageConfig {
        shard_size: 128 * 1024,
        max_data_shards: 4,
        redundancy_percent: 40,
        ..Default::default()
    };
    let storage = Storage::new(Store::new(pool.clone()), nntp, config)?;
    let account = Uuid::new_v4();
    let email = format!("demo-{account}@nntdrive.local");
    let password = "demo-password-not-secret";
    let (keyfile, master) = KeyFile::create(password, account)?;
    let verifier = nntdrive_crypto::derive_auth_verifier(password, account);
    sqlx::query(
        "INSERT INTO accounts (id, email, password_hash, display_name, keyfile)
         VALUES ($1, $2, $3, 'Demo', $4)",
    )
    .bind(account)
    .bind(&email)
    .bind(hash_verifier(&verifier)?)
    .bind(serde_json::to_value(&keyfile)?)
    .execute(&pool)
    .await?;
    std::fs::write(keyfile_out, serde_json::to_vec_pretty(&keyfile)?)?;
    let (kit, code) = RecoveryKit::create(&master, Some("demo".into()))?;
    let kit_path = keyfile_out.with_extension("recovery.json");
    std::fs::write(&kit_path, kit.to_json_pretty()?)?;

    let data: Vec<u8> = match &file {
        Some(path) => {
            std::fs::read(path).with_context(|| format!("cannot read {}", path.display()))?
        }
        None => (0..size)
            .map(|i| (i.wrapping_mul(2654435761) >> 9) as u8)
            .collect(),
    };
    let file_id = create_file(&storage, account, None, Path::new("demo.bin"), &master).await?;
    let ctx = Context::new(account, master.clone());

    println!("== NNTDrive Phase 1/2 demonstration ==");
    println!("mock NNTP: 127.0.0.1:{}", server.addr.port());
    println!("account:   {account}");
    println!("file:      {file_id} ({} bytes)", data.len());
    println!("keyfile:   {}", keyfile_out.display());
    println!("recovery:  {} (code printed below)", kit_path.display());
    println!("RECOVERY CODE (demo only): {code}\n");

    let revision = Uuid::new_v4();
    let outcome = storage
        .upload(&ctx, file_id, revision, std::io::Cursor::new(data.clone()))
        .await?;
    storage.commit(&ctx, &outcome, None).await?;
    println!(
        "upload: chunks_new={} articles={} bytes_posted={}",
        outcome.stats.chunks_new, outcome.stats.articles_posted, outcome.stats.bytes_posted
    );

    let (manifest, _, _) = storage.load_manifest(&ctx, file_id, None).await?;
    let mut downloaded = Vec::new();
    let stats = storage
        .download_to(&ctx, &manifest, &mut downloaded)
        .await?;
    anyhow::ensure!(downloaded == data, "downloaded bytes differ from source");
    println!(
        "download + decrypt + verify: OK ({} bytes, {} shards)",
        stats.bytes_written, stats.shards_fetched
    );

    let health = storage.check_file(&ctx, &manifest).await?;
    println!(
        "health: recoverable={} degraded={} shards={}/{}",
        health.recoverable, health.degraded, health.available_shards, health.total_shards
    );

    // Lose one article per stripe, as a provider retention gap would.
    let mut deleted = 0;
    let mut seen = std::collections::HashSet::new();
    for s in storage
        .store()
        .load_shards_for_stripes(&stripe_ids(&manifest))
        .await?
    {
        if seen.insert(s.stripe_id) {
            server.store.delete_message(&s.message_id).await;
            deleted += 1;
        }
    }
    println!("\nsimulated loss of {deleted} articles (one per stripe)");
    let health = storage.check_file(&ctx, &manifest).await?;
    println!(
        "health after loss: recoverable={} degraded={} shards={}/{}",
        health.recoverable, health.degraded, health.available_shards, health.total_shards
    );
    let mut recovered = Vec::new();
    storage.download_to(&ctx, &manifest, &mut recovered).await?;
    anyhow::ensure!(
        recovered == data,
        "recovery after loss produced wrong bytes"
    );
    println!("download despite loss: OK (erasure coding reconstructed missing shards)");

    let repair = storage.repair_file(&ctx, &manifest).await?;
    println!(
        "repair: stripes_repaired={} shards_reposted={} unrecoverable={}",
        repair.stripes_repaired, repair.shards_reposted, repair.stripes_unrecoverable
    );
    let health = storage.check_file(&ctx, &manifest).await?;
    println!(
        "health after repair: recoverable={} degraded={} shards={}/{}",
        health.recoverable, health.degraded, health.available_shards, health.total_shards
    );

    // Deduplication: the same content in a new revision must not be re-posted.
    let before = server.store.article_count().await;
    let second = storage
        .upload(
            &ctx,
            file_id,
            Uuid::new_v4(),
            std::io::Cursor::new(data.clone()),
        )
        .await?;
    storage.commit(&ctx, &second, Some(revision)).await?;
    println!(
        "re-upload identical content: chunks_reused={} new_articles={}",
        second.stats.chunks_reused,
        server.store.article_count().await - before
    );

    // Whole-stripe loss is reported honestly, never as success.
    let first = manifest.chunks.first().and_then(|c| c.stripes.first());
    if let Some(stripe) = first {
        for s in storage.store().load_shards(stripe.id).await? {
            server.store.delete_message(&s.message_id).await;
        }
        let mut sink = Vec::new();
        match storage.download_to(&ctx, &manifest, &mut sink).await {
            Ok(_) => bail!("unrecoverable file was downloaded successfully - bug"),
            Err(e) => println!("\nwhole-stripe loss correctly reported: {e}"),
        }
    }
    println!(
        "\nDemo complete. Keyfile and recovery kit were written next to the working directory."
    );
    Ok(())
}

fn stripe_ids(manifest: &nntdrive_storage::FileManifest) -> Vec<Uuid> {
    manifest
        .chunks
        .iter()
        .flat_map(|c| c.stripes.iter().map(|s| s.id))
        .collect()
}
