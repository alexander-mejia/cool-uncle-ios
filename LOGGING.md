# Cool Uncle Logging System

Cool Uncle uses a dual-output logging system that writes to both Xcode console and Console.app simultaneously.

## Why Logs Appear Twice

Each log statement outputs to two destinations:
1. **Xcode Console** (`print()`) - Truncated for readability during development
2. **Console.app** (`Logger.notice()`) - Full content preserved for debugging

This is intentional - it provides clean development logs while preserving complete data for analysis.

## Filtering in Xcode

To see clean, single logs in Xcode's console, use the filter dropdown:

- **STDIO** - Shows only `print()` statements (recommended for development)
- **NOTICE** - Shows only `Logger.notice()` statements
- **No Filter** - Shows both (duplicates visible)

## Console.app Integration

For detailed debugging on a connected device:

1. Open Console.app on your Mac
2. Select your iOS device in the sidebar
3. Filter by subsystem: `subsystem:com.cooluncle.ai`

All logs appear with full, untruncated content.

## Log Categories

| Emoji | Category | Description |
|-------|----------|-------------|
| 🎯 | AI Calls | Call A/B requests |
| ✅ | AI Results | Call A/B/C responses |
| 🤖 | Sentiment | Call C analysis |
| 🗣️ | User Input | Voice transcription |
| 🎮 | MiSTer | Game launch commands |
| 📨 | Responses | MiSTer replies |
| 🔌 | Connection | WebSocket status |
| ⚠️ | Warnings | Non-fatal issues |
| ❌ | Errors | Critical failures |
| 🎲 | Random | Random game selection |

## Verbose Logging

Set environment variable `VERBOSE_LOGGING=1` in your Xcode scheme to enable additional debug output and file logging to the Documents folder.
