//! Importtabellen einer Windows-Programmdatei (PE32+) lesen — für den Selbsttest `nomedia`: Die
//! Media-Foundation-DLLs müssen verzögert geladen werden (`build.rs`), sonst startet Knips auf
//! Windows N/KN ohne Media Feature Pack gar nicht. Nur `std`, damit es auch auf dem Mac prüfbar ist.

/// DLL-Namen (klein geschrieben) aus der normalen und der Verzögert-Import-Tabelle.
pub struct Imports {
    pub normal: Vec<String>,
    pub delayed: Vec<String>,
}

pub fn imports(bytes: &[u8]) -> Result<Imports, String> {
    let u16_at = |o: usize| bytes.get(o..o + 2).map(|b| u16::from_le_bytes([b[0], b[1]])).ok_or("Datei zu kurz");
    let u32_at = |o: usize| bytes.get(o..o + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]])).ok_or("Datei zu kurz");
    if bytes.get(0..2) != Some(b"MZ".as_slice()) {
        return Err("keine Windows-Programmdatei (MZ fehlt)".into());
    }
    let pe = u32_at(0x3c)? as usize;
    if bytes.get(pe..pe + 4) != Some(b"PE\0\0".as_slice()) {
        return Err("PE-Signatur fehlt".into());
    }
    let coff = pe + 4;
    let sections = u16_at(coff + 2)? as usize;
    let opt_size = u16_at(coff + 16)? as usize;
    let opt = coff + 20;
    if u16_at(opt)? != 0x20b {
        return Err("kein PE32+ (64 Bit)".into());
    }
    let dirs = u32_at(opt + 108)? as usize;
    // Datenverzeichnis i: (RVA, Größe) ab Optional Header + 112 (PE32+).
    let dir = |i: usize| -> Result<u32, String> { if i < dirs { Ok(u32_at(opt + 112 + i * 8)?) } else { Ok(0) } };
    let table = opt + opt_size;
    let offset = |rva: u32| -> Result<usize, String> {
        for s in 0..sections {
            let h = table + s * 40;
            let (vsize, va, raw_size, raw) = (u32_at(h + 8)?, u32_at(h + 12)?, u32_at(h + 16)?, u32_at(h + 20)?);
            if rva >= va && rva < va + vsize.max(raw_size) {
                return Ok((rva - va + raw) as usize);
            }
        }
        Err(format!("Adresse {rva:#x} liegt in keinem Abschnitt"))
    };
    let name = |rva: u32| -> Result<String, String> {
        let start = offset(rva)?;
        let rest = bytes.get(start..).ok_or("Name außerhalb der Datei")?;
        let end = rest.iter().position(|&b| b == 0).ok_or("Name ohne Ende")?;
        Ok(String::from_utf8_lossy(&rest[..end]).to_ascii_lowercase())
    };

    // IMAGE_IMPORT_DESCRIPTOR: 20 Bytes, Name bei +12; Ende = Eintrag mit Name 0.
    let mut normal = Vec::new();
    let rva = dir(1)?;
    if rva != 0 {
        let mut at = offset(rva)?;
        loop {
            let n = u32_at(at + 12)?;
            if n == 0 {
                break;
            }
            normal.push(name(n)?);
            at += 20;
        }
    }
    // ImgDelayDescr: 32 Bytes, Attribute bei +0 (1 = Adressen sind RVAs), Name bei +4.
    let mut delayed = Vec::new();
    let rva = dir(13)?;
    if rva != 0 {
        let mut at = offset(rva)?;
        loop {
            let (attrs, n) = (u32_at(at)?, u32_at(at + 4)?);
            if n == 0 {
                break;
            }
            if attrs & 1 == 0 {
                return Err("veraltete Verzögert-Import-Tabelle (VA statt RVA)".into());
            }
            delayed.push(name(n)?);
            at += 32;
        }
    }
    Ok(Imports { normal, delayed })
}
