# Copilot Instructions for ServerCommandFilter

## Repository Overview

This repository contains **ServerCommandFilter**, a SourcePawn plugin for SourceMod that provides comprehensive filtering of server commands. The plugin specifically targets:

- **point_servercommand** entities that execute commands via map logic
- **VScript SetValue()** calls that modify ConVars
- **VScript SendToServerConsole()** calls that execute server commands

The plugin uses a configuration-driven rule system with support for allow/deny/clamp modes, regex matching, and comprehensive logging.

## Technical Environment

### Core Technologies
- **Language**: SourcePawn (.sp files)
- **Platform**: SourceMod 1.11+ (minimum supported version)
- **Build System**: SourceKnight (modern SourceMod build tool)
- **Target Game**: Counter-Strike: Source (CSS) - gamedata signatures provided
- **Extensions Required**: DHooks, SDKTools, CSTools, Regex

### Dependencies
- **SourceMod Core**: Base platform (1.11.0-git6934 in CI)
- **UtilsHelper**: External include from srcdslab/sm-plugin-UtilsHelper
- **DHooks**: For function hooking and detours
- **GameData**: Custom signatures for CSS in `ServerCommandFilter.games.txt`

### Build Configuration
The project uses SourceKnight with configuration in `sourceknight.yaml`:
```yaml
project:
  sourceknight: 0.2
  name: ServerCommandFilter
  targets:
    - ServerCommandFilter
```

## Code Architecture & Patterns

### Core Components

1. **Command Validation Engine** (`ValidateCommand()`)
   - Central validation function used by all detours
   - Parses commands into left (command) and right (parameters) parts
   - Applies rules based on configuration

2. **DHooks Integration**
   - `AcceptInput()` detour for point_servercommand filtering
   - `SetValue()` detour for VScript ConVar changes (CSS only)
   - `SendToServerConsole()` detour for VScript command execution (CSS only)

3. **Rule System**
   - StringMap-based rule storage (`g_Rules`)
   - ArrayList for rule lists (`g_aRules`)
   - Regex support (`g_Regexes`, `g_RegexRules`)
   - Multiple rule modes: ALL, STRVALUE, INTVALUE, FLOATVALUE, REGEXVALUE

4. **Memory Management Patterns**
   - Proper cleanup in `OnPluginEnd()`
   - Use `delete` directly without null checks (per best practices)
   - Avoid `.Clear()` on StringMap/ArrayList (creates memory leaks)
   - Create new containers instead of clearing existing ones

### Key Functions

- `OnPluginStart()`: Initialize DHooks, load gamedata, setup late loading
- `OnMapStart()`: Reload configuration files
- `LoadConfig()`: Parse configuration file into rule structures
- `ValidateCommand()`: Main validation logic for all command sources
- `MatchRuleList()`: Apply rules to determine action (allow/deny/clamp)
- `Cleanup()`: Proper memory deallocation for all containers

### Rule System Architecture

Rules are organized by command name with modes:
- **MODE_ALLOW**: Explicitly allow command
- **MODE_DENY**: Block command execution
- **MODE_CLAMP**: Clamp values to specified ranges
- **MODE_MIN/MAX**: Minimum/maximum value constraints

## Configuration Management

### File Location
`addons/sourcemod/configs/ServerCommandFilter.cfg`

### Configuration Format
KeyValues format with nested structure:
```
"ServerCommandFilter"
{
    "commandname"
    {
        "allow" { "value" }      // Allow specific values
        "deny" { "value" }       // Deny specific values  
        "clamp"                  // Clamp to range
        {
            "min" "value"
            "max" "value"
        }
    }
}
```

### Rule Types
- **String matching**: Exact string comparison (case-insensitive)
- **Numeric matching**: Integer and float value matching
- **Regex matching**: Pattern matching with `/pattern/` syntax
- **Range clamping**: Min/max constraints with optional clamping

## Memory Management Guidelines

### Best Practices Applied
- Use `delete` directly without null checks before deletion
- Never use `.Clear()` on StringMap/ArrayList - delete and recreate instead
- Properly clean up regex handles in rule parsing
- Clean up all containers in `Cleanup()` function
- Use proper methodmap types (StringMap, ArrayList, Regex)

### Cleanup Patterns
```sourcepawn
// Correct cleanup pattern used in this plugin
for(int i = 0; i < g_aRules.Length; i++)
{
    ArrayList RuleList = g_aRules.Get(i);
    CleanupRuleList(RuleList);
}
delete g_aRules;  // Delete old container
g_aRules = new ArrayList();  // Create new one
```

## Development Workflow

### Building the Plugin
```bash
# Using SourceKnight (recommended)
sourceknight build

# Or via GitHub Actions - automatic on push/PR
```

### Testing Changes
1. **Local Testing**: Deploy to test server with SourceMod
2. **Configuration Testing**: Modify ServerCommandFilter.cfg and reload map
3. **Validation**: Check logs for rule matching behavior
4. **Memory Testing**: Use SourceMod's built-in profiler for leak detection

### Adding New Rules
1. Edit `addons/sourcemod/configs/ServerCommandFilter.cfg`
2. Add new command section with appropriate rule mode
3. Reload map or restart server to apply changes
4. Test with verbose logging enabled (`sm_scf_verbose 3`)

### Adding New Detours (CSS only)
1. Add gamedata signature to `ServerCommandFilter.games.txt`
2. Create detour setup function (see `Generate_SetValueDetour`)
3. Implement detour callback using `ValidateCommand()`
4. Add cleanup in `OnPluginEnd()`

## File Structure

```
addons/sourcemod/
├── scripting/
│   └── ServerCommandFilter.sp           # Main plugin source
├── configs/
│   └── ServerCommandFilter.cfg          # Rule configuration
├── gamedata/
│   └── ServerCommandFilter.games.txt    # Game signatures
└── plugins/
    └── ServerCommandFilter.smx          # Compiled plugin (build output)
```

## Common Development Tasks

### Adding a New Command Filter
1. Add command to configuration file with appropriate rules
2. Test with various parameter combinations
3. Verify logging output with different verbosity levels

### Debugging Rule Matching
1. Set `sm_scf_verbose 3` for detailed logging
2. Check SourceMod logs for validation results
3. Use regex testing tools for complex patterns

### Adding Game Support
1. Create gamedata entries for new game in `.games.txt`
2. Test signature validity with game version
3. Verify detour functionality in game environment

### Performance Optimization
1. Check rule matching complexity - avoid O(n) in frequently called functions
2. Cache expensive operations (regex compilation is done at config load)
3. Profile memory usage with SourceMod tools
4. Monitor server tick rate impact

## Logging & Debugging

### Verbosity Levels
- `0`: No logs
- `1`: Denied commands (no rules/match)
- `2`: Denied + Clamped commands
- `3`: All validation results (verbose)

### Log Format
```
[SOURCE] ACTION: "command parameters"
[point_servercommand] Blocked (No Rule): "mp_timelimit 999"
[SetValue] Clamped (800.0 -> 100.0): "sv_gravity 800"
```

## Troubleshooting Guide

### Common Issues

**Plugin fails to load:**
- Check SourceMod version (1.11+ required)
- Verify all extensions loaded (DHooks, SDKTools, etc.)
- Check gamedata compatibility with game version

**Rules not working:**
- Verify configuration file syntax
- Check command name casing (converted to lowercase)
- Test regex patterns with external tools
- Enable verbose logging for debugging

**Memory leaks:**
- Avoid `.Clear()` on containers
- Ensure proper cleanup in `OnPluginEnd()`
- Check regex handle cleanup in rule parsing

**Performance issues:**
- Monitor rule complexity and count
- Check frequency of command filtering
- Profile with SourceMod tools

### Testing Commands
```sourcepawn
// Test point_servercommand filtering
point_servercommand -> Command: "mp_timelimit 999"

// Test VScript filtering (CSS only)
Script: Convars.SetValue("sv_gravity", 800)
Script: SendToConsole("mp_restartgame 1")
```

## Code Style Guidelines

This plugin follows the established SourcePawn best practices:

- **Indentation**: Tabs (4 spaces)
- **Naming**: camelCase for locals, PascalCase for functions, g_ prefix for globals
- **Pragmas**: `#pragma semicolon 1` and `#pragma newdecls required`
- **Memory**: Use methodmaps, delete without null checks, avoid .Clear()
- **Documentation**: Focus on complex logic, avoid unnecessary headers
- **Error Handling**: Proper validation for all API calls

## Version Control

- Use semantic versioning (MAJOR.MINOR.PATCH)
- Plugin version defined in `myinfo` structure
- CI automatically creates releases from tags
- Master/main branch auto-tagged as "latest"

## Performance Considerations

- Rule matching is O(1) for exact command names via StringMap
- Regex matching is O(n) over regex list - minimize regex rules
- DHooks callbacks are performance-critical - keep validation fast
- Configuration loading only happens on map start
- Memory allocation minimized through container reuse patterns