# Building Cool Uncle

This guide covers everything you need to build and run Cool Uncle.

## Prerequisites

- **macOS** with Xcode 26 or later
- **iOS 26.0+ device** (simulator not supported)
- **CocoaPods** for dependency management
- **Apple Developer account** (free tier works for device testing)

## Dependencies

Cool Uncle uses two package managers:

### CocoaPods
- **onnxruntime-objc** - ONNX Runtime for wake word ML inference

### Swift Package Manager (automatic)
- **FluidAudio** - Voice activity detection

## Step-by-Step Build

### 1. Install CocoaPods

If you don't have CocoaPods installed:

```bash
sudo gem install cocoapods
```

### 2. Clone the Repository

```bash
git clone https://github.com/yourusername/cool-uncle-ios.git
cd cool-uncle-ios
```

### 3. Install Pod Dependencies

```bash
pod install
```

This creates the `Cool Uncle.xcworkspace` file.

### 4. Open the Workspace

**Critical:** Always open the `.xcworkspace`, not the `.xcodeproj`:

```bash
open "Cool Uncle.xcworkspace"
```

If you open the `.xcodeproj` directly, you'll get "No such module 'onnxruntime'" errors.

### 5. Configure Signing

1. Select the "Cool Uncle" target
2. Go to "Signing & Capabilities"
3. Select your development team
4. Xcode will automatically manage provisioning

### 6. Connect Your Device

1. Connect your iPhone via USB or Wi-Fi
2. Trust the computer on your device if prompted
3. Select your device in Xcode's device dropdown

### 7. Build and Run

Press ⌘+R or click the Play button.

**Note:** First build may take several minutes due to ONNX Runtime compilation.

## Why No Simulator?

Cool Uncle requires:
- Microphone access for voice input
- Audio session configuration for duplex audio
- Real-time audio processing

The iOS Simulator doesn't support these features adequately.

## Project Structure

```
Cool Uncle/
├── Cool Uncle.xcworkspace    # ← Open this
├── Cool Uncle.xcodeproj/     # App project (managed by workspace)
├── Pods/                     # CocoaPods dependencies (generated)
├── Podfile                   # Pod dependency declarations
├── Podfile.lock              # Locked versions
└── Cool Uncle/               # Source code
    ├── Cool_UncleApp.swift   # App entry point
    ├── EnhancedOpenAIService.swift
    ├── ZaparooService.swift
    ├── SpeechService.swift
    ├── WakeWordKit/          # Wake word detection
    ├── ConsumerUI/           # Main UI
    └── *.onnx                # ML models
```

## ONNX Models

The wake word system uses three ONNX models:

| Model | Purpose | Size |
|-------|---------|------|
| `hey_mister.onnx` | Wake word detection | ~2MB |
| `melspectrogram.onnx` | Audio feature extraction | ~100KB |
| `embedding.onnx` | Audio embeddings | ~500KB |

These are included in the repository and bundled with the app automatically.

## Troubleshooting

### "No such module 'onnxruntime'"

You opened the `.xcodeproj` instead of `.xcworkspace`. Close Xcode and open:
```bash
open "Cool Uncle.xcworkspace"
```

### Pod install fails

Try updating CocoaPods:
```bash
sudo gem update cocoapods
pod repo update
pod install
```

### Build fails with signing errors

1. Ensure you have a valid Apple Developer account
2. In Xcode: Target → Signing & Capabilities → Select your team
3. If using free account, you may need to change the bundle identifier

### App crashes on launch

Ensure you're running on a physical device, not the simulator.

### "Microphone access denied"

1. Go to iOS Settings → Privacy → Microphone
2. Enable access for Cool Uncle
3. Or delete and reinstall the app to get the permission prompt again

## Environment Variables (Debug)

For development, these environment variables can be set in the scheme:

| Variable | Purpose |
|----------|---------|
| `VERBOSE_LOGGING` | Enable detailed console logs |

You can run the program with the CLI `-ForceConsumerUI` to force the consumer UI on while debugging the app, and with `-SimulateNetworkTimeout` if you want the open AI calls to time out each time you send them.

Set these in: Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables

## Clean Build

If you encounter strange build issues:

1. Product → Clean Build Folder (⇧⌘K)
2. Delete DerivedData: `rm -rf ~/Library/Developer/Xcode/DerivedData/Cool_Uncle-*`
3. Re-run `pod install`
4. Build again
