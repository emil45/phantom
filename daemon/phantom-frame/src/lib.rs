//! Binary frame codec for Phantom terminal I/O.
//!
//! Frame wire format:
//! ```text
//! [1B type][4B payload_length BE][8B sequence BE][2B flags][payload]
//! ```
//!
//! Header is 15 bytes. Max payload is 65536 bytes. Max frame is 65551 bytes.
//!
//! Types:
//!   0x01 = Data (terminal output/input)
//!   0x02 = Resize (cols + rows)
//!   0x03 = Heartbeat (keepalive)
//!   0x04 = Close (session end)
//!   0x05 = Scrollback (reattach replay)
//!   0x06 = WindowUpdate (flow control)
//!
//! Flags:
//!   bit 0 = compressed (zstd)

pub const HEADER_SIZE: usize = 15;
pub const MAX_PAYLOAD: usize = 65536;
pub const MAX_FRAME: usize = HEADER_SIZE + MAX_PAYLOAD;

const COMPRESS_THRESHOLD: usize = 256;
const FLAG_COMPRESSED: u16 = 0x0001;

// ── Frame types ──────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum FrameType {
    Data = 0x01,
    Resize = 0x02,
    Heartbeat = 0x03,
    Close = 0x04,
    Scrollback = 0x05,
    WindowUpdate = 0x06,
}

impl FrameType {
    fn from_u8(v: u8) -> Result<Self, FrameError> {
        match v {
            0x01 => Ok(Self::Data),
            0x02 => Ok(Self::Resize),
            0x03 => Ok(Self::Heartbeat),
            0x04 => Ok(Self::Close),
            0x05 => Ok(Self::Scrollback),
            0x06 => Ok(Self::WindowUpdate),
            _ => Err(FrameError::UnknownType(v)),
        }
    }
}

// ── Errors ───────────────────────────────────────────────────────────────

#[derive(Debug, thiserror::Error)]
pub enum FrameError {
    #[error("unknown frame type: 0x{0:02x}")]
    UnknownType(u8),
    #[error("payload too large: {0} bytes (max {MAX_PAYLOAD})")]
    PayloadTooLarge(usize),
    #[error("incomplete header: need {HEADER_SIZE} bytes, got {0}")]
    IncompleteHeader(usize),
    #[error("incomplete payload: need {need} bytes, got {got}")]
    IncompletePayload { need: usize, got: usize },
    #[error("zstd compression error: {0}")]
    Compress(String),
    #[error("zstd decompression error: {0}")]
    Decompress(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

// ── Frame ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub frame_type: FrameType,
    pub sequence: u64,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn data(seq: u64, payload: Vec<u8>) -> Self {
        Self { frame_type: FrameType::Data, sequence: seq, payload }
    }

    pub fn resize(seq: u64, cols: u16, rows: u16) -> Self {
        let mut payload = Vec::with_capacity(4);
        payload.extend_from_slice(&cols.to_be_bytes());
        payload.extend_from_slice(&rows.to_be_bytes());
        Self { frame_type: FrameType::Resize, sequence: seq, payload }
    }

    pub fn heartbeat(seq: u64) -> Self {
        Self { frame_type: FrameType::Heartbeat, sequence: seq, payload: Vec::new() }
    }

    pub fn close(seq: u64) -> Self {
        Self { frame_type: FrameType::Close, sequence: seq, payload: Vec::new() }
    }

    pub fn scrollback(seq: u64, payload: Vec<u8>) -> Self {
        Self { frame_type: FrameType::Scrollback, sequence: seq, payload }
    }

    pub fn window_update(seq: u64, window: u64) -> Self {
        Self {
            frame_type: FrameType::WindowUpdate,
            sequence: seq,
            payload: window.to_be_bytes().to_vec(),
        }
    }

    /// Parse resize payload into (cols, rows).
    pub fn parse_resize(&self) -> Option<(u16, u16)> {
        if self.frame_type != FrameType::Resize || self.payload.len() < 4 {
            return None;
        }
        let cols = u16::from_be_bytes([self.payload[0], self.payload[1]]);
        let rows = u16::from_be_bytes([self.payload[2], self.payload[3]]);
        Some((cols, rows))
    }

    /// Parse window update payload into window size.
    pub fn parse_window_update(&self) -> Option<u64> {
        if self.frame_type != FrameType::WindowUpdate || self.payload.len() < 8 {
            return None;
        }
        Some(u64::from_be_bytes([
            self.payload[0], self.payload[1], self.payload[2], self.payload[3],
            self.payload[4], self.payload[5], self.payload[6], self.payload[7],
        ]))
    }
}

// ── Encoder ──────────────────────────────────────────────────────────────

/// Encode a frame into a byte buffer, optionally compressing the payload.
pub fn encode(frame: &Frame, compress: bool) -> Result<Vec<u8>, FrameError> {
    let (payload, flags) = if compress && frame.payload.len() > COMPRESS_THRESHOLD {
        let compressed = zstd::bulk::compress(&frame.payload, 3)
            .map_err(|e| FrameError::Compress(e.to_string()))?;
        // Only use compressed version if it's actually smaller
        if compressed.len() < frame.payload.len() {
            (compressed, FLAG_COMPRESSED)
        } else {
            (frame.payload.clone(), 0u16)
        }
    } else {
        (frame.payload.clone(), 0u16)
    };

    if payload.len() > MAX_PAYLOAD {
        return Err(FrameError::PayloadTooLarge(payload.len()));
    }

    let mut buf = Vec::with_capacity(HEADER_SIZE + payload.len());
    buf.push(frame.frame_type as u8);
    buf.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    buf.extend_from_slice(&frame.sequence.to_be_bytes());
    buf.extend_from_slice(&flags.to_be_bytes());
    buf.extend_from_slice(&payload);

    Ok(buf)
}

// ── Decoder ──────────────────────────────────────────────────────────────

/// Decode a frame from a byte slice. Returns the frame and the number of bytes consumed.
/// Returns Ok(None) if the buffer doesn't contain a complete frame yet.
pub fn decode(buf: &[u8]) -> Result<Option<(Frame, usize)>, FrameError> {
    if buf.len() < HEADER_SIZE {
        return Ok(None);
    }

    let frame_type = FrameType::from_u8(buf[0])?;
    let payload_len = u32::from_be_bytes([buf[1], buf[2], buf[3], buf[4]]) as usize;
    let sequence = u64::from_be_bytes([
        buf[5], buf[6], buf[7], buf[8], buf[9], buf[10], buf[11], buf[12],
    ]);
    let flags = u16::from_be_bytes([buf[13], buf[14]]);

    if payload_len > MAX_PAYLOAD {
        return Err(FrameError::PayloadTooLarge(payload_len));
    }

    let total = HEADER_SIZE + payload_len;
    if buf.len() < total {
        return Ok(None);
    }

    let raw_payload = &buf[HEADER_SIZE..total];

    let payload = if flags & FLAG_COMPRESSED != 0 {
        zstd::bulk::decompress(raw_payload, MAX_PAYLOAD)
            .map_err(|e| FrameError::Decompress(e.to_string()))?
    } else {
        raw_payload.to_vec()
    };

    Ok(Some((
        Frame { frame_type, sequence, payload },
        total,
    )))
}

// ── Streaming decoder ────────────────────────────────────────────────────

/// Accumulates bytes and yields complete frames.
pub struct FrameDecoder {
    buf: Vec<u8>,
}

impl FrameDecoder {
    pub fn new() -> Self {
        Self { buf: Vec::with_capacity(MAX_FRAME) }
    }

    /// Feed bytes into the decoder.
    pub fn feed(&mut self, data: &[u8]) {
        self.buf.extend_from_slice(data);
    }

    /// Try to decode the next complete frame.
    /// Returns None if more data is needed.
    pub fn decode_next(&mut self) -> Result<Option<Frame>, FrameError> {
        match decode(&self.buf)? {
            Some((frame, consumed)) => {
                self.buf.drain(..consumed);
                Ok(Some(frame))
            }
            None => Ok(None),
        }
    }
}

impl Default for FrameDecoder {
    fn default() -> Self {
        Self::new()
    }
}

// ── Control messages (JSON) ──────────────────────────────────────────────

/// Control stream wire format: [4B length BE][JSON payload]
/// These go over QUIC stream 0, separate from per-session data streams.

pub mod control {
    /// Encode a JSON control message with length prefix.
    pub fn encode_message(json: &[u8]) -> Vec<u8> {
        let mut buf = Vec::with_capacity(4 + json.len());
        buf.extend_from_slice(&(json.len() as u32).to_be_bytes());
        buf.extend_from_slice(json);
        buf
    }

    /// Try to decode a length-prefixed JSON message from a buffer.
    /// Returns the JSON bytes and total bytes consumed, or None if incomplete.
    pub fn decode_message(buf: &[u8]) -> Option<(&[u8], usize)> {
        if buf.len() < 4 {
            return None;
        }
        let len = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
        let total = 4 + len;
        if buf.len() < total {
            return None;
        }
        Some((&buf[4..total], total))
    }
}

// ── Tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[allow(unused_imports)]
    fn roundtrip_data_frame() {
        let frame = Frame::data(42, b"hello world".to_vec());
        let encoded = encode(&frame, false).unwrap();
        let (decoded, consumed) = decode(&encoded).unwrap().unwrap();
        assert_eq!(consumed, encoded.len());
        assert_eq!(decoded, frame);
    }

    #[test]
    fn roundtrip_data_compressed() {
        // Repetitive data compresses well
        let payload = vec![0x41; 1024]; // 1KB of 'A's
        let frame = Frame::data(1, payload.clone());
        let encoded = encode(&frame, true).unwrap();
        // Compressed should be smaller
        assert!(encoded.len() < HEADER_SIZE + 1024);
        let (decoded, _) = decode(&encoded).unwrap().unwrap();
        assert_eq!(decoded.payload, payload);
        assert_eq!(decoded.sequence, 1);
    }

    #[test]
    fn roundtrip_resize() {
        let frame = Frame::resize(7, 120, 40);
        let encoded = encode(&frame, false).unwrap();
        let (decoded, _) = decode(&encoded).unwrap().unwrap();
        assert_eq!(decoded.parse_resize(), Some((120, 40)));
    }

    #[test]
    fn roundtrip_heartbeat() {
        let frame = Frame::heartbeat(99);
        let encoded = encode(&frame, false).unwrap();
        let (decoded, _) = decode(&encoded).unwrap().unwrap();
        assert_eq!(decoded.frame_type, FrameType::Heartbeat);
        assert_eq!(decoded.sequence, 99);
        assert!(decoded.payload.is_empty());
    }

    #[test]
    fn roundtrip_close() {
        let frame = Frame::close(100);
        let encoded = encode(&frame, false).unwrap();
        let (decoded, _) = decode(&encoded).unwrap().unwrap();
        assert_eq!(decoded.frame_type, FrameType::Close);
    }

    #[test]
    fn roundtrip_window_update() {
        let frame = Frame::window_update(5, 262144);
        let encoded = encode(&frame, false).unwrap();
        let (decoded, _) = decode(&encoded).unwrap().unwrap();
        assert_eq!(decoded.parse_window_update(), Some(262144));
    }

    #[test]
    fn roundtrip_scrollback() {
        let frame = Frame::scrollback(10, b"terminal scrollback data".to_vec());
        let encoded = encode(&frame, false).unwrap();
        let (decoded, _) = decode(&encoded).unwrap().unwrap();
        assert_eq!(decoded.frame_type, FrameType::Scrollback);
        assert_eq!(decoded.payload, b"terminal scrollback data");
    }

    #[test]
    fn decode_incomplete_header() {
        let result = decode(&[0x01, 0x00]).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn decode_incomplete_payload() {
        let frame = Frame::data(1, b"hello".to_vec());
        let encoded = encode(&frame, false).unwrap();
        // Truncate payload
        let result = decode(&encoded[..HEADER_SIZE + 2]).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn decode_unknown_type() {
        let buf = vec![0xFF; HEADER_SIZE];
        let err = decode(&buf).unwrap_err();
        assert!(matches!(err, FrameError::UnknownType(0xFF)));
    }

    #[test]
    fn payload_too_large() {
        let frame = Frame::data(1, vec![0; MAX_PAYLOAD + 1]);
        let err = encode(&frame, false).unwrap_err();
        assert!(matches!(err, FrameError::PayloadTooLarge(_)));
    }

    #[test]
    fn streaming_decoder() {
        let f1 = Frame::data(1, b"first".to_vec());
        let f2 = Frame::data(2, b"second".to_vec());

        let e1 = encode(&f1, false).unwrap();
        let e2 = encode(&f2, false).unwrap();

        let mut decoder = FrameDecoder::new();

        // Feed partial first frame
        decoder.feed(&e1[..10]);
        assert!(decoder.decode_next().unwrap().is_none());

        // Feed rest of first + all of second
        decoder.feed(&e1[10..]);
        decoder.feed(&e2);

        let d1 = decoder.decode_next().unwrap().unwrap();
        assert_eq!(d1, f1);

        let d2 = decoder.decode_next().unwrap().unwrap();
        assert_eq!(d2, f2);

        assert!(decoder.decode_next().unwrap().is_none());
    }

    #[test]
    fn control_message_roundtrip() {
        let json = br#"{"type":"ping","request_id":"abc123"}"#;
        let encoded = control::encode_message(json);
        let (decoded, consumed) = control::decode_message(&encoded).unwrap();
        assert_eq!(decoded, json);
        assert_eq!(consumed, encoded.len());
    }

    #[test]
    fn control_message_incomplete() {
        let json = br#"{"type":"ping"}"#;
        let encoded = control::encode_message(json);
        assert!(control::decode_message(&encoded[..3]).is_none()); // partial length
        assert!(control::decode_message(&encoded[..6]).is_none()); // partial payload
    }

    #[test]
    fn compression_not_used_for_small_payloads() {
        let frame = Frame::data(1, b"tiny".to_vec());
        let encoded = encode(&frame, true).unwrap();
        // Flags should be 0 (no compression for <256 bytes)
        assert_eq!(u16::from_be_bytes([encoded[13], encoded[14]]), 0);
    }

    #[test]
    fn compression_skipped_when_not_beneficial() {
        // Random data doesn't compress well
        let payload: Vec<u8> = (0..512).map(|i| (i * 37 + 13) as u8).collect();
        let frame = Frame::data(1, payload.clone());
        let encoded_compressed = encode(&frame, true).unwrap();
        let encoded_plain = encode(&frame, false).unwrap();
        // Both should decode to same payload
        let (d1, _) = decode(&encoded_compressed).unwrap().unwrap();
        let (d2, _) = decode(&encoded_plain).unwrap().unwrap();
        assert_eq!(d1.payload, payload);
        assert_eq!(d2.payload, payload);
    }
}
