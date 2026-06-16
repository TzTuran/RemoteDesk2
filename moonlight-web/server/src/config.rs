use serde::{Deserialize, Serialize};
use std::fs;

/// A single ICE server entry (STUN or TURN).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IceServer {
    pub urls: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub credential: Option<String>,
}

/// Top-level application configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    /// Bind address for the web server (e.g. "0.0.0.0").
    #[serde(default = "default_host")]
    pub host: String,

    /// Port Sunshine is listening on for WebRTC signaling.
    #[serde(default = "default_sunshine_port")]
    pub sunshine_port: u16,

    /// Port the web server listens on (overridable via CLI).
    #[serde(default = "default_web_port")]
    pub web_port: u16,

    /// Path to TLS certificate PEM file.
    #[serde(default)]
    pub tls_cert: String,

    /// Path to TLS private-key PEM file.
    #[serde(default)]
    pub tls_key: String,

    /// HS256 secret used to sign / verify JWTs.
    #[serde(default = "default_jwt_secret")]
    pub jwt_secret: String,

    /// bcrypt hash of the admin password.
    #[serde(default = "default_admin_password_hash")]
    pub admin_password_hash: String,

    /// ICE servers passed to WebRTC clients.
    #[serde(default = "default_ice_servers")]
    pub ice_servers: Vec<IceServer>,

    /// Maximum number of concurrent streaming sessions.
    #[serde(default = "default_max_sessions")]
    pub max_sessions: u32,
}

// ─── Default value helpers ────────────────────────────────────────────────────

fn default_host() -> String {
    "0.0.0.0".to_string()
}

fn default_sunshine_port() -> u16 {
    47999
}

fn default_web_port() -> u16 {
    8080
}

fn default_jwt_secret() -> String {
    // In production this MUST be overridden via config or environment.
    "CHANGE_ME_IN_PRODUCTION_SECRET_KEY_32BYTES".to_string()
}

fn default_admin_password_hash() -> String {
    // bcrypt hash of "admin" with cost 12 — override immediately in production.
    "$2b$12$EixZaYVK1fsbw1ZfbX3OXePaWxn96p36WQoeG6Lruj3vjPGga31lW".to_string()
}

fn default_ice_servers() -> Vec<IceServer> {
    vec![
        IceServer {
            urls: vec!["stun:stun.l.google.com:19302".to_string()],
            username: None,
            credential: None,
        },
        IceServer {
            urls: vec!["stun:stun1.l.google.com:19302".to_string()],
            username: None,
            credential: None,
        },
        IceServer {
            urls: vec!["stun:stun2.l.google.com:19302".to_string()],
            username: None,
            credential: None,
        },
    ]
}

fn default_max_sessions() -> u32 {
    10
}

// ─── Public API ───────────────────────────────────────────────────────────────

/// Load and validate an `AppConfig` from a TOML file at `path`.
pub fn load_config(path: &str) -> anyhow::Result<AppConfig> {
    let raw = fs::read_to_string(path)
        .map_err(|e| anyhow::anyhow!("Failed to read config file '{}': {}", path, e))?;

    let config: AppConfig = toml::from_str(&raw)
        .map_err(|e| anyhow::anyhow!("Failed to parse config file '{}': {}", path, e))?;

    validate_config(&config)?;
    Ok(config)
}

/// Validate required fields and logical consistency.
fn validate_config(cfg: &AppConfig) -> anyhow::Result<()> {
    if cfg.jwt_secret.len() < 32 {
        anyhow::bail!("jwt_secret must be at least 32 characters long");
    }
    if cfg.admin_password_hash.is_empty() {
        anyhow::bail!("admin_password_hash must not be empty");
    }
    if cfg.sunshine_port == 0 {
        anyhow::bail!("sunshine_port must not be 0");
    }
    if cfg.web_port == 0 {
        anyhow::bail!("web_port must not be 0");
    }
    if cfg.max_sessions == 0 {
        anyhow::bail!("max_sessions must be at least 1");
    }
    Ok(())
}

/// Return an `AppConfig` populated with sensible defaults (no file required).
pub fn default_config() -> AppConfig {
    AppConfig {
        host: default_host(),
        sunshine_port: default_sunshine_port(),
        web_port: default_web_port(),
        tls_cert: String::new(),
        tls_key: String::new(),
        jwt_secret: default_jwt_secret(),
        admin_password_hash: default_admin_password_hash(),
        ice_servers: default_ice_servers(),
        max_sessions: default_max_sessions(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_is_valid() {
        let cfg = default_config();
        validate_config(&cfg).expect("default config should be valid");
    }

    #[test]
    fn default_ice_servers_are_non_empty() {
        let cfg = default_config();
        assert!(!cfg.ice_servers.is_empty());
    }

    #[test]
    fn short_jwt_secret_is_rejected() {
        let mut cfg = default_config();
        cfg.jwt_secret = "short".to_string();
        assert!(validate_config(&cfg).is_err());
    }
}
