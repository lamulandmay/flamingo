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
}
