# Cool Uncle Architecture

This document describes the core architectural patterns used in Cool Uncle.

## User Interfaces

Cool Uncle includes two UI modes:

### Consumer UI (Default)

Located in `ConsumerUI/ConsumerView.swift`

The production interface designed for end users:
- Clean chat bubble conversation interface
- Large microphone button with visual feedback
- Real-time transcription display while speaking
- Wake word toggle for hands-free operation
- Transient status indicators (iMessage-style)
- Keyboard input option for manual text entry

### Debug UI

Located in `DebugContentView.swift`

A developer-focused interface for testing and debugging:
- Raw log output display
- Connection status details
- Manual command entry
- Detailed AI response inspection
- Useful for troubleshooting MiSTer connectivity

The app defaults to Consumer UI. Debug UI can be accessed via the app's internal navigation.

## Three-Call Architecture

Cool Uncle uses a three-phase AI system for processing user requests:

### Call A - Intent Classification & Command Generation

**Purpose:** Understand what the user wants and generate the appropriate command.

**Model:** GPT-4o (for accuracy) or GPT-4o-mini (for speed)

**Output:** JSON command or classification

```json
{"action_type": "launch_specific", "action_context": "user wants to play Wing Commander II"}
```

**Action Types:**
- `launch_specific` - User wants a specific game
- `recommend` - User wants a game recommendation
- `recommend_confirm` - User has been playing a game for over a certain time and needs to confirm before launch
- `recommend_alternative` - user asks for a different/better version of the game
- `random` - User wants a random game from a system
- `informational` - User is asking a question (no command)
- `save_state`, `load_state`, `menu`, `stop_game` - Utility commands

### Call B - Response Generation

**Purpose:** Generate Cool Uncle's spoken response.

**Model:** GPT-4o-mini

**Characteristics:**
- Personality-driven responses (knowledgeable, enthusiastic uncle)
- Context-aware (knows what game is playing, what was just launched)
- Brief for commands, detailed for informational queries

### Call C - Sentiment Analysis (Background)

**Purpose:** Learn user preferences from their statements.

**Model:** GPT-4o-mini

**Execution:** Asynchronous via `CallCDispatchService`

**Output:** Preference updates (favorites, dislikes, want-to-play)

## Two-Variable Game State

The app tracks two distinct game states to handle recommendation flows:

### Current Game (`currentGame`)
- The game actually running on MiSTer
- Updated when a launch command succeeds
- Used for context in AI prompts

### Recommended Game (`recommendedGame`)
- A game Cool Uncle has suggested but not yet launched
- Cleared when user confirms or rejects
- Enables "play that" / "no thanks" flows

### State Transitions

```
User: "Recommend a puzzle game"
→ recommendedGame = "Tetris"
→ currentGame = unchanged

User: "Play that"
→ Launch Tetris
→ currentGame = "Tetris"
→ recommendedGame = nil

User: "No thanks"
→ recommendedGame = nil
→ currentGame = unchanged
```

## Search & Launch Workflow

### Optimized Search Path

For `launch_specific` requests, Cool Uncle uses parallel search:

1. **Generate Search Terms** - AI creates 3 keyword variations
2. **Execute Searches** - Sequential search with early termination
3. **Select Best Match** - AI picks the best ROM from results
4. **Launch** - Send command to MiSTer via Zaparoo

### Search Term Generation

The AI generates keywords optimized for ROM filename matching:

```json
{"searches": ["wing", "commander", "wc2"], "target_game": "Wing Commander II", "system": null}
```

## WebSocket Communication

Cool Uncle communicates with MiSTer via WebSocket JSON-RPC 2.0:

**Connection:** `ws://<mister-ip>:7497/api/v0.1`

### Command Format

```json
{
  "jsonrpc": "2.0",
  "id": "unique-uuid",
  "method": "launch",
  "params": {
    "text": "DOS/Wing Commander II.mgl"
  }
}
```

### Available Methods
- `launch` - Launch a game
- `media.search` - Search for games
- `systems` - List available systems
- `stop` - Stop current game
- `settings.reload` - Reload settings

See the [Zaparoo Core API documentation](https://zaparoo.org/docs/core/api/) for more details

## Wake Word Detection

### Pipeline

1. **Audio Capture** - Continuous 16kHz audio from microphone
2. **VAD** - Voice Activity Detection (FluidAudio/Silero)
3. **Wake Word** - ONNX model detects "Hey Mister"
4. **Speech Recognition** - iOS SpeechAnalyzer for transcription

### Models (ONNX)

| Model | Purpose | Source | License |
|-------|---------|--------|---------|
| `hey_mister_V7_baseline_epoch_50.onnx` | Custom "Hey Mister" wake word | Trained by project author | BSD-3-Clause |
| `melspectrogram.onnx` | Audio feature extraction | [openWakeWord](https://github.com/dscripka/openWakeWord) | Apache 2.0 |
| `embedding_model.onnx` | Audio embeddings | [openWakeWord](https://github.com/dscripka/openWakeWord) (Google TFHub) | Apache 2.0 |

**Note:** The `melspectrogram.onnx` and `embedding_model.onnx` files are from the openWakeWord project and are licensed under Apache 2.0, not BSD-3-Clause. They are included here for convenience but retain their original license.

The `hey_mister` model was trained using openWakeWord's training pipeline with speech-to-text variants. It could be improved with more diverse training data.

## Service Architecture

### Core Services

| Service | Responsibility |
|---------|---------------|
| `EnhancedOpenAIService` | AI calls, prompt management |
| `ZaparooService` | MiSTer WebSocket communication |
| `SpeechService` | Voice input, wake word |
| `CurrentGameService` | Game state management |
| `GamePreferenceService` | User preferences storage |
| `CallCDispatchService` | Background sentiment analysis queue |

### Data Flow

```
User Voice → SpeechService → EnhancedOpenAIService (Call A)
                                      ↓
                              ZaparooService → MiSTer
                                      ↓
                           EnhancedOpenAIService (Call B)
                                      ↓
                              AVSpeechService → Audio Output
                                      ↓
                           CallCDispatchService (Call C) [async]
```

## Preference System

User preferences are tracked across sessions:

- **Favorites** - Games user explicitly loved
- **Disliked** - Games user didn't enjoy
- **Want to Play** - Games user expressed interest in
- **Play History** - Recent games (for variety)

Preferences influence recommendations but never block explicit launches.
