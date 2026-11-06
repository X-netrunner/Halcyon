//! Spotify PKCE authentication flow and loopback callback server.
//!
//! 1. Generates PKCE code verifier and S256 code challenge.
//! 2. Binds a lightweight loopback server on `127.0.0.1:<port>/callback` (never localhost).
//! 3. Exchanges authorization code for tokens and persists them.
//! 4. Refreshes tokens before expiry or on 401.

use crate::token_store::{save_token, TokenData};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use rand::RngCore;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tracing::{debug, info};

pub const DEFAULT_PORT: u16 = 8888;
pub const SPOTIFY_AUTH_URL: &str = "https://accounts.spotify.com/authorize";
pub const SPOTIFY_TOKEN_URL: &str = "https://accounts.spotify.com/api/token";

pub const SCOPES: &str = "user-read-playback-state user-modify-playback-state user-read-currently-playing playlist-read-private playlist-read-collaborative user-library-read user-read-recently-played user-top-read streaming";

#[derive(Debug, Clone)]
pub struct PkceSession {
    pub client_id: String,
    pub code_verifier: String,
    pub state: String,
    pub port: u16,
    pub redirect_uri: String,
    pub auth_url: String,
}

#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: String,
    token_type: String,
    expires_in: u64,
    refresh_token: Option<String>,
    scope: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TokenErrorResponse {
    error: String,
    error_description: Option<String>,
}

/// Generate PKCE session with verifier, challenge and loopback listener.
pub async fn start_pkce_flow(client_id: &str) -> Result<(PkceSession, TcpListener), String> {
    // Generate 64 random bytes for verifier
    let mut verifier_bytes = [0u8; 64];
    rand::thread_rng().fill_bytes(&mut verifier_bytes);
    let code_verifier = URL_SAFE_NO_PAD.encode(verifier_bytes);

    // S256 code challenge
    let mut hasher = Sha256::new();
    hasher.update(code_verifier.as_bytes());
    let hash = hasher.finalize();
    let code_challenge = URL_SAFE_NO_PAD.encode(hash);

    // Random state
    let mut state_bytes = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut state_bytes);
    let state = URL_SAFE_NO_PAD.encode(state_bytes);

    // Try default port 8888 first, fallback to ephemeral port 0
    let listener = match TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], DEFAULT_PORT))).await {
        Ok(l) => l,
        Err(_) => {
            TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], 0)))
                .await
                .map_err(|e| format!("unable to bind loopback server: {e}"))?
        }
    };

    let local_addr = listener
        .local_addr()
        .map_err(|e| format!("unable to get local addr: {e}"))?;
    let port = local_addr.port();
    let redirect_uri = format!("http://127.0.0.1:{port}/callback");

    // Build authorization URL
    let auth_url = format!(
        "{}?client_id={}&response_type=code&redirect_uri={}&code_challenge_method=S256&code_challenge={}&state={}&scope={}",
        SPOTIFY_AUTH_URL,
        urlencoding(client_id),
        urlencoding(&redirect_uri),
        urlencoding(&code_challenge),
        urlencoding(&state),
        urlencoding(SCOPES)
    );

    let session = PkceSession {
        client_id: client_id.to_string(),
        code_verifier,
        state,
        port,
        redirect_uri,
        auth_url,
    };

    Ok((session, listener))
}

/// Wait on the loopback listener for the authorization callback.
pub async fn wait_for_callback(
    listener: TcpListener,
    expected_state: &str,
    timeout: Duration,
) -> Result<String, String> {
    let accept_future = async {
        let (mut socket, _) = listener
            .accept()
            .await
            .map_err(|e| format!("loopback accept failed: {e}"))?;

        let mut buf = [0u8; 2048];
        let n = socket
            .read(&mut buf)
            .await
            .map_err(|e| format!("reading callback failed: {e}"))?;

        let request = String::from_utf8_lossy(buf.get(..n).unwrap_or(&[]));
        let first_line = request.lines().next().unwrap_or("");

        // Parse GET /callback?code=...&state=... HTTP/1.1
        let path_and_query = first_line.split_whitespace().nth(1).unwrap_or("");
        let query_str = path_and_query.split('?').nth(1).unwrap_or("");
        let params = parse_query(query_str);

        let error = params.get("error");
        if let Some(err) = error {
            let desc = params.get("error_description").cloned().unwrap_or_default();
            let body = format!("<html><body><h2>Spotify Authorization Failed</h2><p>{err}: {desc}</p></body></html>");
            let resp = format!(
                "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            let _ = socket.write_all(resp.as_bytes()).await;
            return Err(format!("authorization error: {err} ({desc})"));
        }

        let state = params.get("state").cloned().unwrap_or_default();
        if state != expected_state {
            let body = "<html><body><h2>State mismatch</h2><p>Possible CSRF attack prevented.</p></body></html>";
            let resp = format!(
                "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            let _ = socket.write_all(resp.as_bytes()).await;
            return Err("state mismatch in OAuth callback".to_string());
        }

        let code = match params.get("code") {
            Some(c) => c.clone(),
            None => {
                let body = "<html><body><h2>Missing code</h2></body></html>";
                let resp = format!(
                    "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = socket.write_all(resp.as_bytes()).await;
                return Err("missing code parameter in OAuth callback".to_string());
            }
        };

        // Render sleek Halcyon success response page
        let body = r#"<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Halcyon Music — Connected</title>
<style>
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f1115; color: #e6e8ed; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
.card { background: #181b22; border: 1px solid #2a2f3a; border-radius: 12px; padding: 36px 48px; text-align: center; box-shadow: 0 8px 32px rgba(0,0,0,0.4); max-width: 420px; }
h1 { font-size: 24px; margin-bottom: 8px; color: #a6d189; }
p { font-size: 15px; color: #9da5b4; line-height: 1.5; margin: 0 0 20px 0; }
.badge { display: inline-block; padding: 6px 14px; background: #262b36; border-radius: 20px; font-size: 13px; color: #cad3f5; }
</style>
</head>
<body>
<div class="card">
<h1>Connected to Spotify</h1>
<p>Halcyon Music is now connected. You can close this tab and return to the music player.</p>
<div class="badge">Halcyon Rice</div>
</div>
</body>
</html>"#;
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        let _ = socket.write_all(resp.as_bytes()).await;
        let _ = socket.flush().await;

        Ok(code)
    };

    match tokio::time::timeout(timeout, accept_future).await {
        Ok(res) => res,
        Err(_) => Err("timeout waiting for browser callback (60s)".to_string()),
    }
}

/// Exchange authorization code for TokenData.
pub async fn exchange_code(
    client: &reqwest::Client,
    session: &PkceSession,
    code: &str,
) -> Result<TokenData, String> {
    let mut params = HashMap::new();
    params.insert("grant_type", "authorization_code");
    params.insert("code", code);
    params.insert("redirect_uri", &session.redirect_uri);
    params.insert("client_id", &session.client_id);
    params.insert("code_verifier", &session.code_verifier);

    let resp = client
        .post(SPOTIFY_TOKEN_URL)
        .form(&params)
        .timeout(Duration::from_secs(8))
        .send()
        .await
        .map_err(|e| format!("failed to send token exchange request: {e}"))?;

    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| format!("failed to read token exchange response: {e}"))?;

    if !status.is_success() {
        if let Ok(err) = serde_json::from_str::<TokenErrorResponse>(&text) {
            let desc = err.error_description.unwrap_or_default();
            return Err(format!("token exchange error: {} ({desc})", err.error));
        }
        return Err(format!("token exchange HTTP error {status}: {text}"));
    }

    let token_resp = serde_json::from_str::<TokenResponse>(&text)
        .map_err(|e| format!("failed to parse token response: {e} (body: {text})"))?;

    let refresh_token = match token_resp.refresh_token {
        Some(rt) => rt,
        None => return Err("missing refresh_token in Spotify token response".to_string()),
    };

    let scopes: Vec<String> = token_resp
        .scope
        .as_deref()
        .unwrap_or("")
        .split_whitespace()
        .map(String::from)
        .collect();

    let token = TokenData::new(
        session.client_id.clone(),
        token_resp.access_token,
        refresh_token,
        token_resp.expires_in,
        token_resp.token_type,
        scopes,
    );

    save_token(&token)?;
    info!("Spotify authorization code successfully exchanged for tokens");
    Ok(token)
}

/// Refresh an existing token using the refresh_token grant.
pub async fn refresh_access_token(
    client: &reqwest::Client,
    token: &TokenData,
    token_url: Option<&str>,
) -> Result<TokenData, String> {
    let url = token_url.unwrap_or(SPOTIFY_TOKEN_URL);
    let mut params = HashMap::new();
    params.insert("grant_type", "refresh_token");
    params.insert("refresh_token", token.refresh_token.as_str());
    params.insert("client_id", token.client_id.as_str());

    let resp = client
        .post(url)
        .form(&params)
        .timeout(Duration::from_secs(8))
        .send()
        .await
        .map_err(|e| format!("refresh request network error: {e}"))?;

    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| format!("refresh response read error: {e}"))?;

    if !status.is_success() {
        if let Ok(err) = serde_json::from_str::<TokenErrorResponse>(&text) {
            let desc = err.error_description.unwrap_or_default();
            return Err(format!("token refresh rejected: {} ({desc})", err.error));
        }
        return Err(format!("token refresh failed HTTP {status}: {text}"));
    }

    let token_resp = serde_json::from_str::<TokenResponse>(&text)
        .map_err(|e| format!("failed to parse token refresh response: {e}"))?;

    // Spotify might return a new refresh_token or keep the old one
    let refresh_token = token_resp
        .refresh_token
        .unwrap_or_else(|| token.refresh_token.clone());

    let scopes = if let Some(s) = token_resp.scope {
        s.split_whitespace().map(String::from).collect()
    } else {
        token.scopes.clone()
    };

    let updated = TokenData::new(
        token.client_id.clone(),
        token_resp.access_token,
        refresh_token,
        token_resp.expires_in,
        token_resp.token_type,
        scopes,
    );

    save_token(&updated)?;
    debug!("token successfully refreshed and saved");
    Ok(updated)
}

fn parse_query(q: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();
    for part in q.split('&') {
        let mut kv = part.splitn(2, '=');
        let k = kv.next().unwrap_or("");
        let v = kv.next().unwrap_or("");
        if !k.is_empty() {
            let decoded_k = urldecode(k);
            let decoded_v = urldecode(v);
            map.insert(decoded_k, decoded_v);
        }
    }
    map
}

fn urlencoding(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

fn urldecode(s: &str) -> String {
    let mut out = Vec::new();
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes.get(i).copied().unwrap_or(0);
        if b == b'%' && i + 2 < bytes.len() {
            let h1 = bytes.get(i + 1).copied().unwrap_or(0);
            let h2 = bytes.get(i + 2).copied().unwrap_or(0);
            if let Ok(val) = u8::from_str_radix(
                &format!("{}{}", h1 as char, h2 as char),
                16,
            ) {
                out.push(val);
                i += 3;
                continue;
            }
        } else if b == b'+' {
            out.push(b' ');
            i += 1;
            continue;
        }
        out.push(b);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_query_test() {
        let q = "code=AQD123&state=xyz%20123&foo=bar+baz";
        let parsed = parse_query(q);
        assert_eq!(parsed.get("code").map(|s| s.as_str()), Some("AQD123"));
        assert_eq!(parsed.get("state").map(|s| s.as_str()), Some("xyz 123"));
        assert_eq!(parsed.get("foo").map(|s| s.as_str()), Some("bar baz"));
    }

    #[tokio::test]
    async fn pkce_session_generation() {
        let (session, _listener) = start_pkce_flow("client123").await.expect("pkce start");
        assert_eq!(session.client_id, "client123");
        assert!(!session.code_verifier.is_empty());
        assert!(!session.state.is_empty());
        assert!(session.redirect_uri.starts_with("http://127.0.0.1:"));
        assert!(session.redirect_uri.ends_with("/callback"));
        assert!(session.auth_url.contains("client_id=client123"));
        assert!(session.auth_url.contains("code_challenge_method=S256"));
    }
}
