//! rawler を Swift から呼ぶための薄い C ABI レイヤー。
//! 出力は「リニア sRGB(D65)・デモザイク済み・RGBA f32」。トーンカーブ/ガンマはかけない。

use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;

use rawler::decoders::RawDecodeParams;
use rawler::imgop::develop::{Intermediate, ProcessingStep, RawDevelop};
use rawler::rawsource::RawSource;

#[repr(C)]
pub struct RlImage {
    pub width: u32,
    pub height: u32,
    /// RGBA f32 interleaved。rl_image_free で解放する
    pub data: *mut f32,
    pub len: usize,
    /// EXIF Orientation (1-8)
    pub orientation: u16,
}

#[repr(C)]
pub struct RlMetadata {
    pub make: [c_char; 64],
    pub model: [c_char; 64],
    pub lens: [c_char; 128],
    pub date: [c_char; 32],
    pub iso: f64,
    pub shutter: f64,
    pub aperture: f64,
    pub focal_length: f64,
}

static VERSION: &[u8] = b"0.8.0\0";

#[no_mangle]
pub extern "C" fn rl_version() -> *const c_char {
    VERSION.as_ptr() as *const c_char
}

/// 0 = 成功。失敗時は err に UTF-8 のメッセージを書く
#[no_mangle]
pub unsafe extern "C" fn rl_decode(
    path: *const c_char,
    apply_wb: bool,
    out: *mut RlImage,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| decode(path, apply_wb)));
    match result {
        Ok(Ok(img)) => {
            *out = img;
            0
        }
        Ok(Err(e)) => write_err(err, err_len, &e),
        Err(_) => write_err(err, err_len, "rawler が panic しました(未対応のファイルの可能性)"),
    }
}

#[no_mangle]
pub unsafe extern "C" fn rl_image_free(data: *mut f32, len: usize) {
    if !data.is_null() {
        drop(Vec::from_raw_parts(data, len, len));
    }
}

#[no_mangle]
pub unsafe extern "C" fn rl_metadata(
    path: *const c_char,
    out: *mut RlMetadata,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| metadata(path)));
    match result {
        Ok(Ok(m)) => {
            *out = m;
            0
        }
        Ok(Err(e)) => write_err(err, err_len, &e),
        Err(_) => write_err(err, err_len, "rawler が panic しました"),
    }
}

// ---------------------------------------------------------------------------

unsafe fn open(path: *const c_char) -> Result<RawSource, String> {
    let path = CStr::from_ptr(path).to_str().map_err(|e| e.to_string())?;
    RawSource::new(Path::new(path)).map_err(|e| format!("開けません: {e}"))
}

unsafe fn decode(path: *const c_char, apply_wb: bool) -> Result<RlImage, String> {
    let source = open(path)?;
    let params = RawDecodeParams::default();
    let decoder = rawler::get_decoder(&source).map_err(|e| e.to_string())?;
    let raw = decoder.raw_image(&source, &params, false).map_err(|e| e.to_string())?;

    // SRgb(ガンマ)を外して、リニア sRGB で止める
    let mut steps = vec![
        ProcessingStep::Rescale,
        ProcessingStep::Demosaic,
        ProcessingStep::FujiRotate,
        ProcessingStep::CropActiveArea,
        ProcessingStep::Calibrate,
        ProcessingStep::CropDefault,
    ];
    if apply_wb {
        steps.push(ProcessingStep::WhiteBalance);
    }
    let developed = RawDevelop::new_with(&steps)
        .develop_intermediate(&raw)
        .map_err(|e| e.to_string())?;

    let (width, height, mut data) = match developed {
        Intermediate::ThreeColor(px) => {
            let mut v = Vec::with_capacity(px.data.len() * 4);
            for p in &px.data {
                v.extend_from_slice(&[p[0], p[1], p[2], 1.0]);
            }
            (px.width, px.height, v)
        }
        Intermediate::Monochrome(px) => {
            let mut v = Vec::with_capacity(px.data.len() * 4);
            for &g in &px.data {
                v.extend_from_slice(&[g, g, g, 1.0]);
            }
            (px.width, px.height, v)
        }
        Intermediate::FourColor(_) => return Err("4色センサーは未対応".into()),
    };
    data.shrink_to_fit();
    let len = data.len();
    let ptr = data.as_mut_ptr();
    std::mem::forget(data);

    Ok(RlImage {
        width: width as u32,
        height: height as u32,
        data: ptr,
        len,
        orientation: raw.orientation.to_u16(),
    })
}

unsafe fn metadata(path: *const c_char) -> Result<RlMetadata, String> {
    let source = open(path)?;
    let params = RawDecodeParams::default();
    let decoder = rawler::get_decoder(&source).map_err(|e| e.to_string())?;
    let md = decoder.raw_metadata(&source, &params).map_err(|e| e.to_string())?;
    let ex = &md.exif;
    let rational = |r: Option<rawler::formats::tiff::Rational>| -> f64 {
        r.map(|r| if r.d == 0 { 0.0 } else { r.n as f64 / r.d as f64 }).unwrap_or(0.0)
    };
    let lens = md
        .lens
        .as_ref()
        .map(|l| l.lens_model.clone())
        .or_else(|| ex.lens_model.clone())
        .unwrap_or_default();

    let mut m = RlMetadata {
        make: [0; 64],
        model: [0; 64],
        lens: [0; 128],
        date: [0; 32],
        iso: ex.iso_speed_ratings.map(|v| v as f64).or(ex.iso_speed.map(|v| v as f64)).unwrap_or(0.0),
        shutter: rational(ex.exposure_time),
        aperture: rational(ex.fnumber),
        focal_length: rational(ex.focal_length),
    };
    copy_str(&mut m.make, &md.make);
    copy_str(&mut m.model, &md.model);
    copy_str(&mut m.lens, &lens);
    copy_str(&mut m.date, ex.date_time_original.as_deref().unwrap_or(""));
    Ok(m)
}

fn copy_str(dst: &mut [c_char], s: &str) {
    let bytes = s.as_bytes();
    let n = bytes.len().min(dst.len() - 1);
    for (d, &b) in dst.iter_mut().zip(&bytes[..n]) {
        *d = b as c_char;
    }
    dst[n] = 0;
}

unsafe fn write_err(err: *mut c_char, err_len: usize, msg: &str) -> i32 {
    if !err.is_null() && err_len > 0 {
        copy_str(std::slice::from_raw_parts_mut(err, err_len), msg);
    }
    1
}
