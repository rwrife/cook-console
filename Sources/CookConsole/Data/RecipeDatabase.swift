import GRDB

enum RecipeDatabase {
    private static let foundationWhitespaceSQL = """
        char(9, 10, 11, 12, 13, 32, 133, 160, 5760,
             8192, 8193, 8194, 8195, 8196, 8197, 8198, 8199, 8200, 8201, 8202,
             8232, 8233, 8239, 8287, 12288)
        """

    static func make(at path: String) throws -> DatabaseQueue {
        let database = try DatabaseQueue(path: path)
        try makeMigrator().migrate(database)
        return database
    }

    static func makeInMemory() throws -> DatabaseQueue {
        let database = try DatabaseQueue()
        try makeMigrator().migrate(database)
        return database
    }

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_recipe_core") { db in
            try db.create(table: "recipes") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull().check(
                    sql: "length(trim(title, \(foundationWhitespaceSQL))) > 0"
                )
                table.column("servings", .double).notNull().check(sql: "servings > 0 AND servings < 1e999")
            }
            try db.create(table: "ingredients") { table in
                table.column("id", .text).primaryKey()
                table.column("recipe_id", .text)
                    .notNull()
                    .references("recipes", onDelete: .cascade)
                table.column("position", .integer).notNull().check(sql: "position >= 0")
                table.column("name", .text).notNull().check(
                    sql: "length(trim(name, \(foundationWhitespaceSQL))) > 0"
                )
                table.column("amount", .double).notNull().check(sql: "amount > 0 AND amount < 1e999")
                table.column("unit", .text).notNull().check(
                    sql: "unit IN ('each', 'teaspoon', 'tablespoon', 'cup', 'milliliter', 'liter', 'gram', 'kilogram', 'ounce', 'pound')"
                )
                table.uniqueKey(["recipe_id", "position"])
            }
            try db.create(index: "ingredients_recipe_id", on: "ingredients", columns: ["recipe_id"])

            try db.create(table: "recipe_steps") { table in
                table.column("id", .text).primaryKey()
                table.column("recipe_id", .text)
                    .notNull()
                    .references("recipes", onDelete: .cascade)
                table.column("position", .integer).notNull().check(sql: "position >= 0")
                table.column("instruction", .text).notNull().check(
                    sql: "length(trim(instruction, \(foundationWhitespaceSQL))) > 0"
                )
                table.column("timer_duration", .double).check(
                    sql: "timer_duration IS NULL OR (timer_duration > 0 AND timer_duration < 1e999)"
                )
                table.uniqueKey(["recipe_id", "position"])
            }
            try db.create(index: "recipe_steps_recipe_id", on: "recipe_steps", columns: ["recipe_id"])

            try db.create(table: "recipe_tags") { table in
                table.column("recipe_id", .text)
                    .notNull()
                    .references("recipes", onDelete: .cascade)
                table.column("position", .integer).notNull().check(sql: "position >= 0")
                table.column("name", .text).notNull().check(
                    sql: "length(trim(name, \(foundationWhitespaceSQL))) > 0"
                )
                table.primaryKey(["recipe_id", "position"])
            }
            try db.create(index: "recipe_tags_name", on: "recipe_tags", columns: ["name"])
        }
        migrator.registerMigration("v2_add_recipe_favorite") { db in
            try db.alter(table: "recipes") { table in
                table.add(column: "is_favorite", .boolean)
                    .notNull()
                    .defaults(to: false)
                    .check(sql: "is_favorite IN (0, 1)")
            }
        }
        migrator.registerMigration("v3_create_cook_sessions") { db in
            try db.create(table: "cook_sessions") { table in
                table.column("id", .text).primaryKey()
                table.column("recipe_id", .text)
                    .notNull()
                    .references("recipes", onDelete: .cascade)
                table.column("started_at", .datetime).notNull()
                table.column("ended_at", .datetime)
                table.column("status", .text).notNull().check(
                    sql: "status IN ('active', 'completed', 'abandoned')"
                )
                table.column("current_step", .integer).notNull().defaults(to: 0)
                    .check(sql: "current_step >= 0")
            }
            try db.create(
                index: "cook_sessions_recipe_status_ended",
                on: "cook_sessions",
                columns: ["recipe_id", "status", "ended_at"]
            )
        }
        migrator.registerMigration("v4_create_step_timers") { db in
            try db.create(table: "cook_timers") { table in
                table.column("id", .text).primaryKey()
                table.column("recipe_id", .text).notNull()
                    .references("recipes", onDelete: .cascade)
                table.column("step_id", .text).notNull()
                table.column("cook_session_id", .text).notNull()
                    .references("cook_sessions", onDelete: .cascade)
                table.column("step_name", .text).notNull().check(
                    sql: "length(trim(step_name, \(foundationWhitespaceSQL))) > 0"
                )
                table.column("original_duration", .double).notNull().check(
                    sql: "original_duration > 0 AND original_duration < 1e999"
                )
                table.column("status", .text).notNull().check(
                    sql: "status IN ('running', 'paused', 'cancelled', 'completed')"
                )
                table.column("started_at", .datetime).notNull()
                table.column("deadline", .datetime)
                table.column("remaining_when_paused", .double)
                table.column("completed_at", .datetime)
            }
            try db.create(index: "cook_timers_session", on: "cook_timers", columns: ["cook_session_id"])
            try db.create(index: "cook_timers_status_deadline", on: "cook_timers", columns: ["status", "deadline"])
            try db.create(table: "timer_events") { table in
                table.autoIncrementedPrimaryKey("sequence")
                table.column("id", .text).notNull().unique()
                table.column("timer_id", .text).notNull()
                    .references("cook_timers", onDelete: .cascade)
                table.column("event_kind", .text).notNull().check(
                    sql: "event_kind IN ('started', 'fired', 'extended')"
                )
                table.column("occurred_at", .datetime).notNull()
                table.column("seconds", .double)
            }
            try db.create(index: "timer_events_timer", on: "timer_events", columns: ["timer_id", "occurred_at"])
            try db.execute(
                sql: "CREATE UNIQUE INDEX timer_events_one_fired ON timer_events(timer_id) WHERE event_kind = 'fired'"
            )
        }
        migrator.registerMigration("v5_timer_invariants_and_completion_queue") { db in
            // A completed timer can be restarted by a notification action and
            // legitimately fire again. State transitions, not a global event
            // uniqueness rule, make each individual reconciliation idempotent.
            try db.execute(sql: "DROP INDEX timer_events_one_fired")
            try db.create(table: "timer_completion_alerts") { table in
                table.column("timer_id", .text).primaryKey()
                    .references("cook_timers", onDelete: .cascade)
                table.column("completed_at", .datetime).notNull()
            }
            let validShape = """
                (NEW.status = 'running' AND NEW.deadline IS NOT NULL
                    AND NEW.remaining_when_paused IS NULL AND NEW.completed_at IS NULL)
                OR (NEW.status = 'paused' AND NEW.deadline IS NULL
                    AND NEW.remaining_when_paused > 0 AND NEW.completed_at IS NULL)
                OR (NEW.status IN ('cancelled', 'completed') AND NEW.deadline IS NULL
                    AND NEW.remaining_when_paused IS NULL AND NEW.completed_at IS NOT NULL)
                """
            try db.execute(sql: """
                CREATE TRIGGER cook_timers_valid_shape_insert
                BEFORE INSERT ON cook_timers
                WHEN NOT (\(validShape))
                BEGIN SELECT RAISE(ABORT, 'invalid timer state shape'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER cook_timers_valid_shape_update
                BEFORE UPDATE ON cook_timers
                WHEN NOT (\(validShape))
                BEGIN SELECT RAISE(ABORT, 'invalid timer state shape'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER cook_timers_valid_identity_insert
                BEFORE INSERT ON cook_timers
                WHEN NOT EXISTS (
                    SELECT 1
                    FROM cook_sessions AS session
                    JOIN recipe_steps AS step ON step.recipe_id = session.recipe_id
                    WHERE session.id = NEW.cook_session_id
                      AND session.recipe_id = NEW.recipe_id
                      AND session.status = 'active'
                      AND step.id = NEW.step_id
                )
                BEGIN SELECT RAISE(ABORT, 'invalid timer identity'); END
                """)
        }
        migrator.registerMigration("v6_timer_schedule_generation") { db in
            // Every timer transition that replaces or removes its scheduled
            // notification bumps this counter. A delivered payload is valid
            // only while its captured generation still equals the stored
            // row's, so an obsolete request can never complete a newly
            // resumed or extended timer even when deadlines nearly coincide.
            try db.execute(
                sql: "ALTER TABLE cook_timers ADD COLUMN schedule_generation INTEGER NOT NULL DEFAULT 0"
            )
        }
        return migrator
    }
}
