use actix_web::{web, HttpRequest, HttpResponse};
use actix_ws::{Message, Session};
use std::sync::Arc;
use tokio::{
    net::TcpStream,
    sync::Mutex,
    time::{interval, Duration},
};
use tokio_tungstenite::{
    connect_async,
    tungstenite::protocol::Message as TungsteniteMessage,
    MaybeTlsStream, WebSocketStream,
};
use futures_util::{SinkExt, StreamExt};

use crate::config::AppConfig;

// ─── Handler ─────────────────────────────────────────────────────────────────

/// Actix-web handler that upgrades the incoming HTTP request to a WebSocket
/// connection and proxies all traffic bidirectionally to the Sunshine signaling
/// server running on `ws://127.0.0.1:<sunshine_port>`.
///
/// Route registration example:
/// ```ignore
/// web::resource("/api/signaling")
///     .route(web::get().to(ws_signaling_handler))
/// ```
pub async fn ws_signaling_handler(
    req: HttpRequest,
    stream: web::Payload,
    config: web::Data<Arc<AppConfig>>,
) -> Result<HttpResponse, actix_web::Error> {
    let client_ip = req
        .connection_info()
        .realip_remote_addr()
        .unwrap_or("unknown")
        .to_string();

    log::info!("[signaling] Client connected: {}", client_ip);

    let sunshine_url = format!("ws://127.0.0.1:{}/", config.sunshine_port);

    // Connect to Sunshine before accepting the client upgrade so that
    // we can reject the client immediately if Sunshine is unavailable.
    let (sunshine_ws, _response) = match connect_async(&sunshine_url).await {
        Ok(pair) => pair,
        Err(e) => {
            log::error!(
                "[signaling] Failed to connect to Sunshine at {}: {}",
                sunshine_url,
                e
            );
            return Ok(HttpResponse::ServiceUnavailable()
                .json(serde_json::json!({ "error": "Signaling upstream unavailable" })));
        }
    };

    log::info!(
        "[signaling] Connected to Sunshine signaling at {}",
        sunshine_url
    );

    // Upgrade the client connection.
    let (response, client_session, mut client_stream) = actix_ws::handle(&req, stream)?;

    // Split Sunshine stream into sink + source.
    let (sunshine_sink, sunshine_source) = sunshine_ws.split();

    let sunshine_sink = Arc::new(Mutex::new(sunshine_sink));
    let client_session = Arc::new(Mutex::new(client_session));

    // Spawn the bidirectional relay.
    let client_ip_clone = client_ip.clone();
    actix_rt::spawn(async move {
        relay(
            client_ip_clone,
            client_session,
            client_stream,
            sunshine_sink,
            sunshine_source,
        )
        .await;
    });

    Ok(response)
}

// ─── Bidirectional relay ──────────────────────────────────────────────────────

async fn relay(
    client_ip: String,
    client_session: Arc<Mutex<Session>>,
    mut client_rx: actix_ws::MessageStream,
    sunshine_tx: Arc<Mutex<futures_util::stream::SplitSink<
        WebSocketStream<MaybeTlsStream<TcpStream>>,
        TungsteniteMessage,
    >>>,
    mut sunshine_rx: futures_util::stream::SplitStream<
        WebSocketStream<MaybeTlsStream<TcpStream>>,
    >,
) {
    let mut ping_ticker = interval(Duration::from_secs(30));
    // Skip the first immediate tick.
    ping_ticker.tick().await;

    loop {
        tokio::select! {
            // ── Keepalive ping to client ──────────────────────────────────
            _ = ping_ticker.tick() => {
                let mut session = client_session.lock().await;
                if session.ping(b"keepalive").await.is_err() {
                    log::info!("[signaling] Ping failed, closing connection for {}", client_ip);
                    break;
                }
            }

            // ── Message from the browser client → Sunshine ───────────────
            msg = client_rx.next() => {
                match msg {
                    None => {
                        log::info!("[signaling] Client {} disconnected", client_ip);
                        break;
                    }
                    Some(Err(e)) => {
                        log::warn!("[signaling] Client {} stream error: {}", client_ip, e);
                        break;
                    }
                    Some(Ok(msg)) => {
                        let forward = match msg {
                            Message::Text(text) => {
                                Some(TungsteniteMessage::Text(text.to_string()))
                            }
                            Message::Binary(bin) => {
                                Some(TungsteniteMessage::Binary(bin.to_vec()))
                            }
                            Message::Ping(data) => {
                                // Reply with Pong to the client.
                                let mut session = client_session.lock().await;
                                let _ = session.pong(&data).await;
                                None
                            }
                            Message::Pong(_) => None,
                            Message::Close(reason) => {
                                log::info!(
                                    "[signaling] Client {} sent Close frame: {:?}",
                                    client_ip, reason
                                );
                                break;
                            }
                            Message::Continuation(_) => {
                                // Continuation frames are not common in signaling; ignore.
                                None
                            }
                            Message::Nop => None,
                        };

                        if let Some(fwd) = forward {
                            let mut tx = sunshine_tx.lock().await;
                            if let Err(e) = tx.send(fwd).await {
                                log::warn!(
                                    "[signaling] Failed to forward to Sunshine for {}: {}",
                                    client_ip, e
                                );
                                break;
                            }
                        }
                    }
                }
            }

            // ── Message from Sunshine → browser client ───────────────────
            msg = sunshine_rx.next() => {
                match msg {
                    None => {
                        log::info!("[signaling] Sunshine closed connection for {}", client_ip);
                        break;
                    }
                    Some(Err(e)) => {
                        log::warn!(
                            "[signaling] Sunshine stream error for {}: {}",
                            client_ip, e
                        );
                        break;
                    }
                    Some(Ok(msg)) => {
                        let mut session = client_session.lock().await;
                        let result = match msg {
                            TungsteniteMessage::Text(text) => {
                                session.text(text).await
                            }
                            TungsteniteMessage::Binary(bin) => {
                                session.binary(bin).await
                            }
                            TungsteniteMessage::Ping(data) => {
                                session.ping(&data).await
                            }
                            TungsteniteMessage::Pong(data) => {
                                session.pong(&data).await
                            }
                            TungsteniteMessage::Close(_) => {
                                log::info!(
                                    "[signaling] Sunshine sent Close frame for {}",
                                    client_ip
                                );
                                break;
                            }
                            TungsteniteMessage::Frame(_) => {
                                // Raw frames are not expected here.
                                Ok(())
                            }
                        };

                        if let Err(e) = result {
                            log::warn!(
                                "[signaling] Failed to forward to client {}: {}",
                                client_ip, e
                            );
                            break;
                        }
                    }
                }
            }
        }
    }

    // Best-effort graceful close.
    {
        let mut tx = sunshine_tx.lock().await;
        let _ = tx.send(TungsteniteMessage::Close(None)).await;
    }
    {
        let mut session = client_session.lock().await;
        let _ = session.close(None).await;
    }

    log::info!("[signaling] Relay closed for {}", client_ip);
}
