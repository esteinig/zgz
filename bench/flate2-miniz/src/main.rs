use flate2::bufread::{GzDecoder, MultiGzDecoder};
use std::env;
use std::fs::File;
use std::io::{self, BufReader, Read, Write};
use std::process::ExitCode;

const DEFAULT_BUFFER_SIZE: usize = 256 * 1024;

#[derive(Debug, Clone)]
struct CliOptions {
    input_path: Option<String>,
    input_buffer_size: usize,
    output_buffer_size: usize,
    max_output_bytes: Option<usize>,
    allow_concatenated_members: bool,
}

impl Default for CliOptions {
    fn default() -> Self {
        Self {
            input_path: None,
            input_buffer_size: DEFAULT_BUFFER_SIZE,
            output_buffer_size: DEFAULT_BUFFER_SIZE,
            max_output_bytes: None,
            allow_concatenated_members: true,
        }
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("{err}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let options = parse_args(env::args().collect())?;

    let input_path = options.input_path.as_deref().ok_or_else(|| {
        usage();
        "rzgz: expected exactly one input file".to_string()
    })?;

    if options.input_buffer_size == 0 {
        return Err("rzgz: --in-buffer must be greater than zero".to_string());
    }

    if options.output_buffer_size == 0 {
        return Err("rzgz: --out-buffer must be greater than zero".to_string());
    }

    if matches!(options.max_output_bytes, Some(0)) {
        return Err("rzgz: --max-output must be greater than zero".to_string());
    }

    let file = File::open(input_path)
        .map_err(|err| format!("rzgz: failed to open '{input_path}': {err}"))?;

    let input = BufReader::with_capacity(options.input_buffer_size, file);

    if options.allow_concatenated_members {
        let decoder = MultiGzDecoder::new(input);
        stream_decode(decoder, &options)
    } else {
        let decoder = GzDecoder::new(input);
        stream_decode(decoder, &options)
    }
    .map_err(|err| format!("rzgz: failed to decompress '{input_path}': {err}"))
}

fn stream_decode<R: Read>(mut decoder: R, options: &CliOptions) -> io::Result<()> {
    let stdout = io::stdout();
    let mut writer = stdout.lock();

    let mut buffer = vec![0_u8; options.output_buffer_size];
    let mut total_out: usize = 0;

    loop {
        let n = match options.max_output_bytes {
            Some(cap) => {
                if total_out >= cap {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "max output exceeded",
                    ));
                }

                let remaining = cap - total_out;
                let limit = remaining.min(buffer.len());
                decoder.read(&mut buffer[..limit])?
            }
            None => decoder.read(&mut buffer)?,
        };

        if n == 0 {
            break;
        }

        total_out = total_out
            .checked_add(n)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "output size overflow"))?;

        writer.write_all(&buffer[..n])?;
    }

    writer.flush()
}

fn parse_args(args: Vec<String>) -> Result<CliOptions, String> {
    let mut options = CliOptions::default();

    let mut i = 1;
    while i < args.len() {
        let arg = &args[i];

        match arg.as_str() {
            "-h" | "--help" => {
                usage();
                return Err("help requested".to_string());
            }
            "--no-concat" => {
                options.allow_concatenated_members = false;
                i += 1;
            }
            "--in-buffer" => {
                i += 1;
                let value = args
                    .get(i)
                    .ok_or_else(|| "rzgz: --in-buffer requires a byte count".to_string())?;
                options.input_buffer_size = parse_size(value)?;
                i += 1;
            }
            "--out-buffer" => {
                i += 1;
                let value = args
                    .get(i)
                    .ok_or_else(|| "rzgz: --out-buffer requires a byte count".to_string())?;
                options.output_buffer_size = parse_size(value)?;
                i += 1;
            }
            "--max-output" => {
                i += 1;
                let value = args
                    .get(i)
                    .ok_or_else(|| "rzgz: --max-output requires a byte count".to_string())?;
                options.max_output_bytes = Some(parse_size(value)?);
                i += 1;
            }
            _ if arg.starts_with('-') => {
                return Err(format!("rzgz: unknown option: {arg}"));
            }
            _ => {
                if options.input_path.is_some() {
                    return Err("rzgz: expected exactly one input file".to_string());
                }

                options.input_path = Some(arg.clone());
                i += 1;
            }
        }
    }

    Ok(options)
}

fn parse_size(text: &str) -> Result<usize, String> {
    if text.is_empty() {
        return Err("rzgz: empty size".to_string());
    }

    let (digits, multiplier): (&str, usize) = match text.as_bytes().last().copied() {
        Some(b'k' | b'K') => (&text[..text.len() - 1], 1024),
        Some(b'm' | b'M') => (&text[..text.len() - 1], 1024 * 1024),
        Some(b'g' | b'G') => (&text[..text.len() - 1], 1024 * 1024 * 1024),
        Some(_) => (text, 1),
        None => return Err("rzgz: empty size".to_string()),
    };

    if digits.is_empty() {
        return Err(format!("rzgz: invalid size: {text}"));
    }

    let base = digits
        .parse::<usize>()
        .map_err(|_| format!("rzgz: invalid size: {text}"))?;

    base.checked_mul(multiplier)
        .ok_or_else(|| format!("rzgz: size overflows usize: {text}"))
}

fn usage() {
    eprintln!(
        "\
Usage:
  rzgz [options] FILE.gz

Options:
  --in-buffer BYTES     File reader buffer. Supports K/M/G suffixes.
                        Default: 256K.
  --out-buffer BYTES    Decompression buffer size. Supports K/M/G suffixes.
                        Default: 256K.
  --max-output BYTES    Abort if output exceeds this limit. Supports K/M/G suffixes.
  --no-concat           Decode one gzip member only.
  -h, --help            Show this help.

Examples:
  rzgz-miniz sample.gz > /dev/null
  rzgz-miniz --in-buffer 1M --out-buffer 1M sample.gz > /dev/null
"
    );
}