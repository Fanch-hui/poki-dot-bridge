import fs from "node:fs";
import path from "node:path";
import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import type {
  D1AllResult,
  D1DatabaseLike,
  D1PreparedStatementLike,
  D1RunResult,
} from "../db/d1-types.ts";

class SqliteStatement implements D1PreparedStatementLike {
  private readonly db: DatabaseSync;
  private readonly query: string;
  private readonly params: SQLInputValue[];

  constructor(db: DatabaseSync, query: string, params: SQLInputValue[] = []) {
    this.db = db;
    this.query = query;
    this.params = params;
  }

  bind(...values: unknown[]): D1PreparedStatementLike {
    const normalized = values.map((v) =>
      v === undefined ? null : (v as SQLInputValue),
    );
    return new SqliteStatement(this.db, this.query, normalized);
  }

  async first<T = Record<string, unknown>>(colName?: string): Promise<T | null> {
    const stmt = this.db.prepare(this.query);
    const row = stmt.get(...this.params) as Record<string, unknown> | undefined;
    if (!row) return null;
    if (colName !== undefined) {
      return (row[colName] as T | undefined) ?? null;
    }
    return row as T;
  }

  async all<T = Record<string, unknown>>(): Promise<D1AllResult<T>> {
    const stmt = this.db.prepare(this.query);
    const results = stmt.all(...this.params) as T[];
    return { results, success: true };
  }

  async run(): Promise<D1RunResult> {
    const stmt = this.db.prepare(this.query);
    const info = stmt.run(...this.params);
    return {
      success: true,
      meta: {
        changes: Number(info.changes ?? 0),
        last_row_id: Number(info.lastInsertRowid ?? 0),
      },
    };
  }

  executeSync(): D1AllResult<Record<string, unknown>> {
    const trimmed = this.query.trimStart().toUpperCase();
    const returnsRows =
      trimmed.startsWith("SELECT") ||
      trimmed.startsWith("WITH") ||
      /\bRETURNING\b/i.test(this.query);
    const stmt = this.db.prepare(this.query);
    if (returnsRows) {
      const results = stmt.all(...this.params) as Record<string, unknown>[];
      return { results, success: true };
    }
    const info = stmt.run(...this.params);
    return {
      results: [],
      success: true,
      meta: {
        changes: Number(info.changes ?? 0),
        last_row_id: Number(info.lastInsertRowid ?? 0),
      },
    };
  }
}

export class SqliteD1Adapter implements D1DatabaseLike {
  readonly raw: DatabaseSync;

  constructor(filePath = ":memory:", applyMigration = true) {
    if (filePath !== ":memory:") {
      fs.mkdirSync(path.dirname(filePath), { recursive: true });
    }
    this.raw = new DatabaseSync(filePath);
    this.raw.exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;");
    if (applyMigration) {
      this.applyInitialMigration();
    }
  }

  private applyInitialMigration(): void {
    const migrationPath = path.resolve(process.cwd(), "migrations/0001_init.sql");
    const sql = fs.readFileSync(migrationPath, "utf8");
    this.raw.exec(sql);
  }

  prepare(query: string): D1PreparedStatementLike {
    return new SqliteStatement(this.raw, query);
  }

  async batch<T = unknown>(
    statements: D1PreparedStatementLike[],
  ): Promise<D1AllResult<T>[]> {
    this.raw.exec("BEGIN IMMEDIATE");
    try {
      const results: D1AllResult<T>[] = [];
      for (const stmt of statements) {
        if (stmt instanceof SqliteStatement) {
          results.push(stmt.executeSync() as D1AllResult<T>);
        } else {
          results.push(await stmt.all<T>());
        }
      }
      this.raw.exec("COMMIT");
      return results;
    } catch (error) {
      this.raw.exec("ROLLBACK");
      throw error;
    }
  }

  async exec(query: string): Promise<void> {
    this.raw.exec(query);
  }

  close(): void {
    this.raw.close();
  }
}
