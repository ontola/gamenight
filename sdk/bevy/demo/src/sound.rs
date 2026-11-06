//! Tiny synthesised sounds, so the demo ships no audio files.

use std::f32::consts::TAU;

const RATE: u32 = 22_050;

fn wav(samples: &[f32]) -> Vec<u8> {
    let data_len = samples.len() as u32 * 2;
    let mut out = Vec::with_capacity(44 + data_len as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_len).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&RATE.to_le_bytes());
    out.extend_from_slice(&(RATE * 2).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    for s in samples {
        out.extend_from_slice(&((s.clamp(-1.0, 1.0) * 32000.0) as i16).to_le_bytes());
    }
    out
}

fn tone(freq: f32, seconds: f32, out: &mut Vec<f32>, volume: f32) {
    let n = (seconds * RATE as f32) as usize;
    for i in 0..n {
        let t = i as f32 / RATE as f32;
        let env = (1.0 - t / seconds).powf(2.0) * (t * 200.0).min(1.0);
        let wave = (TAU * freq * t).sin() * 0.7 + (TAU * freq * 2.0 * t).sin() * 0.3;
        out.push(wave * env * volume);
    }
}

/// A bright two-note blip.
pub fn pickup() -> Vec<u8> {
    let mut s = Vec::new();
    tone(988.0, 0.06, &mut s, 0.5);
    tone(1319.0, 0.12, &mut s, 0.5);
    wav(&s)
}

/// A soft noise thump.
pub fn boom() -> Vec<u8> {
    let n = (0.45 * RATE as f32) as usize;
    let mut seed = 0x1234_5678u32;
    let s: Vec<f32> = (0..n)
        .map(|i| {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            let t = i as f32 / RATE as f32;
            let noise = (seed as f32 / u32::MAX as f32) * 2.0 - 1.0;
            let thump = (TAU * (90.0 - t * 80.0) * t).sin();
            (noise * 0.4 + thump * 0.8) * (1.0 - t / 0.45).powf(3.0) * 0.8
        })
        .collect();
    wav(&s)
}

/// An eight-second arpeggio loop.
pub fn music() -> Vec<u8> {
    let chords: [[f32; 3]; 4] = [
        [261.6, 329.6, 392.0],
        [220.0, 261.6, 329.6],
        [174.6, 220.0, 261.6],
        [196.0, 246.9, 293.7],
    ];
    let mut s = Vec::new();
    for chord in chords {
        for step in 0..8 {
            let note = chord[step % 3] * if step >= 6 { 2.0 } else { 1.0 };
            let mut bar = Vec::new();
            tone(note, 0.25, &mut bar, 0.25);
            // A low root under every other step.
            if step % 2 == 0 {
                let mut bass = Vec::new();
                tone(chord[0] / 2.0, 0.25, &mut bass, 0.3);
                for (a, b) in bar.iter_mut().zip(bass) {
                    *a += b;
                }
            }
            s.extend(bar);
        }
    }
    wav(&s)
}
