// Spins up a throwaway Postgres (PGlite) with the dev auth shim + every
// migration, exactly as the browser demo mode does.
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const read = (p) => readFileSync(root + p, 'utf8');

export const OWNER = '00000000-0000-4000-8000-000000000001';

export async function createDb({ seedOwner = true } = {}) {
  const db = new PGlite();
  await db.exec(read('supabase/dev/auth_shim.sql'));
  for (const f of JSON.parse(read('supabase/migrations/manifest.json'))) {
    try { await db.exec(read('supabase/migrations/' + f)); }
    catch (e) { throw new Error(`${f}: ${e.message}`); }
  }
  if (seedOwner) {
    await db.query(`insert into auth.users (id, email, raw_user_meta_data) values ($1, 'olim@goldexconst.com', '{"first_name":"Olimbek","last_name":"Nazyrov"}')`, [OWNER]);
    await asUser(db, OWNER);
  }
  return db;
}

// Act as a signed-in Supabase user (RLS applies) or anon (id = null).
export async function asUser(db, id) {
  await db.exec(`reset role`);
  await db.query(`select set_config('request.jwt.claim.sub', $1, false)`, [id || '']);
  await db.query(`select set_config('request.jwt.claim.role', $1, false)`, [id ? 'authenticated' : 'anon']);
  await db.exec(`set role ${id ? 'authenticated' : 'anon'}`);
}

export async function asService(db) {
  await db.exec(`reset role`);
  await db.query(`select set_config('request.jwt.claim.sub', '', false)`);
  await db.query(`select set_config('request.jwt.claim.role', 'service_role', false)`);
  await db.exec(`set role service_role`);
}

export const one = async (db, sql, params) => (await db.query(sql, params)).rows[0];
export const all = async (db, sql, params) => (await db.query(sql, params)).rows;
export const val = async (db, sql, params) => Object.values((await db.query(sql, params)).rows[0] ?? {})[0];
