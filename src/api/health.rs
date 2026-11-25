//! `GET /health`

pub async fn health() -> &'static str {
    "sharp-account is alive"
}
