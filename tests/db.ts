// Testdatenbank: echtes PostgreSQL mit schema.sql.
// Lokal z. B. per initdb gestartet, in GitHub Actions als Service-Container.
// TEST_DATABASE_URL zeigt auf eine Instanz, in der Datenbanken angelegt werden dürfen.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import pg from "pg";

const ROOT = join(import.meta.dirname, "..");
const ADMIN_URL = process.env.TEST_DATABASE_URL ?? "postgres://postgres@localhost:54329/postgres?host=/tmp/fa-pg";
const TEMPLATE = "uci_test_template";

const sql = (f: string) => readFileSync(join(ROOT, f), "utf8");

async function admin() {
  const c = new pg.Client({ connectionString: ADMIN_URL });
  await c.connect();
  return c;
}

export function urlFor(db: string) {
  const u = new URL(ADMIN_URL);
  u.pathname = `/${db}`;
  return u.toString();
}

let templateReady: Promise<void> | null = null;

/** Vorlage einmal pro Testlauf anlegen (Schema zweimal einspielen = Wiederholbarkeit prüfen). */
function ensureTemplate() {
  templateReady ??= (async () => {
    const a = await admin();
    await a.query(`drop database if exists ${TEMPLATE}`);
    await a.query(`create database ${TEMPLATE}`);
    await a.end();
    const c = new pg.Client({ connectionString: urlFor(TEMPLATE) });
    await c.connect();
    await c.query("set client_min_messages = warning");
    for (let i = 0; i < 2; i++) {
      await c.query(sql("tests/supabase-stub.sql"));
      await c.query(sql("supabase/schema.sql"));
    }
    await c.end();
  })();
  return templateReady;
}

export type Db = pg.Client & { one<T = any>(q: string, p?: unknown[]): Promise<T>; all<T = any>(q: string, p?: unknown[]): Promise<T[]> };

/** Frische Datenbank aus der Vorlage. */
export async function freshDb(): Promise<Db> {
  await ensureTemplate();
  const name = `uci_test_${Math.random().toString(36).slice(2, 10)}`;
  const a = await admin();
  await a.query(`create database ${name} template ${TEMPLATE}`);
  await a.end();
  const c = new pg.Client({ connectionString: urlFor(name) }) as Db;
  await c.connect();
  await c.query("set client_min_messages = warning");
  c.one = async (q, p = []) => (await c.query(q, p)).rows[0];
  c.all = async (q, p = []) => (await c.query(q, p)).rows;
  const end = c.end.bind(c);
  c.end = (async () => {
    await end();
    const x = await admin();
    await x.query(`drop database if exists ${name}`);
    await x.end();
  }) as typeof c.end;
  return c;
}

export async function createUser(db: Db, name: string) {
  const id = crypto.randomUUID();
  await db.query("insert into auth.users (id, email) values ($1, $2)", [id, `${name}@example.com`]);
  return id;
}

/** Als Nutzer handeln (auth.uid()). */
export async function as(db: Db, userId: string | null) {
  await db.query("select set_config('request.jwt.claim.sub', $1, false)", [userId ?? ""]);
}

/** Fahrer anlegen (r-<id>), Rang = Platz im UCI-Ranking. */
export async function rider(db: Db, id: number, name: string, gender: "men" | "women" = "men", rank = id) {
  const slug = `r-${id}`;
  await db.query("insert into riders (pcs_slug, name, gender, nation, uci_rank) values ($1, $2, $3, 'GER', $4)", [slug, name, gender, rank]);
  return slug;
}
