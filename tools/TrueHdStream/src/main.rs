// Copyright (c) B00kerLouis. SPDX-License-Identifier: Apache-2.0
use anyhow::{Context, Result, bail, ensure};
use std::fs::File;
use std::io::{self, BufReader, BufWriter, Read, Write};
use truehd::process::{
    decode::{DecodedAccessUnit, Decoder},
    extract::Extractor,
    parse::Parser,
};
use truehd::structs::{channel::ChannelLabel, oamd::ObjectAudioMetadataPayload};

#[derive(Clone, Debug, PartialEq)]
struct Element {
    kind: u8,
    label: i8,
    lfe: bool,
}

fn bed_label(label: &ChannelLabel) -> Result<i8> {
    use ChannelLabel::*;
    Ok(match label {
        L => 0,
        R => 1,
        C => 2,
        LFE => 3,
        Ls | Lsd => 4,
        Rs | Rsd => 5,
        Lb => 6,
        Rb => 7,
        Tfl => 8,
        Tfr => 9,
        Tsl => 10,
        Tsr => 11,
        Tbl => 12,
        Tbr => 13,
        Lw => 14,
        Rw => 15,
        LFE2 => 16,
        other => bail!("Channel {other:?} has no THDS speaker label"),
    })
}

fn elements(
    decoded: &DecodedAccessUnit,
    metadata: Option<&ObjectAudioMetadataPayload>,
) -> Result<Vec<Element>> {
    let mut result = vec![
        Element {
            kind: 0,
            label: -1,
            lfe: false
        };
        decoded.channel_count
    ];
    if let Some(metadata) = metadata {
        ensure!(
            metadata.object_count == decoded.channel_count,
            "OAMD element count does not match decoded PCM"
        );
        ensure!(
            metadata.program_assignment.num_isf_objects == 0,
            "This Cinema renderer does not support TrueHD ISF elements"
        );
        let labels: Vec<_> = metadata
            .program_assignment
            .bed_assignment
            .iter()
            .flat_map(|bed| bed.to_index_vec())
            .collect();
        ensure!(
            labels.len() <= result.len(),
            "OAMD bed exceeds the PCM channel count"
        );
        for (index, element) in result.iter_mut().enumerate() {
            if let Some(&label) = labels.get(index) {
                *element = Element {
                    kind: 1,
                    label: label as i8,
                    lfe: label == 3 || label == 16,
                };
            } else {
                element.kind = 2;
            }
        }
    } else {
        for (element, label) in result.iter_mut().zip(&decoded.channel_labels) {
            let label = bed_label(label)?;
            *element = Element {
                kind: 1,
                label,
                lfe: label == 3 || label == 16,
            };
        }
    }
    Ok(result)
}

fn record(output: &mut impl Write, kind: u8, position: u64, payload: &[u8]) -> Result<()> {
    // THDS v1 uses a 24-byte record header; see Cinema's TrueHdStreamProtocol.
    let mut header = [0u8; 24];
    header[0] = kind;
    header[2..4].copy_from_slice(&24u16.to_le_bytes());
    header[4..8].copy_from_slice(&u32::try_from(payload.len())?.to_le_bytes());
    header[8..16].copy_from_slice(&position.to_le_bytes());
    output.write_all(&header)?;
    output.write_all(payload)?;
    Ok(())
}

fn config(
    output: &mut impl Write,
    kind: u8,
    position: u64,
    rate: u32,
    elements: &[Element],
) -> Result<()> {
    let count = u16::try_from(elements.len())?;
    let mut payload = vec![0u8; 20];
    payload[0..4].copy_from_slice(&rate.to_le_bytes());
    payload[4..6].copy_from_slice(&count.to_le_bytes());
    payload[6..8].copy_from_slice(&1u16.to_le_bytes()); // signed 24-bit PCM in int32
    payload[18..20].copy_from_slice(&count.to_le_bytes());
    for element in elements {
        payload.extend_from_slice(&[
            element.kind,
            element.label as u8,
            u8::from(element.lfe),
            0,
            0,
            0,
            0,
            0,
        ]);
    }
    record(output, kind, position, &payload)
}

fn metadata(
    output: &mut impl Write,
    position: u64,
    data: &ObjectAudioMetadataPayload,
    elements: &[Element],
) -> Result<()> {
    let Some(objects) = &data.object_element else {
        return Ok(());
    };
    // The current Cinema interpolation contract accepts one timing block per OAMD update.
    ensure!(
        objects.md_update_info.num_obj_info_blocks == 1,
        "Multiple TrueHD metadata timing blocks are not supported by this renderer"
    );
    ensure!(
        objects.object_data.len() == elements.len(),
        "Invalid OAMD object table"
    );
    let update = objects
        .md_update_info
        .block_update_info
        .first()
        .context("Missing OAMD timing block")?;
    let target = position
        .checked_add(data.evo_sample_offset)
        .and_then(|value| value.checked_add(objects.md_update_info.sample_offset as u64))
        .context("OAMD timestamp overflow")?;
    let positions = data.get_damf_pos();
    let mut payload = Vec::with_capacity(4 + elements.len() * 48);
    payload.extend_from_slice(&u16::try_from(elements.len())?.to_le_bytes());
    payload.extend_from_slice(&1u16.to_le_bytes());
    for (index, element) in elements.iter().enumerate() {
        let object = objects.object_data[index]
            .first()
            .context("Missing OAMD object block")?;
        let xyz = positions
            .get(index)
            .and_then(|blocks| blocks.first())
            .context("Missing OAMD position")?;
        let mut event = [0u8; 48];
        let flags = u16::from(!object.b_object_not_active)
            | (u16::from(object.b_object_in_bed_or_isf) << 1)
            | (u16::from(element.lfe) << 2);
        event[0..2].copy_from_slice(&(index as u16).to_le_bytes());
        event[2..4].copy_from_slice(&flags.to_le_bytes());
        event[4..12].copy_from_slice(&target.to_le_bytes());
        event[12..16].copy_from_slice(&u32::from(update.ramp_duration).to_le_bytes());
        event[16..18]
            .copy_from_slice(&i16::from(object.object_basic_info.object_gain).to_le_bytes());
        for (offset, value) in [
            (20, xyz[0]),
            (24, xyz[1]),
            (28, xyz[2]),
            (32, object.object_render_info.object_size[0]),
        ] {
            event[offset..offset + 4].copy_from_slice(&(value as f32).to_le_bytes());
        }
        payload.extend_from_slice(&event);
    }
    record(output, 3, position, &payload)
}

fn transcode(mut input: impl Read, mut output: impl Write, presentation: usize) -> Result<u64> {
    ensure!(presentation < 4, "Presentation must be between 0 and 3");
    let mut extractor = Extractor::default();
    let mut parser = Parser::default();
    let mut requested = [false; 4];
    requested[presentation] = true;
    parser.set_required_presentations(&requested);
    let mut decoder = Decoder::default();
    let mut descriptors = Vec::new();
    let mut rate = 0;
    let mut sample_position = 0;
    let mut chunk = [0u8; 16384];
    let mut header = [0u8; 16];
    header[0..4].copy_from_slice(b"THDS");
    header[4..6].copy_from_slice(&1u16.to_le_bytes());
    header[6..8].copy_from_slice(&16u16.to_le_bytes());
    header[8..12].copy_from_slice(&1u32.to_le_bytes());
    output.write_all(&header)?;
    loop {
        let bytes = input.read(&mut chunk)?;
        if bytes == 0 {
            break;
        }
        extractor.push_bytes(&chunk[..bytes]);
        for frame in extractor.by_ref() {
            let frame = match frame {
                Ok(frame) => frame,
                Err(truehd::utils::errors::ExtractError::InsufficientData) => break,
                Err(error) => return Err(error).context("Invalid TrueHD frame"),
            };
            let unit = parser.parse(&frame)?;
            let decoded = decoder.decode_presentation(&unit, presentation)?;
            if decoded.is_duplicate {
                continue;
            }
            let next = if let Some(oamd) = decoded.oamd.first() {
                elements(&decoded, Some(oamd))?
            } else if descriptors.len() == decoded.channel_count && !descriptors.is_empty() {
                descriptors.clone()
            } else {
                elements(&decoded, None)?
            };
            if next != descriptors || rate != decoded.sampling_frequency {
                config(
                    &mut output,
                    if descriptors.is_empty() { 1 } else { 4 },
                    sample_position,
                    decoded.sampling_frequency,
                    &next,
                )?;
                descriptors = next;
                rate = decoded.sampling_frequency;
            }
            for oamd in &decoded.oamd {
                metadata(&mut output, sample_position, oamd, &descriptors)?;
            }
            let mut pcm = Vec::with_capacity(4 + decoded.sample_length * decoded.channel_count * 4);
            pcm.extend_from_slice(&u16::try_from(decoded.sample_length)?.to_le_bytes());
            pcm.extend_from_slice(&u16::try_from(decoded.channel_count)?.to_le_bytes());
            for frame in &decoded.pcm_data[..decoded.sample_length] {
                for sample in &frame[..decoded.channel_count] {
                    pcm.extend_from_slice(&sample.to_le_bytes());
                }
            }
            record(&mut output, 2, sample_position, &pcm)?;
            sample_position += decoded.sample_length as u64;
        }
        output.flush()?;
    }
    ensure!(sample_position > 0, "No TrueHD PCM frames decoded");
    record(&mut output, 255, sample_position, &[])?;
    output.flush()?;
    Ok(sample_position)
}

fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.iter().any(|value| value == "--help" || value == "-h") || args.is_empty() {
        println!("truehd-stream <input|-> --output <output|-> [--presentation 0..3]");
        return Ok(());
    }
    if args[0] == "--version" {
        println!(
            "SpatialAudioLab truehd-stream {} (THDS v1)",
            env!("CARGO_PKG_VERSION")
        );
        return Ok(());
    }
    let input_path = &args[0];
    let mut output_path = "-";
    let mut presentation = 3;
    let mut index = 1;
    while index < args.len() {
        let value = args.get(index + 1).context("Missing option value")?;
        match args[index].as_str() {
            "--output" => output_path = value,
            "--presentation" => presentation = value.parse()?,
            other => bail!("Unknown option {other}"),
        }
        index += 2;
    }
    let input: Box<dyn Read> = if input_path == "-" {
        Box::new(io::stdin())
    } else {
        Box::new(File::open(input_path)?)
    };
    let output: Box<dyn Write> = if output_path == "-" {
        Box::new(io::stdout())
    } else {
        Box::new(File::create(output_path)?)
    };
    let frames = transcode(BufReader::new(input), BufWriter::new(output), presentation)?;
    eprintln!("Decoded {frames} PCM frames to THDS v1");
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("truehd-stream: {error:#}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(name: &str) -> Vec<u8> {
        std::fs::read(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../third_party/truehdd-src/truehd/tests/assets")
                .join(name),
        )
        .unwrap()
    }
    #[test]
    fn real_stereo_and_atmos_streams_produce_complete_pcm_and_metadata_records() {
        for name in ["fba_2ch.mlp", "fba_atmos_cbi.mlp", "fba_atmos_obj.mlp"] {
            let mut bytes = Vec::new();
            let frames = transcode(&fixture(name)[..], &mut bytes, 3).unwrap();
            assert_eq!(&bytes[..4], b"THDS");
            let mut cursor = 16;
            let mut pcm_frames = 0u64;
            let mut metadata_records = 0;
            let mut channels = 0;
            while cursor < bytes.len() {
                let kind = bytes[cursor];
                let size =
                    u32::from_le_bytes(bytes[cursor + 4..cursor + 8].try_into().unwrap()) as usize;
                let position =
                    u64::from_le_bytes(bytes[cursor + 8..cursor + 16].try_into().unwrap());
                let payload = &bytes[cursor + 24..cursor + 24 + size];
                match kind {
                    1 | 4 => {
                        channels = u16::from_le_bytes(payload[4..6].try_into().unwrap()) as usize;
                        assert_eq!(size, 20 + channels * 8);
                    }
                    2 => {
                        assert_eq!(position, pcm_frames);
                        let count = u16::from_le_bytes(payload[..2].try_into().unwrap()) as usize;
                        assert_eq!(size, 4 + count * channels * 4);
                        pcm_frames += count as u64;
                    }
                    3 => {
                        metadata_records += 1;
                        assert_eq!(size, 4 + channels * 48);
                    }
                    255 => {
                        assert_eq!(position, frames);
                        assert_eq!(size, 0);
                    }
                    _ => panic!("Unexpected record"),
                }
                cursor += 24 + size;
            }
            assert_eq!(pcm_frames, frames);
            assert!(frames > 0);
            eprintln!(
                "{name}: {frames} frames, {channels} channels, {metadata_records} metadata records"
            );
            if name.contains("atmos_obj") {
                assert!(metadata_records > 0, "Atmos object metadata was lost");
            }
        }
    }
    struct Fragments<'a> {
        remaining: &'a [u8],
        maximum: usize,
    }
    impl Read for Fragments<'_> {
        fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
            let count = self.remaining.len().min(output.len()).min(self.maximum);
            output[..count].copy_from_slice(&self.remaining[..count]);
            self.remaining = &self.remaining[count..];
            Ok(count)
        }
    }
    #[test]
    fn pipe_fragmentation_preserves_every_pcm_byte_and_metadata_timestamp() {
        let source = fixture("fba_atmos_obj.mlp");
        let mut expected = Vec::new();
        assert_eq!(transcode(&source[..], &mut expected, 3).unwrap(), 5600);
        for maximum in [1, 71, 4096] {
            let mut fragmented = Vec::new();
            let input = Fragments {
                remaining: &source,
                maximum,
            };
            transcode(input, &mut fragmented, 3).unwrap();
            assert_eq!(fragmented, expected, "Chunk boundary changed the stream");
        }
    }
    #[test]
    fn empty_or_invalid_input_and_out_of_range_presentations_fail() {
        assert!(transcode(&[][..], Vec::new(), 3).is_err());
        assert!(transcode(&b"invalid bitstream"[..], Vec::new(), 3).is_err());
        assert!(transcode(&[][..], Vec::new(), 4).is_err());
    }
}
