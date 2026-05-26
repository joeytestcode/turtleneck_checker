# turtleneck_checker

Flutter mobile app for the posture-analysis workflow originally built in `webapp_sample`.

## OpenAI Key Setup

You can hardcode the API key directly in [c:\Programming\turtleneck_checker\turtleneck_checker\lib\main.dart](c:/Programming/turtleneck_checker/turtleneck_checker/lib/main.dart) by setting the `_hardcodedApiKey` constant.

```dart
const _hardcodedApiKey = 'sk-...';
```

If `_hardcodedApiKey` is empty, the app still supports build-time env values from `webapp_sample/.env`:

```env
OPENAI_API_KEY=sk-...
```

or:

```env
CHATGPT_API_KEY=sk-...
```

3. Run the app with:

```bash
flutter run --dart-define-from-file=webapp_sample/.env
```

Resolution order is: hardcoded key, then `OPENAI_API_KEY`, then `CHATGPT_API_KEY`, then the manual API key field in the app.

## In-App AI Settings

The app also supports loading an API key from a local text file in the AI settings dialog.

Create a file named `api.key` with only the API key text inside:

```text
sk-...
```

Then open the AI settings dialog in the app and use `api.key 파일에서 불러오기`. The imported key is saved on-device and remains available after restarting the app.
