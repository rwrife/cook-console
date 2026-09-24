"""Seed sample recipes into a NEW, dedicated simulator database after first launch.
Usage: python3 Tools/seed_screenshot_recipes.py /path/to/recipes.sqlite
Terminate the app before running. Refuses to modify a nonempty recipe library.
"""
import sqlite3
import sys
import uuid

recipes = [
    ('Creamy Tomato Soup', ['weeknight', 'comfort food'], [('Olive oil', 2, 'tablespoon'), ('Onion, diced', 1, 'each'), ('Crushed tomatoes', 800, 'gram'), ('Vegetable stock', 2, 'cup'), ('Cream', 0.5, 'cup')], [('Soften the onion in olive oil over medium heat.', 300), ('Add tomatoes and stock. Simmer gently, stirring occasionally.', 900), ('Blend until smooth, stir in cream, and season to taste.', None)]),
    ('Lemon Herb Rice', ['side dish', 'batch cooking'], [('Rice', 1, 'cup'), ('Water', 2, 'cup'), ('Lemon', 1, 'each')], [('Rinse rice, then bring to a boil with water.', None), ('Cover and simmer over low heat.', 900), ('Rest off the heat, then fluff with lemon zest and herbs.', 300)]),
    ('Roasted Carrots', ['vegetarian', 'side dish'], [('Carrots', 500, 'gram'), ('Olive oil', 2, 'tablespoon')], [('Heat oven to 200°C. Slice carrots and toss with oil.', None), ('Roast until tender and golden at the edges.', 1500)]),
    ('Sunday Pancakes', ['breakfast', 'family favorites'], [('Flour', 1.5, 'cup'), ('Milk', 1, 'cup'), ('Egg', 1, 'each')], [('Whisk ingredients into a smooth batter.', None), ('Cook small ladles of batter in a hot pan. Flip when bubbles appear.', 120)]),
    ('Garlic Butter Pasta', ['quick', 'weeknight'], [('Pasta', 400, 'gram'), ('Butter', 3, 'tablespoon'), ('Garlic cloves', 3, 'each')], [('Boil pasta in salted water until al dente.', 600), ('Warm butter and garlic. Toss with pasta and a splash of cooking water.', None)]),
    ('Chickpea Salad', ['lunch', 'make ahead'], [('Chickpeas', 400, 'gram'), ('Cucumber', 1, 'each'), ('Olive oil', 2, 'tablespoon')], [('Drain chickpeas and dice cucumber.', None), ('Toss with olive oil, lemon juice, and fresh herbs.', None)]),
]
with sqlite3.connect(sys.argv[1]) as db:
    if db.execute('SELECT COUNT(*) FROM recipes').fetchone()[0]:
        raise SystemExit('Refusing to seed a nonempty recipe library')
    for title, tags, ingredients, steps in recipes:
        rid = str(uuid.uuid4()).upper()
        db.execute('INSERT INTO recipes(id,title,servings,is_favorite) VALUES (?,?,4,?)', (rid, title, int(title in ['Creamy Tomato Soup','Sunday Pancakes'])))
        for i, (name, amount, unit) in enumerate(ingredients):
            db.execute('INSERT INTO ingredients VALUES (?,?,?,?,?,?)', (str(uuid.uuid4()).upper(),rid,i,name,amount,unit))
        for i, (instruction, duration) in enumerate(steps):
            db.execute('INSERT INTO recipe_steps VALUES (?,?,?,?,?)', (str(uuid.uuid4()).upper(),rid,i,instruction,duration))
        for i, tag in enumerate(tags):
            db.execute('INSERT INTO recipe_tags VALUES (?,?,?)',(rid,i,tag))
print('Seeded six sample recipes.')
