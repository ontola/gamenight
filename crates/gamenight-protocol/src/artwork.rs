//! Small reusable game art. Titles and colors remain the fallback.
use base64::{engine::general_purpose::STANDARD, Engine};
pub const MAX_PNG_BYTES: usize = 256 * 1024;
pub const MAX_DIMENSION: u32 = 1024;
pub const PNG_PREFIX: &str = "data:image/png;base64,";
pub fn valid_png(bytes: &[u8]) -> bool {
    if bytes.len() < 33
        || bytes.len() > MAX_PNG_BYTES
        || !bytes.starts_with(b"\x89PNG\r\n\x1a\n")
        || &bytes[12..16] != b"IHDR"
    {
        return false;
    }
    let width = u32::from_be_bytes(bytes[16..20].try_into().unwrap());
    let height = u32::from_be_bytes(bytes[20..24].try_into().unwrap());
    (1..=MAX_DIMENSION).contains(&width) && (1..=MAX_DIMENSION).contains(&height)
}
pub fn png_data_uri(bytes: &[u8]) -> Option<String> {
    valid_png(bytes).then(|| format!("{PNG_PREFIX}{}", STANDARD.encode(bytes)))
}
pub fn decode_png_data_uri(value: &str) -> Option<Vec<u8>> {
    let encoded = value.strip_prefix(PNG_PREFIX)?;
    if encoded.len() > MAX_PNG_BYTES.div_ceil(3) * 4 {
        return None;
    }
    let bytes = STANDARD.decode(encoded).ok()?;
    valid_png(&bytes).then_some(bytes)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_oversized_or_non_png_art() {
        assert!(png_data_uri(b"not an image").is_none());
        assert!(decode_png_data_uri("data:image/svg+xml;base64,AAAA").is_none());
        let mut png = vec![0; 33];
        png[..8].copy_from_slice(b"\x89PNG\r\n\x1a\n");
        png[12..16].copy_from_slice(b"IHDR");
        png[16..20].copy_from_slice(&128u32.to_be_bytes());
        png[20..24].copy_from_slice(&128u32.to_be_bytes());
        let uri = png_data_uri(&png).unwrap();
        assert_eq!(decode_png_data_uri(&uri), Some(png.clone()));
        png[16..20].copy_from_slice(&2048u32.to_be_bytes());
        assert!(png_data_uri(&png).is_none());
    }
}
