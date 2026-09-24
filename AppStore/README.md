# App Store assets

Use `description.txt` and the four opaque RGB PNGs in `screenshots-6.5/`, in numbered order: recipe library, servings and ingredients, cook mode, and active timer. Each is 1242 × 2688. These exports preserve the exact visible pixels of the tracked genuine simulator captures in `raw-captures/`.

The original captures use an iPhone 11 Pro Max with illustrative sample recipes. Main was rebuilt and launched on iOS 26.5 with Xcode 27.0 on September 23, 2026. To recreate sample data, see `Tools/seed_screenshot_recipes.py`; capture the corresponding recipe and cooking screens with `xcrun simctl io <device-id> screenshot <file.png>` and export without alpha.

The custom app icon and existing editorial copy are preserved. No build or metadata has been uploaded to App Store Connect.
