#!/usr/bin/env node
// Generates sloppycan/carlito_contract.js from the canonical contract JSON.
//
// Contract sharing = synced copy: the canonical carlito_contract.json lives here in carlito2;
// sloppyCAN consumes a committed JS-global copy so it loads from file:// (Web Serial forces
// that) with no build step to run. Run this after editing the contract:
//     node tools/gen_js_contract.mjs
// The runtime version-mismatch console warning is the primary drift guard.

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const srcPath = resolve(here, '../contract/carlito_contract.json');
const outPath = resolve(here, '../../sloppycan/carlito_contract.js');

const contract = JSON.parse(readFileSync(srcPath, 'utf8')); // throws on malformed JSON
const banner =
`// GENERATED from carlito2/contract/carlito_contract.json — do not edit by hand.
// Regenerate with:  node tools/gen_js_contract.mjs  (in the carlito2 repo)
// Canonical contract lives in carlito2; this is the synced copy sloppyCAN consumes.
`;
const body = `window.CARLITO_CONTRACT = ${JSON.stringify(contract, null, 2)};\n`;
writeFileSync(outPath, banner + body);
console.log(`Wrote ${outPath} (contract v${contract.version}, ${contract.signals.length} signals)`);
