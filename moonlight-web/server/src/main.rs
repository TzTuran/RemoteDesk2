mod auth;
mod config;
mod signaling;

use std::{
    collections::HashMap,
    fs::File,
    io::BufReader,
    net::IpAddr,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use actix_web::{
    dev::{forward_ready, Service, ServiceRequest, ServiceResponse, Transform},
    http::header::{self, HeaderName, HeaderValue},
    middleware::Logger,
    web, App, HttpRequest, HttpResponse, HttpServer,
};
use clap::Parser;
use futures_util::future::{ready, LocalBoxFuture, Ready};
use log::{error, info, warn};
use rustls::{pki_types::PrivateKeyDer, ServerConfig};
use rustls_pemfile::{certs, pkcs8_private_keys};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    auth::AuthMiddleware,
    config::{default_config, load_config, AppConfig},
};

// ─── Embedded static files ───────────────────────────────────────────────────

#[derive(rust_embed::RustEmbed)]
#[folder = "../static/"]
struct StaticAssets;

// ─── CLI arguments ────────────────────────────────────────────────────────────

#[derive(Parser, Debug)]
#[command(
    name = "web-server",
    about = "Moonlight-Web backend server",
    version = "1.0.0"
)]
struct Cli {
    /// TCP port to listen on.
    #[arg(long, default_value_t = 8080)]
    port: u16,

    /// Path to TLS certificate PEM file (optional; omit for HTTP dev mode).
    #[arg(long)]
    tls_cert: Option<String>,

    /// Path to TLS private key PEM file (optional; omit for HTTP dev mode).
    #[arg(long)]
    tls_key: Option<String>,

    /// Path to TOML config file.
    #[arg(long)]
    config: Option<String>,
}

// ─── Rate limiter ─────────────────────────────────────────────────────────────

/// Simple token-bucket rate limiter (10 tokens/s per IP).
#[derive(Clone, Default)]
struct RateLimiter {
    /// Map from IP address to `(tokens, last_refill_instant)`.
    buckets: Arc<Mutex<HashMap<IpAddr, (f64, Instant)>>>,
}

const RATE_LIMIT_CAPACITY: f64 = 10.0; // max burst
const RATE_LIMIT_REFILL_PER_SEC: f64 = 10.0; // steady-state tokens/sec

impl RateLimiter {
    /// Returns `true` if the request is allowed for `ip`.
    fn check(&self, ip: IpAddr) -> bool {
        let mut buckets = self.buckets.lock().unwrap();
        let now = Instant::now();
        let (tokens, last) = buckets
            .entry(ip)
            .or_insert((RATE_LIMIT_CAPACITY, now));

        let elapsed = now.duration_since(*last).as_secs_f64();
        *tokens = (*tokens + elapsed * RATE_LIMIT_REFILL_PER_SEC).min(RATE_LIMIT_CAPACITY);
        *last = now;

        if *tokens >= 1.0 {
            *tokens -= 1.0;
            true
        } else {
            false
        }
    }
}

// ─── Rate-limit middleware ────────────────────────────────────────────────────

struct RateLimitMiddleware(RateLimiter);

impl<S, B> Transform<S, ServiceRequest> for RateLimitMiddleware
where
    S: Service<ServiceRequest, Response = ServiceResponse<B>, Error = actix_web::Error> + 'static,
    B: 'static,
{
    type Response = ServiceResponse<actix_web::body::EitherBody<B>>;
    type Error = actix_web::Error;
    type InitError = ();
    type Transform = RateLimitService<S>;
    type Future = Ready<Result<Self::Transform, Self::InitError>>;

    fn new_transform(&self, service: S) -> Self::Future {
        ready(Ok(RateLimitService {
            service: std::rc::Rc::new(service),
            limiter: self.0.clone(),
        }))
    }
}

struct RateLimitService<S> {
    service: std::rc::Rc<S>,
    limiter: RateLimiter,
}

impl<S, B> Service<ServiceRequest> for RateLimitService<S>
where
    S: Service<ServiceRequest, Response = ServiceResponse<B>, Error = actix_web::Error> + 'static,
    B: 'static,
{
    type Response = ServiceResponse<actix_web::body::EitherBody<B>>;
    type Error = actix_web::Error;
    type Future = LocalBoxFuture<'static, Result<Self::Response, Self::Error>>;

    forward_ready!(service);

    fn call(&self, req: ServiceRequest) -> Self::Future {
        let ip = req
            .connection_info()
            .realip_remote_addr()
            .unwrap_or("0.0.0.0")
            .split(':')
            .next()
            .unwrap_or("0.0.0.0")
            .parse::<IpAddr>()
            .unwrap_or(IpAddr::from([0, 0, 0, 0]));

        if !self.limiter.check(ip) {
            warn!("[rate-limit] Too many requests from {}", ip);
            let (req, _) = req.into_parts();
            let resp = HttpResponse::TooManyRequests()
                .json(serde_json::json!({ "error": "Too many requests" }))
                .map_into_right_body();
            return Box::pin(ready(Ok(ServiceResponse::new(req, resp))));
        }

        let svc = self.service.clone();
        Box::pin(async move {
            let res = svc.call(req).await?;
            Ok(res.map_into_left_body())
        })
    }
}

// ─── Security headers middleware ──────────────────────────────────────────────

struct SecurityHeaders;

impl<S, B> Transform<S, ServiceRequest> for SecurityHeaders
where
    S: Service<ServiceRequest, Response = ServiceResponse<B>, Error = actix_web::Error> + 'static,
    B: 'static,
{
    type Response = ServiceResponse<B>;
    type Error = actix_web::Error;
    type InitError = ();
    type Transform = SecurityHeadersService<S>;
    type Future = Ready<Result<Self::Transform, Self::InitError>>;

    fn new_transform(&self, service: S) -> Self::Future {
        ready(Ok(SecurityHeadersService {
            service: std::rc::Rc::new(service),
        }))
    }
}

struct SecurityHeadersService<S> {
    service: std::rc::Rc<S>,
}

impl<S, B> Service<ServiceRequest> for SecurityHeadersService<S>
where
    S: Service<ServiceRequest, Response = ServiceResponse<B>, Error = actix_web::Error> + 'static,
    B: 'static,
{
    type Response = ServiceResponse<B>;
    type Error = actix_web::Error;
    type Future = LocalBoxFuture<'static, Result<Self::Response, Self::Error>>;

    forward_ready!(service);

    fn call(&self, req: ServiceRequest) -> Self::Future {
        let svc = self.service.clone();
        Box::pin(async move {
            let mut res = svc.call(req).await?;
            let headers = res.headers_mut();

            headers.insert(
                HeaderName::from_static("content-security-policy"),
                HeaderValue::from_static(
                    "default-src 'self'; \
                     script-src 'self'; \
                     style-src 'self' 'unsafe-inline'; \
                     img-src 'self' data:; \
                     connect-src 'self' wss:; \
                     frame-ancestors 'none'",
                ),
            );
            headers.insert(
                HeaderName::from_static("x-frame-options"),
                HeaderValue::from_static("DENY"),
            );
            headers.insert(
                HeaderName::from_static("strict-transport-security"),
                HeaderValue::from_static("max-age=63072000; includeSubDomains; preload"),
            );
            headers.insert(
                HeaderName::from_static("x-content-type-options"),
                HeaderValue::from_static("nosniff"),
            );
            headers.insert(
                HeaderName::from_static("referrer-policy"),
                HeaderValue::from_static("strict-origin-when-cross-origin"),
            );
            headers.insert(
                HeaderName::from_static("permissions-policy"),
                HeaderValue::from_static("geolocation=(), microphone=(), camera=()"),
            );

            Ok(res)
        })
    }
}

// ─── Request/response types ───────────────────────────────────────────────────

#[derive(Deserialize)]
struct LoginRequest {
    username: String,
    password: String,
}

#[derive(Serialize)]
struct LoginResponse {
    token: String,
    #[serde(rename = "expiresIn")]
    expires_in: u32,
}

#[derive(Serialize)]
struct HealthResponse {
    status: &'static str,
    version: &'static str,
}

#[derive(Serialize)]
struct ConfigResponse<'a> {
    host: &'a str,
    sunshine_port: u16,
    web_port: u16,
    #[serde(rename = "iceServers")]
    ice_servers: &'a Vec<config::IceServer>,
    #[serde(rename = "maxSessions")]
    max_sessions: u32,
}

// ─── Route handlers ───────────────────────────────────────────────────────────

/// `GET /` — Serve embedded index.html.
async fn serve_index() -> HttpResponse {
    match StaticAssets::get("index.html") {
        Some(content) => HttpResponse::Ok()
            .content_type("text/html; charset=utf-8")
            .insert_header((header::CACHE_CONTROL, "no-cache"))
            .body(content.data.into_owned()),
        None => HttpResponse::NotFound().body("index.html not found in embedded assets"),
    }
}

/// `GET /assets/{filename}` — Serve an embedded static asset.
async fn serve_asset(path: web::Path<String>) -> HttpResponse {
    let file_path = format!("assets/{}", path.into_inner());

    match StaticAssets::get(&file_path) {
        Some(content) => {
            let mime = mime_guess::from_path(&file_path).first_or_octet_stream();
            HttpResponse::Ok()
                .content_type(mime.as_ref())
                .insert_header((header::CACHE_CONTROL, "max-age=31536000, immutable"))
                .body(content.data.into_owned())
        }
        None => HttpResponse::NotFound().body("Asset not found"),
    }
}

/// `GET /api/health`
async fn health_handler() -> HttpResponse {
    HttpResponse::Ok().json(HealthResponse {
        status: "ok",
        version: "1.0.0",
    })
}

/// `POST /api/auth/login`
async fn login_handler(
    body: web::Json<LoginRequest>,
    config: web::Data<Arc<AppConfig>>,
) -> HttpResponse {
    // Only "admin" username is accepted in v1.
    if body.username != "admin" {
        warn!("[auth] Login attempt with unknown username: {}", body.username);
        return HttpResponse::Unauthorized()
            .json(serde_json::json!({ "error": "Invalid credentials" }));
    }

    match auth::verify_password(&body.password, &config.admin_password_hash) {
        Ok(true) => {}
        Ok(false) => {
            warn!("[auth] Invalid password for user: {}", body.username);
            return HttpResponse::Unauthorized()
                .json(serde_json::json!({ "error": "Invalid credentials" }));
        }
        Err(e) => {
            error!("[auth] bcrypt error: {}", e);
            return HttpResponse::InternalServerError()
                .json(serde_json::json!({ "error": "Authentication error" }));
        }
    }

    match auth::create_token(&body.username, &config.jwt_secret) {
        Ok(token) => {
            info!("[auth] Successful login for user: {}", body.username);
            HttpResponse::Ok().json(LoginResponse {
                token,
                expires_in: 86_400,
            })
        }
        Err(e) => {
            error!("[auth] Token creation failed: {}", e);
            HttpResponse::InternalServerError()
                .json(serde_json::json!({ "error": "Could not issue token" }))
        }
    }
}

/// `GET /api/config` (JWT-protected)
async fn config_handler(config: web::Data<Arc<AppConfig>>) -> HttpResponse {
    HttpResponse::Ok().json(ConfigResponse {
        host: &config.host,
        sunshine_port: config.sunshine_port,
        web_port: config.web_port,
        ice_servers: &config.ice_servers,
        max_sessions: config.max_sessions,
    })
}

/// `GET /api/stream/ice-servers` (JWT-protected)
async fn ice_servers_handler(config: web::Data<Arc<AppConfig>>) -> HttpResponse {
    HttpResponse::Ok().json(&config.ice_servers)
}

// ─── TLS configuration ────────────────────────────────────────────────────────

fn build_tls_config(cert_path: &str, key_path: &str) -> anyhow::Result<ServerConfig> {
    // Load certificate chain.
    let cert_file = File::open(cert_path)
        .map_err(|e| anyhow::anyhow!("Cannot open cert file '{}': {}", cert_path, e))?;
    let certs: Vec<_> = certs(&mut BufReader::new(cert_file))
        .collect::<Result<_, _>>()
        .map_err(|e| anyhow::anyhow!("Failed to parse certificates: {:?}", e))?;

    if certs.is_empty() {
        anyhow::bail!("No certificates found in '{}'", cert_path);
    }

    // Load private key.
    let key_file = File::open(key_path)
        .map_err(|e| anyhow::anyhow!("Cannot open key file '{}': {}", key_path, e))?;
    let mut keys: Vec<_> = pkcs8_private_keys(&mut BufReader::new(key_file))
        .collect::<Result<_, _>>()
        .map_err(|e| anyhow::anyhow!("Failed to parse private key: {:?}", e))?;

    if keys.is_empty() {
        anyhow::bail!("No PKCS#8 private keys found in '{}'", key_path);
    }

    let key = PrivateKeyDer::Pkcs8(keys.remove(0));

    let config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|e| anyhow::anyhow!("TLS config error: {}", e))?;

    Ok(config)
}

// ─── Main ─────────────────────────────────────────────────────────────────────

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    // Initialise logger (RUST_LOG=info by default).
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let cli = Cli::parse();

    // Load config (fall back to defaults if not provided).
    let mut app_config = match &cli.config {
        Some(path) => match load_config(path) {
            Ok(cfg) => {
                info!("Loaded config from '{}'", path);
                cfg
            }
            Err(e) => {
                error!("Failed to load config: {}. Using defaults.", e);
                default_config()
            }
        },
        None => {
            info!("No config file specified. Using defaults.");
            default_config()
        }
    };

    // CLI overrides take priority.
    app_config.web_port = cli.port;
    if let Some(ref cert) = cli.tls_cert {
        app_config.tls_cert = cert.clone();
    }
    if let Some(ref key) = cli.tls_key {
        app_config.tls_key = key.clone();
    }

    let config_data = Arc::new(app_config);
    let rate_limiter = RateLimiter::default();
    let bind_addr = format!("{}:{}", config_data.host, config_data.web_port);

    info!("Starting Moonlight-Web server on {}", bind_addr);

    // Determine whether TLS is available.
    let tls_config = if !config_data.tls_cert.is_empty() && !config_data.tls_key.is_empty() {
        match build_tls_config(&config_data.tls_cert, &config_data.tls_key) {
            Ok(cfg) => {
                info!(
                    "TLS enabled (cert={}, key={})",
                    config_data.tls_cert, config_data.tls_key
                );
                Some(cfg)
            }
            Err(e) => {
                warn!("TLS configuration failed ({}), falling back to HTTP", e);
                None
            }
        }
    } else {
        warn!("No TLS cert/key provided — running in HTTP dev mode");
        None
    };

    let config_clone = config_data.clone();

    let server = HttpServer::new(move || {
        let cfg = config_clone.clone();
        let limiter = rate_limiter.clone();
        let jwt_secret = cfg.jwt_secret.clone();

        App::new()
            .app_data(web::Data::new(cfg))
            // ── Global middleware ────────────────────────────────────────
            .wrap(SecurityHeaders)
            .wrap(Logger::new(
                r#"%a "%r" %s %b "%{Referer}i" "%{User-Agent}i" %T"#,
            ))
            // ── Static routes ────────────────────────────────────────────
            .route("/", web::get().to(serve_index))
            .route("/assets/{filename:.*}", web::get().to(serve_asset))
            // ── Public API ───────────────────────────────────────────────
            .route("/api/health", web::get().to(health_handler))
            // Auth routes — rate-limited
            .service(
                web::scope("/api/auth")
                    .wrap(RateLimitMiddleware(limiter))
                    .route("/login", web::post().to(login_handler)),
            )
            // Protected API — JWT required
            .service(
                web::scope("/api")
                    .wrap(AuthMiddleware::new(jwt_secret))
                    .route("/config", web::get().to(config_handler))
                    .route("/stream/ice-servers", web::get().to(ice_servers_handler))
                    .route(
                        "/signaling",
                        web::get().to(signaling::ws_signaling_handler),
                    ),
            )
    });

    let server = if let Some(tls) = tls_config {
        server.bind_rustls_0_22(&bind_addr, tls)?.run()
    } else {
        server.bind(&bind_addr)?.run()
    };

    // Graceful shutdown on SIGTERM/SIGINT.
    let handle = server.handle();

    tokio::spawn(async move {
        use tokio::signal;
        #[cfg(unix)]
        {
            use signal::unix::{signal as unix_signal, SignalKind};
            let mut sigterm = unix_signal(SignalKind::terminate()).expect("SIGTERM handler");
            let mut sigint = unix_signal(SignalKind::interrupt()).expect("SIGINT handler");
            tokio::select! {
                _ = sigterm.recv() => info!("Received SIGTERM — shutting down"),
                _ = sigint.recv()  => info!("Received SIGINT  — shutting down"),
            }
        }
        #[cfg(not(unix))]
        {
            signal::ctrl_c().await.expect("Ctrl-C handler");
            info!("Received Ctrl-C — shutting down");
        }
        handle.stop(true).await;
    });

    server.await
}
