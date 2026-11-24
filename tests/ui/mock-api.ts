// Nachbau der Supabase-Schnittstelle für Oberflächentests: nimmt die Anfragen der App (Tabellen lesen,
// Funktionen aufrufen) entgegen und führt sie als angemeldeter Nutzer (Rolle authenticated, RLS aktiv)
// gegen eine lokale PostgreSQL-Datenbank aus. Unterstützt nur, was die App braucht.
//   DATABASE_URL=postgres://… PORT=54321 npx tsx tests/ui/mock-api.ts
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import pg from "pg";

const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
const PORT = Number(process.env.PORT ?? 54321);

const ident = (s: string) => {
  if (!/^[a-z_][a-z0-9_]*$/i.test(s)) throw new Error(`Ungültiger Name: ${s}`);
  return `"${s}"`;
};

// Top-Level-Kommas trennen (Klammern beachten)
function splitTop(s: string) {
  const out: string[] = [];
  let depth = 0;
  let cur = "";
  for (const ch of s) {
    if (ch === "(") depth++;
    if (ch === ")") depth--;
    if (ch === "," && depth === 0) {
      out.push(cur);
      cur = "";
    } else cur += ch;
  }
  if (cur) out.push(cur);
  return out.map((x) => x.trim()).filter(Boolean);
}

async function fkJoin(c: pg.PoolClient, table: string, rel: string, fkName?: string) {
  const r = await c.query(
    `select a.attname col, fa.attname fcol from pg_constraint k
       join pg_attribute a on a.attrelid = k.conrelid and a.attnum = k.conkey[1]
       join pg_attribute fa on fa.attrelid = k.confrelid and fa.attnum = k.confkey[1]
      where k.contype = 'f' and k.conrelid = $1::regclass and k.confrelid = $2::regclass and ($3::text is null or k.conname = $3)
      limit 1`, [`public.${table}`, `public.${rel}`, fkName ?? null]);
  if (!r.rows[0]) throw new Error(`Keine Verknüpfung ${table} → ${rel}`);
  return r.rows[0] as { col: string; fcol: string };
}

async function selectList(c: pg.PoolClient, table: string, alias: string, select: string): Promise<string> {
  const parts: string[] = [];
  for (const item of splitTop(select || "*")) {
    const m = item.match(/^(?:(\w+):)?(\w+)(?:!(\w+))?\((.*)\)$/);
    if (m) {
      const [, as, rel, fk, inner] = m;
      const j = await fkJoin(c, table, rel, fk);
      const sub = `${alias}_${rel}`;
      parts.push(`(select to_jsonb(${sub}x) from (select ${await selectList(c, rel, sub, inner)} from public.${ident(rel)} ${sub}
                  where ${sub}.${ident(j.fcol)} = ${alias}.${ident(j.col)}) ${sub}x) as ${ident(as || rel)}`);
    } else if (item === "*") parts.push(`${alias}.*`);
    else {
      const [as, col] = item.includes(":") ? item.split(":") : [item, item];
      parts.push(`${alias}.${ident(col)} as ${ident(as)}`);
    }
  }
  return parts.join(", ");
}

function filterSql(col: string, expr: string, params: unknown[]): string {
  const neg = expr.startsWith("not.");
  const e = neg ? expr.slice(4) : expr;
  const dot = e.indexOf(".");
  const op = e.slice(0, dot);
  const val = e.slice(dot + 1);
  const c = `t.${ident(col)}`;
  const p = (v: unknown) => {
    params.push(v);
    return `$${params.length}`;
  };
  let sql: string;
  switch (op) {
    case "eq": sql = `${c} = ${p(val)}`; break;
    case "neq": sql = `${c} <> ${p(val)}`; break;
    case "gt": sql = `${c} > ${p(val)}`; break;
    case "gte": sql = `${c} >= ${p(val)}`; break;
    case "lt": sql = `${c} < ${p(val)}`; break;
    case "lte": sql = `${c} <= ${p(val)}`; break;
    case "like": sql = `${c}::text like ${p(val.replaceAll("*", "%"))}`; break;
    case "ilike": sql = `${c}::text ilike ${p(val.replaceAll("*", "%"))}`; break;
    case "is": sql = `${c} is ${val === "null" ? "null" : val === "true" ? "true" : "false"}`; break;
    case "in": {
      const items = val.replace(/^\(|\)$/g, "").match(/("([^"]*)"|[^,]+)/g)?.map((x) => x.replace(/^"|"$/g, "")) ?? [];
      sql = `${c}::text = any(${p(items)}::text[])`;
      break;
    }
    default: throw new Error(`Filter ${op} nicht unterstützt`);
  }
  return neg ? `not (${sql})` : sql;
}

async function selectTable(c: pg.PoolClient, table: string, q: URLSearchParams, range: string | undefined) {
  const params: unknown[] = [];
  const where: string[] = [];
  let order = "";
  let limit = q.get("limit");
  let offset = q.get("offset");
  for (const [k, v] of q) {
    if (["select", "limit", "offset", "columns"].includes(k)) continue;
    if (k === "order") {
      order = " order by " + v.split(",").map((o) => {
        const [col, ...mods] = o.split(".");
        const nulls = mods.includes("nullsfirst") ? " nulls first" : mods.includes("nullslast") ? " nulls last" : "";
        return `t.${ident(col)} ${mods.includes("desc") ? "desc" : "asc"}${nulls}`;
      }).join(", ");
      continue;
    }
    if (k === "or") {   // or=(spalte.op.wert,spalte.op.wert)
      // an Kommas außerhalb von Klammern trennen (z. B. „category.in.(A,B),country.eq.GER“)
      const parts = v.replace(/^\(|\)$/g, "").split(/,(?![^(]*\))/).map((x) => { const d = x.indexOf("."); return filterSql(x.slice(0, d), x.slice(d + 1), params); });
      where.push(`(${parts.join(" or ")})`);
      continue;
    }
    where.push(filterSql(k, v, params));
  }
  if (range) {
    const [a, b] = range.split("-").map(Number);
    offset = String(a);
    limit = String(b - a + 1);
  }
  const sql = `select coalesce(json_agg(r), '[]'::json) j from (select ${await selectList(c, table, "t", q.get("select") ?? "*")}
    from public.${ident(table)} t${where.length ? " where " + where.join(" and ") : ""}${order}
    ${limit ? ` limit ${Number(limit)}` : ""}${offset ? ` offset ${Number(offset)}` : ""}) r`;
  return (await c.query(sql, params)).rows[0].j;
}

type Proc = { proretset: boolean; rettype: string; argnames: string[]; modes: string[]; types: string[] };

async function callRpc(c: pg.PoolClient, fn: string, args: Record<string, unknown>) {
  const names = Object.keys(args);
  const procs = (await c.query<Proc>(
    `select p.proretset, p.prorettype::regtype::text rettype, coalesce(p.proargnames, '{}') argnames,
            coalesce(p.proargmodes::text[], '{}') modes, p.proargtypes::regtype[]::text[] types
       from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = $1`, [fn])).rows;
  const inputs = (p: Proc) => p.argnames.filter((_, i) => !p.modes.length || ["i", "b"].includes(p.modes[i]));
  const proc = procs.find((p) => names.every((n) => inputs(p).includes(n)) && inputs(p).length >= names.length) ?? procs[0];
  if (!proc) throw new Error(`Funktion ${fn} nicht gefunden`);
  const params: unknown[] = [];
  const argSql = names.map((n) => {
    const type = proc.types[inputs(proc).indexOf(n)];
    const v = args[n];
    params.push(v !== null && typeof v === "object" && !Array.isArray(v) ? JSON.stringify(v) : v);
    return `${ident(n)} => $${params.length}::${type}`;
  }).join(", ");
  const call = `public.${ident(fn)}(${argSql})`;
  const sql = proc.proretset || proc.rettype === "record"
    ? `select coalesce(json_agg(t), '[]'::json) j from ${call} t`
    : `select to_json(${call}) j`;
  return (await c.query(sql, params)).rows[0].j;
}

function claimsFrom(req: IncomingMessage): { sub?: string; role?: string } {
  const token = (req.headers.authorization ?? "").replace(/^Bearer /, "");
  try {
    return JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString());
  } catch {
    return {};
  }
}

// Schreiben (für den Importer mit Service-Key): Einfügen/Upsert, Ändern, Löschen
function whereSql(q: URLSearchParams, params: unknown[]) {
  const where: string[] = [];
  for (const [k, v] of q) if (!["select", "columns", "on_conflict"].includes(k)) where.push(filterSql(k, v, params));
  return where.length ? ` where ${where.join(" and ")}` : "";
}
async function writeTable(c: pg.PoolClient, method: string, table: string, q: URLSearchParams, body: unknown, prefer: string) {
  const t = `public.${ident(table)}`;
  const params: unknown[] = [];
  if (method === "DELETE") return c.query(`delete from ${t} t${whereSql(q, params)}`, params);
  if (method === "PATCH") {
    const obj = body as Record<string, unknown>;
    params.push(JSON.stringify(obj));
    const sets = Object.keys(obj).map((k) => `${ident(k)} = (json_populate_record(null::${t}, $1::json)).${ident(k)}`);
    return c.query(`update ${t} t set ${sets.join(", ")}${whereSql(q, params)}`, params);
  }
  const rows = (Array.isArray(body) ? body : [body]) as Record<string, unknown>[];
  if (!rows.length) return;
  const cols = [...new Set(rows.flatMap((r) => Object.keys(r)))];
  const list = cols.map(ident).join(", ");
  params.push(JSON.stringify(rows));
  let sql = `insert into ${t} (${list}) select ${list} from json_populate_recordset(null::${t}, $1::json)`;
  const conflict = q.get("on_conflict");
  if (conflict) {
    const keys = conflict.split(",");
    const upd = cols.filter((x) => !keys.includes(x));
    sql += ` on conflict (${keys.map(ident).join(", ")}) do ` +
      (prefer.includes("ignore-duplicates") || !upd.length ? "nothing" : `update set ${upd.map((x) => `${ident(x)} = excluded.${ident(x)}`).join(", ")}`);
  }
  return c.query(sql, params);
}

function send(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "*",
    "Access-Control-Allow-Methods": "GET,POST,PATCH,DELETE,OPTIONS",
    "Access-Control-Expose-Headers": "Content-Range",
  });
  res.end(body === undefined ? "" : JSON.stringify(body));
}

createServer(async (req, res) => {
  if (req.method === "OPTIONS") return send(res, 204, undefined);
  const url = new URL(req.url!, "http://x");
  const claims = claimsFrom(req);
  const sub = claims.sub ?? null;
  const role = claims.role === "service_role" ? "service_role" : "authenticated";
  if (url.pathname.startsWith("/auth/v1/user")) {
    const u = sub && (await pool.query("select id, email from auth.users where id = $1", [sub])).rows[0];
    return u ? send(res, 200, { id: u.id, email: u.email, aud: "authenticated", role: "authenticated" })
      : send(res, 401, { message: "unauthorized" });
  }
  if (url.pathname.startsWith("/auth/v1/logout")) return send(res, 204, undefined);
  const m = url.pathname.match(/^\/rest\/v1\/(rpc\/)?(\w+)$/);
  if (!m) return send(res, 404, { message: "nicht gefunden" });
  let body = "";
  for await (const chunk of req) body += chunk;
  const c = await pool.connect();
  try {
    await c.query("begin");
    await c.query(`set local role ${role}`);
    await c.query("select set_config('request.jwt.claim.sub', $1, true), set_config('request.jwt.claim.role', $2, true)", [sub ?? "", role]);
    if (!m[1] && req.method !== "GET") {
      await writeTable(c, req.method!, m[2], url.searchParams, body ? JSON.parse(body) : {}, String(req.headers.prefer ?? ""));
      await c.query("commit");
      return send(res, req.method === "POST" ? 201 : 204, undefined);
    }
    const data = m[1]
      ? await callRpc(c, m[2], body ? JSON.parse(body) : Object.fromEntries(url.searchParams))
      : await selectTable(c, m[2], url.searchParams, req.headers.range as string | undefined);
    await c.query("commit");
    send(res, 200, data);
  } catch (e) {
    await c.query("rollback").catch(() => {});
    console.error(`${req.method} ${req.url}: ${(e as Error).message}`);
    send(res, 400, { message: (e as Error).message, code: "P0001" });
  } finally {
    c.release();
  }
}).listen(PORT, () => console.log(`Mock-API auf http://localhost:${PORT}`));
