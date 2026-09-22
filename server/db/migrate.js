// One-time (idempotent) migration: reads every *.dc.html page in the project
// root and seeds the SQLite content_fields table from each page's embedded
// `var EN = {...}; var AR = {...};` dictionaries, so the admin CMS has
// something to edit from day one.
//
// Run with: npm run migrate   (from the server/ directory)

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const db = require('./index');
const { extractObjectLiteralSource } = require('../lib/objectLiteral');

const PROJECT_ROOT = path.join(__dirname, '..', '..');

function findPageFiles() {
  return fs
    .readdirSync(PROJECT_ROOT)
    .filter((f) => f.endsWith('.dc.html'))
    .sort();
}

function parseDict(source, varName) {
  const literal = extractObjectLiteralSource(source, varName);
  if (!literal) return null;
  try {
    return vm.runInNewContext('(' + literal + ')', {}, { timeout: 1000 });
  } catch (err) {
    throw new Error(`Failed to evaluate ${varName} object literal: ${err.message}`);
  }
}

function extractTitle(source, slug) {
  const m = source.match(/<title>([^<]*)<\/title>/i);
  if (m) return m[1].replace(/&amp;/g, '&').trim();
  return slug;
}

function migrate() {
  const files = findPageFiles();
  const upsertPage = db.prepare(`
    INSERT INTO pages (slug, title, updated_at)
    VALUES (@slug, @title, datetime('now'))
    ON CONFLICT(slug) DO UPDATE SET title = excluded.title, updated_at = datetime('now')
  `);
  // Only inserts a field if it doesn't already exist, so re-running the
  // migration never clobbers content an admin has already edited.
  const insertFieldIfMissing = db.prepare(`
    INSERT INTO content_fields (page_slug, field_key, en_value, ar_value)
    VALUES (@page_slug, @field_key, @en_value, @ar_value)
    ON CONFLICT(page_slug, field_key) DO NOTHING
  `);

  const runAll = db.transaction((files) => {
    let pagesCount = 0;
    let fieldsCount = 0;

    for (const file of files) {
      const slug = file.replace(/\.dc\.html$/, '');
      const fullPath = path.join(PROJECT_ROOT, file);
      const source = fs.readFileSync(fullPath, 'utf8');

      let EN, AR;
      try {
        EN = parseDict(source, 'EN') || {};
        AR = parseDict(source, 'AR') || {};
      } catch (err) {
        console.error(`[migrate] Skipping ${file}: ${err.message}`);
        continue;
      }

      const title = extractTitle(source, slug);
      upsertPage.run({ slug, title });
      pagesCount++;

      const keys = new Set([...Object.keys(EN), ...Object.keys(AR)]);
      for (const key of keys) {
        const res = insertFieldIfMissing.run({
          page_slug: slug,
          field_key: key,
          en_value: EN[key] != null ? String(EN[key]) : '',
          ar_value: AR[key] != null ? String(AR[key]) : ''
        });
        if (res.changes > 0) fieldsCount++;
      }
    }

    return { pagesCount, fieldsCount };
  });

  const { pagesCount, fieldsCount } = runAll(files);
  console.log(`[migrate] Seeded ${pagesCount} pages, ${fieldsCount} new content fields.`);
}

if (require.main === module) {
  migrate();
}

module.exports = migrate;
