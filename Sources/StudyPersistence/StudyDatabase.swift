import Foundation
import GRDB
import StudyDomain

/// The single authoritative local store: SQLite through GRDB.
///
/// Full-text search is used only when the bundled SQLite actually supports
/// FTS5. The check is real (a temporary virtual table is created and dropped),
/// not assumption-based.
public final class StudyDatabase: Sendable {
    public let queue: DatabaseQueue
    public let supportsFullTextSearch: Bool

    public init(paths: AppPaths) throws {
        try paths.createDirectories()
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: paths.databaseURL.path, configuration: configuration)
        self.queue = queue
        self.supportsFullTextSearch = Self.probeFTS5()
        try Self.migrate(queue: queue, fts5Available: supportsFullTextSearch)
    }

    /// In-memory database for tests and previews.
    public init(inMemory: Bool = true) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        self.queue = queue
        self.supportsFullTextSearch = Self.probeFTS5()
        try Self.migrate(queue: queue, fts5Available: supportsFullTextSearch)
    }

    static func probeFTS5() -> Bool {
        do {
            let queue = try DatabaseQueue(configuration: Configuration())
            try queue.write { db in
                try db.execute(sql: "CREATE VIRTUAL TABLE __fts_probe USING fts5(text)")
                try db.execute(sql: "DROP TABLE __fts_probe")
            }
            return true
        } catch {
            return false
        }
    }

    static func migrate(queue: DatabaseQueue, fts5Available: Bool) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial") { db in
            try db.execute(sql: """
                CREATE TABLE documents (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    fileType TEXT NOT NULL,
                    storedFileName TEXT NOT NULL,
                    sha256 TEXT NOT NULL,
                    importedAt TEXT NOT NULL,
                    state TEXT NOT NULL,
                    language TEXT,
                    parserVersion TEXT NOT NULL,
                    activeSnapshotId TEXT
                );

                CREATE TABLE snapshots (
                    id TEXT PRIMARY KEY NOT NULL,
                    documentId TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                    version INTEGER NOT NULL,
                    textHash TEXT NOT NULL,
                    qualityJSON TEXT NOT NULL,
                    createdAt TEXT NOT NULL
                );
                CREATE INDEX snapshots_document ON snapshots(documentId);

                CREATE TABLE sections (
                    id TEXT PRIMARY KEY NOT NULL,
                    snapshotId TEXT NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    level INTEGER NOT NULL,
                    "order" INTEGER NOT NULL,
                    locationJSON TEXT NOT NULL
                );
                CREATE INDEX sections_snapshot ON sections(snapshotId);

                CREATE TABLE chunks (
                    id TEXT PRIMARY KEY NOT NULL,
                    snapshotId TEXT NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
                    text TEXT NOT NULL,
                    sectionId TEXT,
                    locationJSON TEXT NOT NULL,
                    startOffset INTEGER NOT NULL,
                    endOffset INTEGER NOT NULL,
                    extractionMethod TEXT NOT NULL,
                    quality REAL NOT NULL,
                    isUsableAsEvidence INTEGER NOT NULL,
                    "order" INTEGER NOT NULL
                );
                CREATE INDEX chunks_snapshot ON chunks(snapshotId);

                CREATE TABLE topics (
                    id TEXT PRIMARY KEY NOT NULL,
                    snapshotId TEXT NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    chunkIdsJSON TEXT NOT NULL,
                    "order" INTEGER NOT NULL
                );
                CREATE INDEX topics_snapshot ON topics(snapshotId);

                CREATE TABLE sessions (
                    id TEXT PRIMARY KEY NOT NULL,
                    documentId TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                    snapshotId TEXT NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
                    startedAt TEXT NOT NULL,
                    finishedAt TEXT,
                    mode TEXT NOT NULL,
                    promptVersionId TEXT NOT NULL,
                    modelProfileId TEXT,
                    state TEXT NOT NULL
                );
                CREATE INDEX sessions_document ON sessions(documentId);

                CREATE TABLE questions (
                    id TEXT PRIMARY KEY NOT NULL,
                    sessionId TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    topicId TEXT NOT NULL,
                    text TEXT NOT NULL,
                    rubricJSON TEXT NOT NULL,
                    createdAt TEXT NOT NULL,
                    normalizedTextHash TEXT NOT NULL
                );
                CREATE INDEX questions_session ON questions(sessionId);
                CREATE INDEX questions_topic ON questions(topicId);

                CREATE TABLE attempts (
                    id TEXT PRIMARY KEY NOT NULL,
                    questionId TEXT NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
                    text TEXT NOT NULL,
                    inputMode TEXT NOT NULL,
                    rawTranscript TEXT,
                    createdAt TEXT NOT NULL,
                    evaluationId TEXT
                );
                CREATE INDEX attempts_question ON attempts(questionId);

                CREATE TABLE drafts (
                    questionId TEXT PRIMARY KEY NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
                    text TEXT NOT NULL,
                    updatedAt TEXT NOT NULL
                );

                CREATE TABLE evaluations (
                    id TEXT PRIMARY KEY NOT NULL,
                    attemptId TEXT NOT NULL REFERENCES attempts(id) ON DELETE CASCADE,
                    status TEXT NOT NULL,
                    feedback TEXT NOT NULL,
                    correctPointIdsJSON TEXT NOT NULL,
                    missingPointIdsJSON TEXT NOT NULL,
                    incorrectStatementsJSON TEXT NOT NULL,
                    evidenceChunkIdsJSON TEXT NOT NULL,
                    providerProfileId TEXT,
                    modelId TEXT,
                    promptVersionId TEXT,
                    createdAt TEXT NOT NULL,
                    notEvaluableReason TEXT,
                    userOverrideJSON TEXT
                );
                CREATE INDEX evaluations_attempt ON evaluations(attemptId);

                CREATE TABLE promptVersions (
                    id TEXT PRIMARY KEY NOT NULL,
                    content TEXT NOT NULL,
                    contentHash TEXT NOT NULL,
                    editedAt TEXT NOT NULL,
                    isDefault INTEGER NOT NULL
                );

                CREATE TABLE providerProfiles (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    baseURL TEXT NOT NULL,
                    apiStyle TEXT NOT NULL,
                    modelId TEXT NOT NULL,
                    keychainRef TEXT,
                    requiresAuthentication INTEGER NOT NULL,
                    extraHeadersJSON TEXT NOT NULL,
                    timeoutSeconds REAL NOT NULL,
                    maxRetries INTEGER NOT NULL,
                    createdAt TEXT NOT NULL,
                    lastConnectionTest TEXT,
                    lastConnectionSucceeded INTEGER
                );

                CREATE TABLE speechProfiles (
                    id TEXT PRIMARY KEY NOT NULL,
                    engine TEXT NOT NULL,
                    modelId TEXT,
                    isLocal INTEGER NOT NULL,
                    keychainRef TEXT,
                    language TEXT,
                    remoteBaseURL TEXT,
                    createdAt TEXT NOT NULL
                );

                CREATE TABLE appSettings (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                """)
            if fts5Available {
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE chunkSearch USING fts5(
                        chunkId UNINDEXED,
                        snapshotId UNINDEXED,
                        text,
                        tokenize = 'unicode61'
                    );
                    """)
            }
        }
        migrator.registerMigration("v2_study_scopes") { db in
            try db.execute(sql: """
                CREATE TABLE scopes (
                    id TEXT PRIMARY KEY NOT NULL,
                    snapshotId TEXT NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
                    query TEXT NOT NULL,
                    title TEXT NOT NULL,
                    matchedChunkIdsJSON TEXT NOT NULL,
                    isFullDocument INTEGER NOT NULL,
                    version INTEGER NOT NULL,
                    confirmedByUser INTEGER NOT NULL,
                    createdAt TEXT NOT NULL
                );
                CREATE INDEX scopes_snapshot ON scopes(snapshotId);
                ALTER TABLE questions ADD COLUMN scopeId TEXT;
                ALTER TABLE sessions ADD COLUMN scopeId TEXT;
                ALTER TABLE sessions ADD COLUMN currentScopeId TEXT;
                """)
        }
        try migrator.migrate(queue)
    }
}

public enum SettingKey {
    public static let activeProviderProfileId = "activeProviderProfileId"
    public static let activeSpeechProfileId = "activeSpeechProfileId"
    public static let activePromptVersionId = "activePromptVersionId"
    public static let hasCompletedOnboarding = "hasCompletedOnboarding"
}
