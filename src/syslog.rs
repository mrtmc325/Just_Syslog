// Copyright (c) 2026 Tristan Conner <tristan@conner.house>. All rights reserved.
//
// Syslog message parsing (RFC 3164 + RFC 5424 + lenient fallback) and JSON
// serialization. All fields are best-effort; `raw` always holds the original
// text so nothing is ever lost, even from non-compliant devices.

use std::time::{SystemTime, UNIX_EPOCH};

const SEVERITIES: [&str; 8] = [
    "Emergency", "Alert", "Critical", "Error", "Warning", "Notice",
    "Informational", "Debug",
];

const FACILITIES: [&str; 24] = [
    "kernel", "user", "mail", "daemon", "auth", "syslog", "lpr", "news",
    "uucp", "cron", "authpriv", "ftp", "ntp", "audit", "alert", "clock",
    "local0", "local1", "local2", "local3", "local4", "local5", "local6",
    "local7",
];

#[derive(Debug, Clone)]
pub struct Message {
    pub received: String,   // when we received it (RFC3339 UTC)
    pub source_ip: String,  // sender address
    pub facility: u8,
    pub facility_name: String,
    pub severity: u8,
    pub severity_name: String,
    pub timestamp: String,  // from the message if present, else received
    pub hostname: String,
    pub app: String,        // tag / APP-NAME
    pub procid: String,
    pub msgid: String,
    pub message: String,    // free-text portion
    pub raw: String,        // original decoded datagram
}

impl Message {
    /// Parse a raw datagram from `source_ip`. Never fails: unrecognized input
    /// still yields a Message with the whole text in `message`/`raw`.
    pub fn parse(bytes: &[u8], source_ip: &str, received: &str) -> Message {
        let raw = String::from_utf8_lossy(bytes)
            .trim_matches(|c: char| c == '\0' || c == '\n' || c == '\r')
            .to_string();

        let mut m = Message {
            received: received.to_string(),
            source_ip: source_ip.to_string(),
            facility: 1,
            facility_name: "user".into(),
            severity: 5,
            severity_name: "Notice".into(),
            timestamp: received.to_string(),
            hostname: String::new(),
            app: String::new(),
            procid: String::new(),
            msgid: String::new(),
            message: String::new(),
            raw: raw.clone(),
        };

        // --- PRI: "<NNN>" -> facility*8 + severity ---
        let rest = if let Some(stripped) = raw.strip_prefix('<') {
            if let Some(end) = stripped.find('>') {
                if let Ok(pri) = stripped[..end].parse::<u16>() {
                    if pri <= 191 {
                        m.set_pri(pri);
                        &stripped[end + 1..]
                    } else {
                        raw.as_str()
                    }
                } else {
                    raw.as_str()
                }
            } else {
                raw.as_str()
            }
        } else {
            raw.as_str()
        };

        // --- Body: RFC5424 (version digit + space) else RFC3164 else raw ---
        if rest.len() >= 2 && rest.as_bytes()[0].is_ascii_digit() && rest[1..].starts_with(' ') {
            m.parse_5424(&rest[2..]);
        } else if !parse_3164(&mut m, rest) {
            m.message = rest.trim_start().to_string();
        }
        m
    }

    fn set_pri(&mut self, pri: u16) {
        self.facility = (pri / 8) as u8;
        self.severity = (pri % 8) as u8;
        self.facility_name = FACILITIES
            .get(self.facility as usize)
            .copied()
            .unwrap_or("unknown")
            .into();
        self.severity_name = SEVERITIES[self.severity as usize].into();
    }

    // RFC5424: TIMESTAMP HOSTNAME APP-NAME PROCID MSGID [SD] MSG   ('-' = nil)
    fn parse_5424(&mut self, s: &str) {
        let mut it = s.splitn(6, ' ');
        let nil = |v: &str| if v == "-" { String::new() } else { v.to_string() };
        self.timestamp = {
            let t = it.next().unwrap_or("-");
            if t == "-" { self.received.clone() } else { t.to_string() }
        };
        self.hostname = nil(it.next().unwrap_or("-"));
        self.app = nil(it.next().unwrap_or("-"));
        self.procid = nil(it.next().unwrap_or("-"));
        self.msgid = nil(it.next().unwrap_or("-"));

        // Remainder = STRUCTURED-DATA (nil '-' or one/more "[...]") then MSG.
        let tail = it.next().unwrap_or("");
        let msg = if let Some(t) = tail.strip_prefix('-') {
            t.trim_start()
        } else if tail.starts_with('[') {
            // Skip balanced structured-data blocks.
            let b = tail.as_bytes();
            let mut i = 0;
            while i < b.len() && b[i] == b'[' {
                let mut depth = 0;
                while i < b.len() {
                    match b[i] {
                        b'\\' => i += 1,               // escaped char inside SD
                        b'[' => depth += 1,
                        b']' => { depth -= 1; if depth == 0 { i += 1; break; } }
                        _ => {}
                    }
                    i += 1;
                }
            }
            tail[i..].trim_start()
        } else {
            tail
        };
        self.message = msg.to_string();
    }
}

// RFC3164: "Mmm dd hh:mm:ss host tag[pid]: message". Returns false if the
// leading timestamp doesn't match, so the caller can fall back to raw.
fn parse_3164(m: &mut Message, s: &str) -> bool {
    let s = s.trim_start();
    if s.len() < 16 || !is_rfc3164_time(&s[..15]) {
        return false;
    }
    m.timestamp = s[..15].to_string();
    let mut rest = s[15..].trim_start();

    // hostname = first token (only if a second token follows; otherwise it's
    // all message).
    if let Some(sp) = rest.find(' ') {
        m.hostname = rest[..sp].to_string();
        rest = rest[sp..].trim_start();
    }

    // tag = leading word up to ':' or '[' (bounded, per RFC 32 chars).
    if let Some(colon) = rest.find(':') {
        let tag_field = &rest[..colon];
        if tag_field.len() <= 48 && !tag_field.contains(' ') {
            if let Some(br) = tag_field.find('[') {
                m.app = tag_field[..br].to_string();
                m.procid = tag_field[br + 1..].trim_end_matches(']').to_string();
            } else {
                m.app = tag_field.to_string();
            }
            rest = rest[colon + 1..].trim_start();
        }
    }
    m.message = rest.to_string();
    true
}

fn is_rfc3164_time(s: &str) -> bool {
    // "Mmm dd hh:mm:ss" — cheap structural check, not a full calendar parse.
    let b = s.as_bytes();
    b.len() == 15
        && b[0].is_ascii_alphabetic()
        && b[3] == b' '
        && b[6] == b' '
        && b[9] == b':'
        && b[12] == b':'
        && b[7].is_ascii_digit()
        && b[8].is_ascii_digit()
}

/// RFC3339 UTC timestamp (e.g. "2026-09-15T18:04:01Z") from the system clock,
/// std-only (no chrono). Civil-date conversion via days-since-epoch.
pub fn now_rfc3339() -> String {
    let d = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    let secs = d.as_secs();
    let (days, rem) = (secs / 86_400, secs % 86_400);
    let (h, mi, se) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let (y, mo, dd) = civil_from_days(days as i64);
    format!("{y:04}-{mo:02}-{dd:02}T{h:02}:{mi:02}:{se:02}Z")
}

// Howard Hinnant's days->civil algorithm (public domain).
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// Escape a string per JSON (RFC 8259). The one place correctness bites.
pub fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\x08' => out.push_str("\\b"),
            '\x0c' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

impl Message {
    /// Serialize to a single-line JSON object (one line == one stored record).
    pub fn to_json(&self) -> String {
        let f = |s: &str| json_escape(s);
        format!(
            concat!(
                "{{\"received\":\"{}\",\"source_ip\":\"{}\",\"facility\":{},",
                "\"facility_name\":\"{}\",\"severity\":{},\"severity_name\":\"{}\",",
                "\"timestamp\":\"{}\",\"hostname\":\"{}\",\"app\":\"{}\",",
                "\"procid\":\"{}\",\"msgid\":\"{}\",\"message\":\"{}\",\"raw\":\"{}\"}}"
            ),
            f(&self.received), f(&self.source_ip), self.facility,
            f(&self.facility_name), self.severity, f(&self.severity_name),
            f(&self.timestamp), f(&self.hostname), f(&self.app),
            f(&self.procid), f(&self.msgid), f(&self.message), f(&self.raw),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rfc3164_basic() {
        let m = Message::parse(
            b"<34>Oct 11 22:14:15 mymachine su: 'su root' failed for lonvick",
            "10.0.0.9", "2026-09-15T00:00:00Z",
        );
        assert_eq!(m.facility, 4); // auth
        assert_eq!(m.severity, 2); // critical
        assert_eq!(m.severity_name, "Critical");
        assert_eq!(m.hostname, "mymachine");
        assert_eq!(m.app, "su");
        assert_eq!(m.message, "'su root' failed for lonvick");
    }

    #[test]
    fn rfc3164_with_pid() {
        let m = Message::parse(
            b"<13>Feb  5 17:32:18 host app[1234]: started ok",
            "10.0.0.1", "2026-09-15T00:00:00Z",
        );
        assert_eq!(m.app, "app");
        assert_eq!(m.procid, "1234");
        assert_eq!(m.message, "started ok");
    }

    #[test]
    fn rfc5424_with_sd() {
        let m = Message::parse(
            br#"<165>1 2026-08-24T05:14:15.003Z host.example.com evntslog 8710 ID47 [exampleSDID@32473 iut="3"] BOMAn application event"#,
            "192.168.1.5", "2026-09-15T00:00:00Z",
        );
        assert_eq!(m.facility, 20); // local4
        assert_eq!(m.severity, 5);  // notice
        assert_eq!(m.hostname, "host.example.com");
        assert_eq!(m.app, "evntslog");
        assert_eq!(m.procid, "8710");
        assert_eq!(m.msgid, "ID47");
        assert_eq!(m.message, "BOMAn application event");
    }

    #[test]
    fn rfc5424_nil_sd() {
        let m = Message::parse(
            b"<34>1 2026-08-24T05:14:15Z host app - - - plain message",
            "10.0.0.2", "2026-09-15T00:00:00Z",
        );
        assert_eq!(m.hostname, "host");
        assert_eq!(m.app, "app");
        assert_eq!(m.procid, "");
        assert_eq!(m.msgid, "");
        assert_eq!(m.message, "plain message");
    }

    #[test]
    fn garbage_falls_back_to_raw() {
        let m = Message::parse(b"just some random text", "10.0.0.3", "T");
        assert_eq!(m.message, "just some random text");
        assert_eq!(m.raw, "just some random text");
    }

    #[test]
    fn json_escapes_and_roundtrips_shape() {
        let m = Message::parse(b"<13>hello \"world\"\tline", "10.0.0.4", "T");
        let j = m.to_json();
        assert!(j.starts_with('{') && j.ends_with('}'));
        assert!(j.contains("\\\"world\\\""));
        assert!(j.contains("\\t"));
        assert!(!j.contains('\n')); // must stay single-line
    }

    #[test]
    fn civil_date_epoch() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(10_957), (2000, 1, 1));
        assert_eq!(civil_from_days(18_628), (2021, 1, 1));
    }
}
