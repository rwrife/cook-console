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
        return migrator
    }
}
