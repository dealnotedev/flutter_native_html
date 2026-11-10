// Builds a family -> font files manifest from the installed Windows fonts, so
// the Flutter harness can load exactly the faces Chrome resolves by name.
import fs from 'node:fs';
import path from 'node:path';
import { fontsManifest, writeJson } from './common.mjs';

const dirs = [
  'C:/Windows/Fonts',
  path.join(process.env.LOCALAPPDATA ?? '', 'Microsoft/Windows/Fonts'),
].filter((dir) => fs.existsSync(dir));

function readNames(buf, offset) {
  const numTables = buf.readUInt16BE(offset + 4);
  const tables = {};
  for (let i = 0; i < numTables; i++) {
    const rec = offset + 12 + i * 16;
    tables[buf.toString('latin1', rec, rec + 4)] = {
      offset: buf.readUInt32BE(rec + 8),
      length: buf.readUInt32BE(rec + 12),
    };
  }
  const name = tables.name;
  if (!name) return null;
  const count = buf.readUInt16BE(name.offset + 2);
  const stringOffset = name.offset + buf.readUInt16BE(name.offset + 4);
  const found = {};
  for (let i = 0; i < count; i++) {
    const rec = name.offset + 6 + i * 12;
    const platform = buf.readUInt16BE(rec);
    const language = buf.readUInt16BE(rec + 4);
    const nameId = buf.readUInt16BE(rec + 6);
    const length = buf.readUInt16BE(rec + 8);
    const start = stringOffset + buf.readUInt16BE(rec + 10);
    if (![1, 2, 16, 17].includes(nameId)) continue;
    let value;
    if (platform === 3) {
      const swapped = Buffer.from(buf.subarray(start, start + length));
      swapped.swap16();
      value = swapped.toString('utf16le');
    } else if (platform === 1 && language === 0) {
      value = buf.toString('latin1', start, start + length);
    } else continue;
    // Prefer US English Windows names.
    const score = platform === 3 && language === 0x409 ? 2 : 1;
    if (!found[nameId] || found[nameId].score < score) found[nameId] = { value, score };
  }
  let weight = 400;
  let italic = false;
  if (tables['OS/2']) {
    weight = buf.readUInt16BE(tables['OS/2'].offset + 4);
    italic = (buf.readUInt16BE(tables['OS/2'].offset + 62) & 1) === 1;
  }
  return {
    family: found[1]?.value,
    typographicFamily: found[16]?.value,
    weight,
    italic,
  };
}

const families = {};
let files = 0;
for (const dir of dirs) {
  for (const entry of fs.readdirSync(dir)) {
    if (!/\.(ttf|otf|ttc)$/i.test(entry)) continue;
    const file = path.join(dir, entry).replace(/\\/g, '/');
    let buf;
    try {
      buf = fs.readFileSync(file);
    } catch {
      continue;
    }
    // Skia loads face 0 of a collection; only that face is reachable.
    const offset = buf.toString('latin1', 0, 4) === 'ttcf' ? buf.readUInt32BE(12) : 0;
    let info;
    try {
      info = readNames(buf, offset);
    } catch {
      continue;
    }
    if (!info?.family) continue;
    files++;
    for (const name of new Set([info.family, info.typographicFamily].filter(Boolean))) {
      const key = name.toLowerCase();
      (families[key] ??= { family: name, faces: [] }).faces.push({
        file,
        weight: info.weight,
        italic: info.italic,
        bytes: buf.length,
      });
    }
  }
}

// Windows FontSubstitutes aliases that Chrome honours on this machine.
const aliases = { helvetica: 'arial', times: 'times new roman', courier: 'courier new' };
writeJson(fontsManifest, { families, aliases, generatedAt: new Date().toISOString() });
console.log(`${files} font files, ${Object.keys(families).length} family names -> ${fontsManifest}`);
