#!/usr/bin/env node
// lo-prod-read.cjs: one read-only SELECT against production, for a research agent.
//
//   lo-prod-read.cjs --check <sql file>   apply the guard only; no database
//   lo-prod-read.cjs <sql file>           apply the guard, then run it (needs DATABASE_URL)
//
// `lo-research.sh prod-read` starts it. The agent never sees the connection
// string. It sees only the rows, and a text from outside the team can steer the
// agent, so nothing here trusts the SQL.
//
// What holds a write back is Postgres: the statement runs inside BEGIN READ ONLY,
// on the extended protocol, which refuses a second statement. The guard below is
// a second layer. It also stops what a read-only transaction allows: a session
// setting survives on a pooled backend and takes the app down
// (docs/reading-production.md), and a secret can be read as easily as a name.
// A regex cannot see every route to a secret column: a dedicated read-only role
// with column grants is the real limit, and LO_PROD_READ_URL takes one.
const fs = require("node:fs");

const MAX_ROWS = 100;
const MAX_CELL = 1000;
const MAX_OUTPUT = 20000;

// Anything that runs SQL from a string, changes session state, reaches the disk
// or the network, or holds a lock past the transaction.
const REFUSED_WORDS =
  /\b(insert|update|delete|merge|truncate|drop|alter|create|grant|revoke|set_config|current_setting|dblink\w*|query_to_xml\w*|table_to_xml\w*|cursor_to_xml\w*|schema_to_xml\w*|database_to_xml\w*|lo_\w+|copy|into|do|call|execute|prepare|listen|notify|lock|for\s+(update|share|no\s+key\s+update|key\s+share))\b|\bpg_\w*|\binformation_schema\b|u&["']/i;
// A column with a secret in it, by name. Also checked on the rows that come back.
const SECRET_NAME =
  /(token|secret|password|passwd|cipher|encrypt|credential|api_?key|private_?key|session_?(id|key|cookie)|cookie|li_at|\bli_a\b|signature|refresh|bearer|access_key|hash)/i;
// A whole row turned into one value carries its secret columns past the name check.
const WHOLE_ROW =
  /\b(to_jsonb?|row_to_json|jsonb?_agg|jsonb?_object_agg|json_build\w*|jsonb_build\w*|hstore|array_to_json|xmlforest|xmlelement)\s*\(|(^|[^\w.])\w+\s*::\s*(text|varchar|character\s+varying|jsonb?|xml)\b|\bcast\s*\(\s*\w+\s+as\b|\b\w+\.\*/i;
// A value that looks like a secret, whatever its column is called.
const SECRET_VALUE =
  /(eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|\bsk-[A-Za-z0-9_-]{16,}|\bxox[abprs]-[A-Za-z0-9-]{10,}|\bAKIA[0-9A-Z]{12,}|-----BEGIN|postgres(ql)?:\/\/\S+|\b[A-Za-z0-9+/_-]{64,}={0,2})/g;

function refusal(sql) {
  const text = sql.replace(/\s+/g, " ").trim().replace(/;\s*$/, "");
  if (!text) return "the file is empty";
  if (text.length > 8000) return "the statement is over 8000 characters";
  if (/--|\/\*/.test(text)) return "no comments, please";
  if (text.includes(";")) return "one statement only, with no semicolon inside";
  if (!/^(select|with)\b/i.test(text)) return "only SELECT or WITH";
  const word = text.match(REFUSED_WORDS);
  if (word) return `"${word[0]}" is not allowed`;
  // Whether a secret column is filled is a fact the agent may read; its value is not.
  const secret = text.replace(/[\w.]+\s+is\s+(not\s+)?null/gi, "").match(SECRET_NAME);
  if (secret) return `a name with "${secret[0]}" is not allowed: columns that hold secrets stay out`;
  if (WHOLE_ROW.test(text)) return "name the columns: a whole row turned into one value is not allowed";
  if (/(^|[\s,(])\*/.test(text.replace(/count\s*\(\s*\*\s*\)/gi, "")))
    return "name the columns: SELECT * is not allowed";
  return null;
}

function scrub(value) {
  if (value === null || value === undefined) return value;
  if (value instanceof Date) return value.toISOString();
  const s = typeof value === "object" ? JSON.stringify(value) : value;
  if (typeof s !== "string") return s;
  const clean = s.replace(SECRET_VALUE, "[redacted]");
  return clean.length > MAX_CELL ? `${clean.slice(0, MAX_CELL)}… (cut at ${MAX_CELL})` : clean;
}

async function main() {
  const args = process.argv.slice(2);
  const check = args[0] === "--check";
  const file = check ? args[1] : args[0];
  const sql = fs.readFileSync(file, "utf8").trim().replace(/;\s*$/, "");
  const why = refusal(sql);
  if (why) {
    console.error(`lo-prod-read: refused: ${why}`);
    process.exit(2);
  }
  if (check) return console.log("ok");

  const { Client } = require(`${process.env.LO_REPO}/node_modules/pg`);
  const url = process.env.LO_PROD_READ_URL || process.env.DATABASE_URL;
  const client = new Client({
    connectionString: url,
    ssl: { rejectUnauthorized: false },
    application_name: "lo-prod-read",
  });
  await client.connect();
  try {
    await client.query("BEGIN READ ONLY");
    await client.query("SET LOCAL statement_timeout = '20s'");
    await client.query("SET LOCAL lock_timeout = '2s'");
    // A snapshot first: Postgres then refuses to turn this transaction read-write.
    await client.query("SELECT 1");
    // `rows` forces the extended protocol, which refuses a second statement.
    const res = await client.query({ text: sql, rows: MAX_ROWS + 1 });
    const rows = res.rows.slice(0, MAX_ROWS);
    const out = rows.map((row) =>
      Object.fromEntries(
        Object.entries(row).map(([k, v]) => [k, SECRET_NAME.test(k) ? "[redacted]" : scrub(v)]),
      ),
    );
    let text = out.map((r) => JSON.stringify(r)).join("\n");
    if (text.length > MAX_OUTPUT) text = `${text.slice(0, MAX_OUTPUT)}\n… (output cut)`;
    const more = res.rows.length > MAX_ROWS ? ` (cut at ${MAX_ROWS}; there are more)` : "";
    console.log(`${rows.length} row(s)${more}`);
    if (text) console.log(text);
  } finally {
    await client.query("ROLLBACK").catch(() => {});
    await client.end().catch(() => {});
  }
}

main().catch((err) => {
  // A connection error can name the host and the user, so only Postgres's own
  // query errors pass through; the code tells the agent what to fix.
  const safe = err && err.code && /^[0-9A-Z]{5}$/.test(err.code) ? `${err.code}: ${err.message}` : "the query did not run";
  console.error(`lo-prod-read: ${safe}`.replace(SECRET_VALUE, "[redacted]"));
  process.exit(1);
});
