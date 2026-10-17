/// `index.sqlite` schema. Bump `IndexStore.schemaVersion` and add a step to change it.
///
/// `sections` row `ord = 0` is the file itself (name, title, and whole text when the
/// extractor gave no sections); `ord > 0` are slides, pages, sheets with their anchors.
/// Both FTS tables are external-content, kept in sync by triggers.
enum Schema {
    static let v1 = """
    CREATE TABLE files(
        path TEXT PRIMARY KEY,
        id TEXT,
        mtime REAL NOT NULL,
        size INTEGER NOT NULL,
        ext TEXT NOT NULL,
        title TEXT,
        indexed_at REAL NOT NULL
    );
    CREATE INDEX files_id ON files(id);
    CREATE INDEX files_mtime ON files(mtime);

    CREATE TABLE sections(
        rowid INTEGER PRIMARY KEY,
        path TEXT NOT NULL,
        ord INTEGER NOT NULL,
        anchor_kind TEXT,
        anchor_value TEXT,
        title TEXT,
        text TEXT NOT NULL
    );
    CREATE INDEX sections_path ON sections(path, ord);
    CREATE VIRTUAL TABLE sections_fts USING fts5(
        title, text, content='sections', content_rowid='rowid',
        tokenize='unicode61 remove_diacritics 2', prefix='2 3'
    );
    INSERT INTO sections_fts(sections_fts, rank) VALUES('rank', 'bm25(8.0, 1.0)');
    CREATE TRIGGER sections_ai AFTER INSERT ON sections BEGIN
        INSERT INTO sections_fts(rowid, title, text) VALUES (new.rowid, new.title, new.text);
    END;
    CREATE TRIGGER sections_ad AFTER DELETE ON sections BEGIN
        INSERT INTO sections_fts(sections_fts, rowid, title, text) VALUES ('delete', old.rowid, old.title, old.text);
    END;
    CREATE TRIGGER sections_au AFTER UPDATE OF title, text ON sections BEGIN
        INSERT INTO sections_fts(sections_fts, rowid, title, text) VALUES ('delete', old.rowid, old.title, old.text);
        INSERT INTO sections_fts(rowid, title, text) VALUES (new.rowid, new.title, new.text);
    END;

    CREATE TABLE comments(
        rowid INTEGER PRIMARY KEY,
        path TEXT NOT NULL,
        id TEXT NOT NULL,
        ts REAL NOT NULL,
        anchor_kind TEXT,
        anchor_value TEXT,
        text TEXT NOT NULL
    );
    CREATE INDEX comments_path ON comments(path);
    CREATE VIRTUAL TABLE comments_fts USING fts5(
        text, content='comments', content_rowid='rowid',
        tokenize='unicode61 remove_diacritics 2', prefix='2 3'
    );
    CREATE TRIGGER comments_ai AFTER INSERT ON comments BEGIN
        INSERT INTO comments_fts(rowid, text) VALUES (new.rowid, new.text);
    END;
    CREATE TRIGGER comments_ad AFTER DELETE ON comments BEGIN
        INSERT INTO comments_fts(comments_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
    END;
    CREATE TRIGGER comments_au AFTER UPDATE OF text ON comments BEGIN
        INSERT INTO comments_fts(comments_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
        INSERT INTO comments_fts(rowid, text) VALUES (new.rowid, new.text);
    END;

    PRAGMA user_version = 1;
    """

    static let v2 = """
    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    PRAGMA user_version = 2;
    """

    /// One unit-length Float32 vector per section, keyed by the section's rowid so a rename
    /// keeps it and re-extraction or an edited title drops it.
    static let v3 = """
    CREATE TABLE embeddings(
        section INTEGER PRIMARY KEY,
        model TEXT NOT NULL,
        vector BLOB NOT NULL
    );
    CREATE TRIGGER sections_embed_ad AFTER DELETE ON sections BEGIN
        DELETE FROM embeddings WHERE section = old.rowid;
    END;
    CREATE TRIGGER sections_embed_au AFTER UPDATE OF title, text ON sections BEGIN
        DELETE FROM embeddings WHERE section = old.rowid;
    END;
    PRAGMA user_version = 3;
    """

    /// Titles and tags from a small model for files whose extractor found no title.
    /// `titled_by` marks a file as asked about (the model's name), whatever came back.
    static let v4 = """
    ALTER TABLE files ADD COLUMN tags TEXT;
    ALTER TABLE files ADD COLUMN titled_by TEXT;
    PRAGMA user_version = 4;
    """
    static let v5 = """
    ALTER TABLE files ADD COLUMN extraction_state TEXT NOT NULL DEFAULT 'complete';
    ALTER TABLE files ADD COLUMN extraction_reason TEXT;
    ALTER TABLE files ADD COLUMN attempted_at REAL;
    ALTER TABLE files ADD COLUMN retry_after REAL;
    ALTER TABLE files ADD COLUMN attempt_count INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE files ADD COLUMN processed_units INTEGER;
    ALTER TABLE files ADD COLUMN total_units INTEGER;
    ALTER TABLE comments ADD COLUMN provenance TEXT;
    CREATE INDEX files_extraction_state ON files(extraction_state, retry_after);
    CREATE TABLE embedding_spans(
        section INTEGER NOT NULL,
        offset INTEGER NOT NULL,
        model TEXT NOT NULL,
        vector BLOB NOT NULL,
        PRIMARY KEY(section, offset)
    );
    INSERT INTO embedding_spans SELECT section, 0, model, vector FROM embeddings;
    DELETE FROM embeddings WHERE section IN (SELECT rowid FROM sections WHERE length(text) + length(coalesce(title, '')) > 2000);
    CREATE TRIGGER sections_spans_ad AFTER DELETE ON sections BEGIN
        DELETE FROM embedding_spans WHERE section = old.rowid;
    END;
    CREATE TRIGGER sections_spans_au AFTER UPDATE OF title, text ON sections BEGIN
        DELETE FROM embedding_spans WHERE section = old.rowid;
    END;
    PRAGMA user_version = 5;
    """

    static let v6 = """
    CREATE TABLE pending_renames(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        from_path TEXT NOT NULL,
        to_path TEXT NOT NULL
    );
    PRAGMA user_version = 6;
    """

    static let v7 = """
    ALTER TABLE pending_renames ADD COLUMN file_identity TEXT;
    PRAGMA user_version = 7;
    """

    /// Thoughts v2: what a thought carries beyond its text (`ThoughtMeta`), queryable. `kind` and
    /// `due` are the person's or a model's decision, else what `ThoughtRules` read from the text;
    /// `meta` is the whole hidden-line JSON. A one-time reload fills the columns from the notes.
    static let v9Columns: [(column: String, ddl: String)] = [
        ("uid", "ALTER TABLE comments ADD COLUMN uid TEXT"),
        ("parent", "ALTER TABLE comments ADD COLUMN parent TEXT"),
        ("kind", "ALTER TABLE comments ADD COLUMN kind TEXT"),
        ("kind_by", "ALTER TABLE comments ADD COLUMN kind_by TEXT"),
        ("state", "ALTER TABLE comments ADD COLUMN state TEXT NOT NULL DEFAULT 'open'"),
        ("due", "ALTER TABLE comments ADD COLUMN due REAL"),
        ("snooze_until", "ALTER TABLE comments ADD COLUMN snooze_until REAL"),
        ("modified", "ALTER TABLE comments ADD COLUMN modified REAL"),
        ("origin", "ALTER TABLE comments ADD COLUMN origin TEXT NOT NULL DEFAULT 'human'"),
        ("action", "ALTER TABLE comments ADD COLUMN action TEXT"),
        ("meta", "ALTER TABLE comments ADD COLUMN meta TEXT"),
    ]

    /// The rest of the v9 step, after `v9Columns` (each added only if missing).
    static let v9 = """
    CREATE INDEX IF NOT EXISTS comments_uid ON comments(uid);
    CREATE INDEX IF NOT EXISTS comments_parent ON comments(parent);
    CREATE INDEX IF NOT EXISTS comments_triage ON comments(state, kind, due);
    INSERT OR REPLACE INTO meta(key, value) VALUES ('comments_reload', '1');
    PRAGMA user_version = 9;
    """

    /// Semantic search, additive and idempotent, so it can be applied lazily by the writer
    /// (`IndexStore.ensureSemanticSchema`) without a `user_version` bump, or folded into a
    /// numbered step later (`semanticColumns` first, guarded by `table_info`).
    ///
    /// - `embedding_spans` (v5) holds one row per embedded chunk: `offset`/`length` locate the
    ///   chunk in its section's text, `hash` identifies the exact model input, and `vector` is
    ///   a Float32 scale followed by Int8 components (`VectorCodec`). A row with offset -1 and
    ///   an empty vector marks a section with nothing worth embedding.
    /// - `comment_vectors`: the same for thoughts, keyed by the comment's rowid.
    /// - `semantic_cache`: vectors of chunks whose rows were deleted (a file re-extracted,
    ///   renamed or retitled), keyed by input hash, so unchanged text is never sent to a model
    ///   twice. Pruned by age and size after each embedding pass.
    static let semanticColumns: [(table: String, column: String, ddl: String)] = [
        ("embedding_spans", "hash", "ALTER TABLE embedding_spans ADD COLUMN hash INTEGER"),
        ("embedding_spans", "length", "ALTER TABLE embedding_spans ADD COLUMN length INTEGER"),
    ]

    static let semantic = """
    CREATE INDEX IF NOT EXISTS embedding_spans_model ON embedding_spans(model, section);
    CREATE TABLE IF NOT EXISTS comment_vectors(
        comment INTEGER PRIMARY KEY,
        model TEXT NOT NULL,
        hash INTEGER NOT NULL,
        vector BLOB NOT NULL
    );
    CREATE TABLE IF NOT EXISTS semantic_cache(
        model TEXT NOT NULL,
        hash INTEGER NOT NULL,
        vector BLOB NOT NULL,
        ts REAL NOT NULL,
        PRIMARY KEY(model, hash)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS semantic_cache_ts ON semantic_cache(ts);
    CREATE TRIGGER IF NOT EXISTS embedding_spans_keep AFTER DELETE ON embedding_spans
    WHEN old.hash IS NOT NULL AND length(old.vector) > 0 BEGIN
        INSERT OR IGNORE INTO semantic_cache(model, hash, vector, ts) VALUES (old.model, old.hash, old.vector, strftime('%s', 'now'));
    END;
    CREATE TRIGGER IF NOT EXISTS comments_vectors_ad AFTER DELETE ON comments BEGIN
        DELETE FROM comment_vectors WHERE comment = old.rowid;
    END;
    CREATE TRIGGER IF NOT EXISTS comments_vectors_au AFTER UPDATE OF text ON comments BEGIN
        DELETE FROM comment_vectors WHERE comment = old.rowid;
    END;
    CREATE TRIGGER IF NOT EXISTS comment_vectors_keep AFTER DELETE ON comment_vectors BEGIN
        INSERT OR IGNORE INTO semantic_cache(model, hash, vector, ts) VALUES (old.model, old.hash, old.vector, strftime('%s', 'now'));
    END;
    """

}
