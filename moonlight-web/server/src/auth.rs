use std::{
    future::{ready, Ready},
    rc::Rc,
};

use actix_web::{
    body::EitherBody,
    dev::{forward_ready, Service, ServiceRequest, ServiceResponse, Transform},
    http::header,
    Error, HttpResponse,
};
use bcrypt::{hash, verify, DEFAULT_COST};
use futures_util::future::LocalBoxFuture;
use jsonwebtoken::{
    decode, encode, Algorithm, DecodingKey, EncodingKey, Header, TokenData, Validation,
};
use serde::{Deserialize, Serialize};

// ─── JWT Claims ───────────────────────────────────────────────────────────────

/// JWT payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Claims {
    /// Subject — the username.
    pub sub: String,
    /// Expiry as a Unix timestamp (seconds since epoch).
    pub exp: usize,
    /// Role assigned to this token (e.g. "admin").
    pub role: String,
}

// ─── Token helpers ────────────────────────────────────────────────────────────

/// Create a signed HS256 JWT valid for 24 hours.
pub fn create_token(username: &str, secret: &str) -> anyhow::Result<String> {
    let expiry = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs() as usize
        + 86_400; // 24 h

    let claims = Claims {
        sub: username.to_string(),
        exp: expiry,
        role: "admin".to_string(),
    };

    let token = encode(
        &Header::new(Algorithm::HS256),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )?;

    Ok(token)
}

/// Verify a JWT and return its decoded claims.
pub fn verify_token(token: &str, secret: &str) -> anyhow::Result<Claims> {
    let mut validation = Validation::new(Algorithm::HS256);
    validation.validate_exp = true;

    let token_data: TokenData<Claims> = decode(
        token,
        &DecodingKey::from_secret(secret.as_bytes()),
        &validation,
    )?;

    Ok(token_data.claims)
}

// ─── Password helpers ─────────────────────────────────────────────────────────

/// Hash a plaintext password using bcrypt with cost 12.
pub fn hash_password(password: &str) -> anyhow::Result<String> {
    let hashed = hash(password, 12)?;
    Ok(hashed)
}

/// Verify a plaintext password against a stored bcrypt hash.
pub fn verify_password(password: &str, hashed: &str) -> anyhow::Result<bool> {
    let valid = verify(password, hashed)?;
    Ok(valid)
}

// ─── Auth Middleware ──────────────────────────────────────────────────────────

/// Actix-web `Transform` that enforces Bearer JWT authentication.
///
/// Attach it to a scope or individual route:
/// ```ignore
/// web::scope("/api/protected")
///     .wrap(AuthMiddleware::new(jwt_secret.clone()))
/// ```
#[derive(Clone)]
pub struct AuthMiddleware {
    secret: Rc<String>,
}

impl AuthMiddleware {
    pub fn new(secret: String) -> Self {
        AuthMiddleware {
            secret: Rc::new(secret),
        }
    }
}

impl<S, B> Transform<S, ServiceRequest> for AuthMiddleware
where
    S: Service<ServiceRequest, Response = ServiceResponse<B>, Error = Error> + 'static,
    B: 'static,
{
    type Response = ServiceResponse<EitherBody<B>>;
    type Error = Error;
    type InitError = ();
    type Transform = AuthMiddlewareService<S>;
    type Future = Ready<Result<Self::Transform, Self::InitError>>;

    fn new_transform(&self, service: S) -> Self::Future {
        ready(Ok(AuthMiddlewareService {
            service: Rc::new(service),
            secret: self.secret.clone(),
        }))
    }
}

pub struct AuthMiddlewareService<S> {
    service: Rc<S>,
    secret: Rc<String>,
}

impl<S, B> Service<ServiceRequest> for AuthMiddlewareService<S>
where
    S: Service<ServiceRequest, Response = ServiceResponse<B>, Error = Error> + 'static,
    B: 'static,
{
    type Response = ServiceResponse<EitherBody<B>>;
    type Error = Error;
    type Future = LocalBoxFuture<'static, Result<Self::Response, Self::Error>>;

    forward_ready!(service);

    fn call(&self, req: ServiceRequest) -> Self::Future {
        let service = self.service.clone();
        let secret = self.secret.clone();

        Box::pin(async move {
            // Extract the Bearer token from the Authorization header.
            let auth_header = req
                .headers()
                .get(header::AUTHORIZATION)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("");

            if !auth_header.starts_with("Bearer ") {
                let (req, _payload) = req.into_parts();
                let response = HttpResponse::Unauthorized()
                    .json(serde_json::json!({
                        "error": "Missing or malformed Authorization header"
                    }))
                    .map_into_right_body();
                return Ok(ServiceResponse::new(req, response));
            }

            let token = &auth_header["Bearer ".len()..];

            match verify_token(token, &secret) {
                Ok(_claims) => {
                    // Token valid — pass request through.
                    let res = service.call(req).await?;
                    Ok(res.map_into_left_body())
                }
                Err(e) => {
                    log::warn!("JWT verification failed: {}", e);
                    let (req, _payload) = req.into_parts();
                    let response = HttpResponse::Unauthorized()
                        .json(serde_json::json!({ "error": "Invalid or expired token" }))
                        .map_into_right_body();
                    Ok(ServiceResponse::new(req, response))
                }
            }
        })
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &str = "super_secret_key_for_tests_only_32b";

    #[test]
    fn round_trip_token() {
        let token = create_token("alice", SECRET).unwrap();
        let claims = verify_token(&token, SECRET).unwrap();
        assert_eq!(claims.sub, "alice");
        assert_eq!(claims.role, "admin");
    }

    #[test]
    fn wrong_secret_is_rejected() {
        let token = create_token("bob", SECRET).unwrap();
        assert!(verify_token(&token, "wrong_secret_32_characters_long__").is_err());
    }

    #[test]
    fn password_round_trip() {
        let hash = hash_password("hunter2").unwrap();
        assert!(verify_password("hunter2", &hash).unwrap());
        assert!(!verify_password("wrong", &hash).unwrap());
    }

    #[test]
    fn bcrypt_cost_is_twelve() {
        // bcrypt hash format: $2b$<cost>$...
        let hash = hash_password("test").unwrap();
        assert!(hash.starts_with("$2b$12$"), "expected cost 12, got: {}", hash);
    }
}
